import Foundation
import AVFoundation

/// Errors that can occur during audio recording operations.
public enum AudioRecorderError: Error, LocalizedError, Sendable, Equatable {
    case invalidHardwareFormat
    case converterInitializationFailed
    case conversionFailed(String)
    case engineFailedToStart(String)
    case notRecording
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .invalidHardwareFormat:
            return "Microphone hardware format is invalid or sample rate is zero."
        case .converterInitializationFailed:
            return "Failed to initialize AVAudioConverter from hardware format to 16kHz mono."
        case .conversionFailed(let reason):
            return "Audio format conversion failed: \(reason)"
        case .engineFailedToStart(let reason):
            return "AVAudioEngine failed to start: \(reason)"
        case .notRecording:
            return "AudioRecorder is not currently recording."
        case .alreadyRecording:
            return "AudioRecorder is already recording."
        }
    }
}

/// Thread-safe in-memory audio recording result.
public struct AudioRecording: Sendable {
    /// Canonical 16-bit 16kHz mono WAV container bytes in memory.
    public let wavData: Data
    /// Raw 32-bit floating point samples [-1.0, 1.0] at 16kHz (for WhisperKit).
    public let samples: [Float]
    /// Recorded audio duration in seconds.
    public let durationSeconds: Double

    public init(wavData: Data, samples: [Float], durationSeconds: Double) {
        self.wavData = wavData
        self.samples = samples
        self.durationSeconds = durationSeconds
    }
}

/// Explicit capture lifecycle states for `AudioRecorder`.
public enum AudioRecorderState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
}

/// Abstraction over `AVAudioEngine` input capture for deterministic testing.
public protocol AudioCaptureEngine: AnyObject, Sendable {
    func inputFormat() -> AVAudioFormat
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

private final class SystemAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()

    func inputFormat() -> AVAudioFormat {
        audioEngine.inputNode.inputFormat(forBus: 0)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    func removeTap() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        audioEngine.prepare()
    }

    func start() throws {
        try audioEngine.start()
    }

    func stop() {
        audioEngine.stop()
    }
}

/// Minimal, zero-disk-leak audio recorder using AVAudioEngine downsampled to 16kHz mono.
public final class AudioRecorder: @unchecked Sendable {
    private let engine: any AudioCaptureEngine
    private let lock = NSLock()
    private var accumulatedSamples: [Float] = []
    private var _state: AudioRecorderState = .idle
    private let targetSampleRate: Double = 16_000.0

    public var state: AudioRecorderState {
        lock.withLock { _state }
    }

    public var isRecording: Bool {
        lock.withLock { _state == .recording }
    }

    public convenience init() {
        self.init(engine: SystemAudioCaptureEngine())
    }

    public init(engine: any AudioCaptureEngine) {
        self.engine = engine
    }

    deinit {
        stopSilently()
    }

    /// Starts recording audio from the default input device downsampled to 16kHz mono.
    public func startRecording() throws {
        lock.lock()
        guard _state == .idle else {
            lock.unlock()
            throw AudioRecorderError.alreadyRecording
        }
        _state = .starting
        accumulatedSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        var tapInstalled = false
        var didTransitionToRecording = false
        defer {
            if !didTransitionToRecording {
                if tapInstalled {
                    engine.removeTap()
                }
                lock.withLock {
                    _state = .idle
                    accumulatedSamples.removeAll(keepingCapacity: false)
                }
            }
        }

        let hardwareFormat = engine.inputFormat()

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidHardwareFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.converterInitializationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioRecorderError.converterInitializationFailed
        }

        engine.installTap(bufferSize: 1024, format: hardwareFormat) { [weak self] buffer in
            guard let self else { return }
            guard self.lock.withLock({ self._state == .recording }) else { return }

            let ratio = self.targetSampleRate / hardwareFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 128
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            var hasSuppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if hasSuppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasSuppliedInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status != .error, let channelData = convertedBuffer.floatChannelData?[0] {
                let frameCount = Int(convertedBuffer.frameLength)
                let pointer = UnsafeBufferPointer(start: channelData, count: frameCount)
                self.lock.withLock {
                    guard self._state == .recording else { return }
                    self.accumulatedSamples.append(contentsOf: pointer)
                }
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            lock.withLock {
                _state = .recording
            }
            didTransitionToRecording = true
        } catch {
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }
    }

    /// Stops recording and returns the collected in-memory audio packaged as WAV and raw floats.
    public func stopRecording() throws -> AudioRecording {
        lock.lock()
        guard _state == .recording else {
            lock.unlock()
            throw AudioRecorderError.notRecording
        }
        _state = .stopping
        let capturedSamples = accumulatedSamples
        accumulatedSamples.removeAll(keepingCapacity: false)
        lock.unlock()

        teardownCapture()

        let duration = Double(capturedSamples.count) / targetSampleRate
        let wavData = WAVWriter.createWAVData(from: capturedSamples, sampleRate: UInt32(targetSampleRate), channels: 1)

        return AudioRecording(
            wavData: wavData,
            samples: capturedSamples,
            durationSeconds: duration
        )
    }

    private func stopSilently() {
        let shouldStop = lock.withLock { () -> Bool in
            guard _state == .recording else { return false }
            _state = .stopping
            return true
        }
        if shouldStop {
            teardownCapture()
        }
    }

    private func teardownCapture() {
        engine.removeTap()
        engine.stop()
        lock.withLock {
            _state = .idle
        }
    }
}
