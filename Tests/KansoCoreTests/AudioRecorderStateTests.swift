import Foundation
import AVFoundation
import KansoCore

private final class MockAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    var format: AVAudioFormat
    var startError: Error?
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var tapHandler: ((AVAudioPCMBuffer) -> Void)?
    var onStart: ((MockAudioCaptureEngine) -> Void)?
    var onRemoveTap: ((MockAudioCaptureEngine) -> Void)?
    var onStop: ((MockAudioCaptureEngine) -> Void)?

    init(
        sampleRate: Double = 16_000.0,
        channels: AVAudioChannelCount = 1
    ) {
        if sampleRate > 0 {
            self.format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )!
        } else {
            self.format = AVAudioFormat()
        }
    }

    func inputFormat() -> AVAudioFormat {
        lock.withLock { format }
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        lock.withLock {
            installTapCount += 1
            tapHandler = handler
        }
    }

    func removeTap() {
        let callback = lock.withLock { () -> ((MockAudioCaptureEngine) -> Void)? in
            removeTapCount += 1
            return onRemoveTap
        }
        callback?(self)
        lock.withLock {
            tapHandler = nil
        }
    }

    func prepare() {
        lock.withLock { prepareCount += 1 }
    }

    func start() throws {
        let callback = lock.withLock { () -> ((MockAudioCaptureEngine) -> Void)? in
            startCount += 1
            return onStart
        }
        callback?(self)
        if let startError {
            throw startError
        }
    }

    func stop() {
        let callback = lock.withLock { () -> ((MockAudioCaptureEngine) -> Void)? in
            stopCount += 1
            return onStop
        }
        callback?(self)
    }

    func emitBuffer(samples: [Float]) {
        let format = inputFormat()
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            fatalError("Failed to allocate AVAudioPCMBuffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for (index, value) in samples.enumerated() {
                channel[index] = value
            }
        }
        let handler = lock.withLock { tapHandler }
        handler?(buffer)
    }

    func currentTapHandler() -> ((AVAudioPCMBuffer) -> Void)? {
        lock.withLock { tapHandler }
    }
}

