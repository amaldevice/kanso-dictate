import Foundation
@preconcurrency import WhisperKit

/// Configuration for WhisperKit speech-to-text engine.
public struct WhisperKitConfig: Sendable, Equatable {
    /// Explicit local directory containing pre-downloaded or bundled model files (.mlmodelc).
    public var modelFolder: URL?

    /// Model variant identifier (e.g. "openai_whisper-base", "openai_whisper-small").
    public var modelVariant: String

    /// Base directory for caching downloaded models. Default: ~/Library/Application Support/KansoDictate/models.
    public var downloadBase: URL

    /// Standard Kanso Dictate model cache directory in ~/Library/Application Support/KansoDictate/models.
    public static var defaultDownloadBase: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        return appSupport.appendingPathComponent("KansoDictate/models", isDirectory: true).standardizedFileURL
    }

    /// Normalizes file URLs by expanding tilde prefixes and resolving relative paths.
    public static func normalizePathURL(_ url: URL) -> URL {
        let path = url.path
        if path.hasPrefix("~") {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return url.standardizedFileURL
    }

    public init(
        modelFolder: URL? = nil,
        modelVariant: String = "openai_whisper-base",
        downloadBase: URL = WhisperKitConfig.defaultDownloadBase
    ) {
        self.modelFolder = modelFolder.map { Self.normalizePathURL($0) }
        self.modelVariant = modelVariant
        self.downloadBase = Self.normalizePathURL(downloadBase)
    }

    /// Resolved model directory: explicit `modelFolder` if provided, otherwise the canonical Hub cache path under `downloadBase`.
    public var effectiveModelFolder: URL {
        if let folder = modelFolder {
            return folder
        }
        return downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelVariant, isDirectory: true)
            .standardizedFileURL
    }
}

/// Errors specific to WhisperKit transcription execution.
public enum WhisperTranscriberError: LocalizedError, Sendable, Equatable {
    case notInitialized
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit has not been initialized. Call initialize() first."
        case .modelNotFound(let path):
            return "WhisperKit model directory not found at path: \(path)"
        }
    }
}

/// Helper for extracting 16kHz mono normalized Float audio samples from WAV or raw PCM bytes.
public enum AudioDataParser {
    /// Extracts normalized 16kHz Float samples in [-1.0, 1.0] from WAV or linear 16-bit PCM.
    public static func extractFloatSamples(from data: Data) throws -> [Float] {
        guard !data.isEmpty else {
            throw STTError.emptyAudioData
        }

        // Detect RIFF/WAVE container
        if data.count >= 44,
           let riff = String(data: data.subdata(in: 0..<4), encoding: .utf8), riff == "RIFF",
           let wave = String(data: data.subdata(in: 8..<12), encoding: .utf8), wave == "WAVE" {
            // Locate "data" chunk
            if let dataRange = data.range(of: Data("data".utf8)) {
                let payloadStart = dataRange.upperBound + 4 // 4 bytes of chunk length
                if payloadStart < data.count {
                    let pcmData = data.subdata(in: payloadStart..<data.count)
                    return convertInt16ToFloatNormalized(pcmData: pcmData)
                }
            }
            // Fallback to standard 44-byte RIFF header
            if data.count > 44 {
                let pcmData = data.subdata(in: 44..<data.count)
                return convertInt16ToFloatNormalized(pcmData: pcmData)
            }
            return []
        }

        // Raw 16-bit PCM bytes
        return convertInt16ToFloatNormalized(pcmData: data)
    }

    /// Converts 16-bit signed integer linear PCM bytes into normalized [-1.0, 1.0] Float samples.
    public static func convertInt16ToFloatNormalized(pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            guard let int16Buffer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                floatSamples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }
        return floatSamples
    }
}

