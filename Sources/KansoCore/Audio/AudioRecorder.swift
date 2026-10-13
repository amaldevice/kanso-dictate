import Foundation
import AVFoundation

/// Errors that can occur during audio recording operations.
public enum AudioRecorderError: Error, LocalizedError, Sendable {
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

/// Minimal, zero-disk-leak audio recorder using AVAudioEngine downsampled to 16kHz mono.
public final class AudioRecorder: @unchecked Sendable {
    private let audioEngine: AVAudioEngine
    private let lock = NSLock()
    private var accumulatedSamples: [Float] = []
    private var _isRecording = false
    private let targetSampleRate: Double = 16_000.0

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public init() {
        self.audioEngine = AVAudioEngine()
    }

    deinit {
        stopSilently()
    }

    /// Starts recording audio from the default input device downsampled to 16kHz mono.
    public func startRecording() throws {
        lock.lock()
        guard !_isRecording else {
            lock.unlock()
            throw AudioRecorderError.alreadyRecording
        }
        accumulatedSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

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

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }

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
                    self.accumulatedSamples.append(contentsOf: pointer)
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            lock.withLock {
                _isRecording = true
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }
    }

    /// Stops recording and returns the collected in-memory audio packaged as WAV and raw floats.
    public func stopRecording() throws -> AudioRecording {
        lock.lock()
        guard _isRecording else {
            lock.unlock()
            throw AudioRecorderError.notRecording
        }
        _isRecording = false
        let capturedSamples = accumulatedSamples
        accumulatedSamples.removeAll(keepingCapacity: false)
        lock.unlock()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let duration = Double(capturedSamples.count) / targetSampleRate
        let wavData = WAVWriter.createWAVData(from: capturedSamples, sampleRate: UInt32(targetSampleRate), channels: 1)

        return AudioRecording(
            wavData: wavData,
            samples: capturedSamples,
            durationSeconds: duration
        )
    }

    /// For testing: allows injecting audio samples into the buffer.
    public func appendSamplesForTesting(_ samples: [Float]) {
        lock.withLock {
            accumulatedSamples.append(contentsOf: samples)
        }
    }

    private func stopSilently() {
        lock.lock()
        defer { lock.unlock() }
        if _isRecording {
            _isRecording = false
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }
}