func runAudioRecorderStateTests() {
    // Slice 1: Initial state is .idle and stopRecording when idle throws .notRecording
    do {
        let engine = MockAudioCaptureEngine()
        let recorder = AudioRecorder(engine: engine)
        assert(recorder.state == .idle, "Expected initial state .idle, got \(recorder.state)")
        assert(!recorder.isRecording, "Expected isRecording == false when idle")

        do {
            _ = try recorder.stopRecording()
            assertionFailure("Expected stopRecording() to throw .notRecording when idle")
        } catch let error as AudioRecorderError {
            assert(error == .notRecording, "Expected .notRecording, got \(error)")
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
        assert(recorder.state == .idle, "State must remain .idle after failed stopRecording()")
    }
    print("✔ AudioRecorder initial .idle state and idle stop error verified")

    // Slice 2: Tap callbacks ignore buffers unless state == .recording
    do {
        let engine = MockAudioCaptureEngine()
        let recorder = AudioRecorder(engine: engine)
        var retainedTap: ((AVAudioPCMBuffer) -> Void)?

        engine.onStart = { mock in
            assert(recorder.state == .starting, "Expected .starting inside engine.start(), got \(recorder.state)")
            // Buffer arriving during .starting must be ignored
            mock.emitBuffer(samples: [0.25, 0.5])
            retainedTap = mock.currentTapHandler()
        }
        engine.onRemoveTap = { mock in
            assert(recorder.state == .stopping, "Expected .stopping inside removeTap(), got \(recorder.state)")
            // Late buffer arriving during .stopping must be ignored
            mock.emitBuffer(samples: [0.9, 0.9])
        }

        try recorder.startRecording()
        assert(recorder.state == .recording, "Expected .recording after startRecording()")
        assert(recorder.isRecording, "Expected isRecording == true")

        // Buffer arriving during .recording must be captured
        engine.emitBuffer(samples: [0.75, -0.5])

        let recording = try recorder.stopRecording()
        assert(recorder.state == .idle, "Expected .idle after stopRecording()")
        assert(!recorder.isRecording, "Expected isRecording == false after stopRecording()")
        assert(
            recording.samples == [0.75, -0.5],
            "Expected only .recording samples [0.75, -0.5], got \(recording.samples)"
        )

        // Late buffer arriving while .idle via retained tap closure must also be ignored
        let idleBuffer = AVAudioPCMBuffer(pcmFormat: engine.inputFormat(), frameCapacity: 2)!
        idleBuffer.frameLength = 2
        idleBuffer.floatChannelData?[0][0] = 0.42
        idleBuffer.floatChannelData?[0][1] = -0.42
        retainedTap?(idleBuffer)

        // Start a second session to verify idle buffer did not leak into next session
        engine.onStart = nil
        engine.onRemoveTap = nil
        try recorder.startRecording()
        let secondRecording = try recorder.stopRecording()
        assert(secondRecording.samples.isEmpty, "Idle tap buffer leaked into next recording: \(secondRecording.samples)")
    } catch {
        assertionFailure("Unexpected error in Slice 2: \(error)")
    }
    print("✔ AudioRecorder tap buffer gating outside .recording verified")

    // Slice 3: Any failure during startRecording() resets to .idle and removes any installed tap
    // 3a: Invalid hardware format (sampleRate == 0)
    do {
        let engine = MockAudioCaptureEngine(sampleRate: 0)
        let recorder = AudioRecorder(engine: engine)
        do {
            try recorder.startRecording()
            assertionFailure("Expected .invalidHardwareFormat")
        } catch let error as AudioRecorderError {
            assert(error == .invalidHardwareFormat, "Expected .invalidHardwareFormat, got \(error)")
        }
        assert(recorder.state == .idle, "State must reset to .idle on invalidHardwareFormat, got \(recorder.state)")
        assert(engine.installTapCount == 0 && engine.removeTapCount == 0, "Tap should not be installed/removed before tap setup")

        // Recovery after failure
        engine.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        try recorder.startRecording()
        assert(recorder.state == .recording, "Expected .recording after recovery")
        _ = try recorder.stopRecording()
        assert(recorder.state == .idle)
    } catch {
        assertionFailure("Unexpected error in Slice 3a: \(error)")
    }

    // 3b: Converter initialization failure
    do {
        let engine = MockAudioCaptureEngine()
        // Non-convertible format with sampleRate > 0 fails AVAudioConverter(from:to:)
        engine.format = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatTimeCode,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1
        ])!
        let recorder = AudioRecorder(engine: engine)
        do {
            try recorder.startRecording()
            assertionFailure("Expected .converterInitializationFailed")
        } catch let error as AudioRecorderError {
            assert(error == .converterInitializationFailed, "Expected .converterInitializationFailed, got \(error)")
        }
        assert(recorder.state == .idle, "State must reset to .idle on converterInitializationFailed, got \(recorder.state)")
        assert(engine.installTapCount == 0 && engine.removeTapCount == 0)
    } catch {
        assertionFailure("Unexpected error in Slice 3b: \(error)")
    }

    // 3c: engine.start() failure removes installed tap symmetrically and resets to .idle
    do {
        struct FakeEngineStartError: Error, LocalizedError {
            var errorDescription: String? { "simulated hardware failure" }
        }
        let engine = MockAudioCaptureEngine()
        engine.startError = FakeEngineStartError()
        let recorder = AudioRecorder(engine: engine)

        do {
            try recorder.startRecording()
            assertionFailure("Expected .engineFailedToStart")
        } catch let error as AudioRecorderError {
            if case .engineFailedToStart(let reason) = error {
                assert(reason.contains("simulated hardware failure"), "Unexpected reason: \(reason)")
            } else {
                assertionFailure("Expected .engineFailedToStart, got \(error)")
            }
        }
        assert(recorder.state == .idle, "State must reset to .idle on engineFailedToStart, got \(recorder.state)")
        assert(!recorder.isRecording)
        assert(engine.installTapCount == 1, "Expected 1 installTap call, got \(engine.installTapCount)")
        assert(engine.removeTapCount == 1, "Expected symmetric 1 removeTap call, got \(engine.removeTapCount)")

        // Recovery after engine start failure
        engine.startError = nil
        try recorder.startRecording()
        assert(recorder.state == .recording)
        _ = try recorder.stopRecording()
        assert(recorder.state == .idle)
    } catch {
        assertionFailure("Unexpected error in Slice 3c: \(error)")
    }
    print("✔ AudioRecorder startRecording() failure cleanup and .idle recovery verified")

    // Slice 4: Start/stop error invariants across .starting, .recording, and .stopping + deinit cleanup
    do {
        let engine = MockAudioCaptureEngine()
        let recorder = AudioRecorder(engine: engine)

        engine.onStart = { _ in
            assert(recorder.state == .starting)
            do {
                try recorder.startRecording()
                assertionFailure("Expected .alreadyRecording during .starting")
            } catch let error as AudioRecorderError {
                assert(error == .alreadyRecording, "Expected .alreadyRecording, got \(error)")
            } catch {
                assertionFailure("Unexpected error: \(error)")
            }
            assert(recorder.state == .starting, "State must remain .starting")

            do {
                _ = try recorder.stopRecording()
                assertionFailure("Expected .notRecording during .starting")
            } catch let error as AudioRecorderError {
                assert(error == .notRecording, "Expected .notRecording, got \(error)")
            } catch {
                assertionFailure("Unexpected error: \(error)")
            }
            assert(recorder.state == .starting, "State must remain .starting")
        }

        engine.onStop = { _ in
            assert(recorder.state == .stopping)
            do {
                try recorder.startRecording()
                assertionFailure("Expected .alreadyRecording during .stopping")
            } catch let error as AudioRecorderError {
                assert(error == .alreadyRecording, "Expected .alreadyRecording, got \(error)")
            } catch {
                assertionFailure("Unexpected error: \(error)")
            }
            assert(recorder.state == .stopping, "State must remain .stopping")

            do {
                _ = try recorder.stopRecording()
                assertionFailure("Expected .notRecording during .stopping")
            } catch let error as AudioRecorderError {
                assert(error == .notRecording, "Expected .notRecording, got \(error)")
            } catch {
                assertionFailure("Unexpected error: \(error)")
            }
            assert(recorder.state == .stopping, "State must remain .stopping")
        }

        try recorder.startRecording()
        assert(recorder.state == .recording)
        engine.emitBuffer(samples: [0.1, 0.2])

        // Re-entrant startRecording() while .recording throws .alreadyRecording and preserves samples
        do {
            try recorder.startRecording()
            assertionFailure("Expected .alreadyRecording during .recording")
        } catch let error as AudioRecorderError {
            assert(error == .alreadyRecording, "Expected .alreadyRecording, got \(error)")
        }
        assert(recorder.state == .recording)
        assert(engine.installTapCount == 1, "Tap must not be reinstalled on rejected start")

        let recording = try recorder.stopRecording()
        assert(recorder.state == .idle)
        assert(recording.samples == [0.1, 0.2], "Samples must survive rejected startRecording()")
        assert(engine.removeTapCount == 1)
        assert(engine.stopCount == 1)
    } catch {
        assertionFailure("Unexpected error in Slice 4a: \(error)")
    }

    // Slice 4b: deinit cleans up tap and engine when deallocated while .recording
    do {
        let engine = MockAudioCaptureEngine()
        do {
            let recorder = AudioRecorder(engine: engine)
            try recorder.startRecording()
            assert(recorder.state == .recording)
        }
        assert(engine.removeTapCount == 1, "Expected removeTap on deinit, got \(engine.removeTapCount)")
        assert(engine.stopCount == 1, "Expected stop on deinit, got \(engine.stopCount)")
    } catch {
        assertionFailure("Unexpected error in Slice 4b: \(error)")
    }
    print("✔ AudioRecorder start/stop state invariants and deinit cleanup verified")
}