/// Background actor strictly isolating WhisperKit and Core ML inference off the MainActor.
public actor WhisperTranscriptionActor {
    private var whisperKit: WhisperKit?
    private var isInitializing: Bool = false

    public init() {}

    /// True if WhisperKit is loaded and ready for transcription.
    public var isReady: Bool {
        whisperKit != nil
    }

    /// Initializes WhisperKit with specified configuration off the MainActor.
    public func initialize(config: WhisperKitConfig) async throws {
        guard whisperKit == nil, !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )

        let resolvedModelFolder: String? = {
            if let customFolder = config.modelFolder?.path {
                return customFolder
            }
            if FileManager.default.fileExists(atPath: config.effectiveModelFolder.path) {
                return config.effectiveModelFolder.path
            }
            return nil
        }()

        let kit = try await WhisperKit(
            model: config.modelVariant,
            downloadBase: config.downloadBase,
            modelFolder: resolvedModelFolder,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        self.whisperKit = kit
    }

    /// Convenience initialization accepting config with labeled parameter `with`.
    public func initialize(with config: WhisperKitConfig) async throws {
        try await initialize(config: config)
    }

    /// Convenience initialization with model variant and download base directory.
    public func initialize(
        modelVariant: String = "openai_whisper-base",
        downloadBase: URL = WhisperKitConfig.defaultDownloadBase
    ) async throws {
        try await initialize(config: WhisperKitConfig(modelVariant: modelVariant, downloadBase: downloadBase))
    }

    /// Transcribes an array of 16kHz mono Float samples off the main thread.
    public func transcribe(
        audioSamples: [Float],
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        guard let whisperKit = self.whisperKit else {
            throw WhisperTranscriberError.notInitialized
        }

        guard !audioSamples.isEmpty else { return "" }

        var decodeOptions = DecodingOptions()
        decodeOptions.task = .transcribe
        decodeOptions.temperature = 0.0
        decodeOptions.skipSpecialTokens = true
        decodeOptions.withoutTimestamps = true

        if let language = language {
            decodeOptions.language = language
        }
        if let prompt = prompt, let tokenizer = whisperKit.tokenizer {
            decodeOptions.promptTokens = tokenizer.encode(text: prompt)
        }

        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: decodeOptions
        )

        let fullText = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return fullText
    }

    /// Unloads models to release Apple Neural Engine / GPU / unified memory resources.
    public func unload() async {
        if let whisperKit = self.whisperKit {
            await whisperKit.unloadModels()
            self.whisperKit = nil
        }
    }
}

/// Local on-device Speech-to-Text engine powered by WhisperKit and Apple Neural Engine.
public final class WhisperKitEngine: SpeechToTextEngine, Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = true
    public let config: WhisperKitConfig
    public let actor: WhisperTranscriptionActor

    public init(
        config: WhisperKitConfig = WhisperKitConfig(),
        actor: WhisperTranscriptionActor? = nil
    ) {
        self.config = config
        self.identifier = "whisperkit.\(config.modelVariant)"
        self.displayName = "Local Whisper (\(config.modelVariant))"
        self.actor = actor ?? WhisperTranscriptionActor()
    }

    /// Normalized, resolved model folder URL.
    public var effectiveModelFolder: URL {
        config.effectiveModelFolder
    }

    /// Transcribes raw audio bytes (16kHz mono WAV or 16-bit PCM).
    public func transcribe(
        audioData: Data,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }

        let floatSamples = try AudioDataParser.extractFloatSamples(from: audioData)
        guard !floatSamples.isEmpty else {
            throw STTError.emptyAudioData
        }

        return try await transcribe(samples: floatSamples, language: language, prompt: prompt)
    }

    /// Transcribes normalized 16kHz mono Float samples directly.
    public func transcribe(
        samples: [Float],
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        guard !samples.isEmpty else {
            throw STTError.emptyAudioData
        }

        let isReady = await actor.isReady
        if !isReady {
            try await actor.initialize(config: config)
        }

        let start = Date()
        let text = try await actor.transcribe(
            audioSamples: samples,
            language: language,
            prompt: prompt
        )
        let elapsed = Date().timeIntervalSince(start)

        return TranscriptionResult(
            text: text,
            durationSeconds: elapsed,
            engineIdentifier: identifier,
            timestamp: Date()
        )
    }
}
