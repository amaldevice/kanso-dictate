import Foundation
import AppKit
import AudioToolbox

/// Observable state of the dictation pipeline.
public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(String)
}

/// Central coordinator driving audio recording, transcription, text injection, and persistence.
@MainActor
public final class DictationCoordinator: ObservableObject {
    @Published public private(set) var state: DictationState = .idle {
        didSet {
            if case .error(let message) = state {
                onErrorNotification?(message)
            }
        }
    }
    @Published public private(set) var lastTranscribedText: String = ""

    public var onErrorNotification: (@MainActor (String) -> Void)?
    public let recorder: any AudioRecordingService
    public let injector: TextInjector
    public let historyStore: HistoryStore
    @Published public var activeEngine: any SpeechToTextEngine

    public init(
        recorder: any AudioRecordingService = AudioRecorder(),
        injector: TextInjector = TextInjector(),
        historyStore: HistoryStore = HistoryStore()
    ) {
        self.recorder = recorder
        self.injector = injector
        self.historyStore = historyStore
        self.activeEngine = Self.makeEngineFromPreferences()
    }

    public init(
        recorder: any AudioRecordingService = AudioRecorder(),
        injector: TextInjector = TextInjector(),
        historyStore: HistoryStore = HistoryStore(),
        activeEngine: any SpeechToTextEngine
    ) {
        self.recorder = recorder
        self.injector = injector
        self.historyStore = historyStore
        self.activeEngine = activeEngine
    }

    /// Sets or switches the active speech-to-text engine dynamically.
    public func setEngine(_ newEngine: any SpeechToTextEngine) {
        self.activeEngine = newEngine
    }

    /// Factory method building an engine according to user preferences in `UserDefaults`.
    nonisolated public static func makeEngineFromPreferences(defaults: UserDefaults = .standard) -> any SpeechToTextEngine {
        let mode = defaults.string(forKey: "stt_provider_mode") ?? "remote"
        if mode == "local" {
            let variant = defaults.string(forKey: "whisperkit_model_variant") ?? "openai_whisper-base"
            let cachePath = defaults.string(forKey: "whisperkit_cache_directory")
            let downloadBase: URL
            if let cachePath = cachePath, !cachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                downloadBase = URL(fileURLWithPath: cachePath)
            } else {
                downloadBase = WhisperKitConfig.defaultDownloadBase
            }
            let config = WhisperKitConfig(
                modelVariant: variant,
                downloadBase: downloadBase
            )
            return WhisperKitEngine(config: config)
        } else {
            let baseURLStr = defaults.string(forKey: "stt_base_url") ?? "https://api.groq.com/openai/v1"
            let apiKey = defaults.string(forKey: "stt_api_key")
            let model = defaults.string(forKey: "stt_model") ?? "whisper-large-v3-turbo"
            let config = OpenAICompatibleConfig(
                baseURL: URL(string: baseURLStr) ?? URL(string: "https://api.groq.com/openai/v1")!,
                apiKey: (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? apiKey : nil,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "whisper-large-v3-turbo" : model
            )
            return OpenAICompatibleSTTEngine(config: config)
        }
    }

    /// Configures the active engine based on preferences in `UserDefaults`.
    public func configureEngineFromPreferences(defaults: UserDefaults = .standard) {
        setEngine(Self.makeEngineFromPreferences(defaults: defaults))
    }

    /// Starts audio recording for dictation.
    public func startDictation() {
        switch state {
        case .idle, .error:
            break
        default:
            return
        }

        if recorder.isRecording {
            _ = try? recorder.stopRecording()
        }
        do {
            try recorder.startRecording()
            state = .recording
            playFeedbackSound(named: "Tink", fallbackID: 1103)
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops audio recording, invokes STT engine, and injects transcribed text.
    public func stopDictation() {
        guard state == .recording else { return }

        do {
            let recording = try recorder.stopRecording()
            guard recording.durationSeconds >= 0.3 else {
                // Micro-tap guard: abort without error, alert, or STT invocation
                state = .idle
                return
            }

            playFeedbackSound(named: "Pop", fallbackID: 1104)
            state = .transcribing

            Task {
                do {
                    let result = try await activeEngine.transcribe(
                        audioData: recording.wavData,
                        language: nil,
                        prompt: nil
                    )

                    lastTranscribedText = result.text

                    if !result.text.isEmpty {
                        state = .inserting
                        try await injector.inject(text: result.text)

                        let record = HistoryRecord(
                            text: result.text,
                            durationSeconds: recording.durationSeconds,
                            engineIdentifier: result.engineIdentifier,
                            timestamp: Date()
                        )
                        historyStore.addRecord(record)
                    }

                    state = .idle
                } catch {
                    state = .error("Transcription/Injection failed: \(error.localizedDescription)")
                }
            }
        } catch {
            state = .error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    private func playFeedbackSound(named name: String, fallbackID: SystemSoundID) {
        if let sound = NSSound(named: name), sound.play() {
            return
        }
        AudioServicesPlaySystemSound(fallbackID)
    }

    private func ifCaseError(_ state: DictationState) -> Bool {
        if case .error = state { return true }
        return false
    }
}
