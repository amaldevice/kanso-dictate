import Foundation
import AppKit
import KansoCore

private final class PipelineMockAudioRecorder: AudioRecordingService, @unchecked Sendable {
    var stubbedDuration: Double
    var isRecording: Bool = false
    var startCount = 0
    var stopCount = 0

    init(stubbedDuration: Double = 1.0) {
        self.stubbedDuration = stubbedDuration
    }

    func startRecording() throws {
        startCount += 1
        isRecording = true
    }

    func stopRecording() throws -> AudioRecording {
        stopCount += 1
        isRecording = false
        return AudioRecording(
            wavData: Data([0x52, 0x49, 0x46, 0x46]),
            samples: [0.0],
            durationSeconds: stubbedDuration
        )
    }
}

private final class ControllableSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    let identifier = "mock.controllable.stt"
    let displayName = "Mock Controllable STT"
    let isLocal = true

    private let lock = NSLock()
    private var continuations: [CheckedContinuation<TranscriptionResult, Error>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    private(set) var cancellationObserved: [Bool] = []

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                callCount += 1
                continuations.append(continuation)
                let waiters = startedWaiters
                startedWaiters.removeAll()
                lock.unlock()

                for waiter in waiters {
                    waiter.resume()
                }
            }
        } onCancel: {
            lock.lock()
            cancellationObserved.append(true)
            lock.unlock()
        }
    }

    func waitForCall(count expectedCount: Int) async {
        while currentCallCount() < expectedCount {
            await withCheckedContinuation { waiter in
                enqueueWaiterIfNeeded(expectedCount: expectedCount, waiter: waiter)
            }
        }
    }

    private func currentCallCount() -> Int {
        lock.withLock { callCount }
    }

    private func enqueueWaiterIfNeeded(
        expectedCount: Int,
        waiter: CheckedContinuation<Void, Never>
    ) {
        let shouldResumeImmediately = lock.withLock { () -> Bool in
            if callCount >= expectedCount {
                return true
            }
            startedWaiters.append(waiter)
            return false
        }
        if shouldResumeImmediately {
            waiter.resume()
        }
    }

    /// Resumes the Nth (0-indexed) transcription call with text, ignoring Task cancellation
    /// so tests verify the coordinator's generation guard even for non-cooperative engines.
    func resumeCall(at index: Int, with text: String) {
        lock.lock()
        let continuation = continuations[index]
        lock.unlock()
        continuation.resume(returning: TranscriptionResult(
            text: text,
            durationSeconds: 1.0,
            engineIdentifier: identifier,
            timestamp: Date()
        ))
    }

    func failCall(at index: Int, with error: Error) {
        lock.lock()
        let continuation = continuations[index]
        lock.unlock()
        continuation.resume(throwing: error)
    }

    var observedCancellations: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationObserved.count
    }
}

@MainActor
private func makeTestCoordinator(
    recorder: AudioRecordingService,
    engine: SpeechToTextEngine
) -> (coordinator: DictationCoordinator, historyStore: HistoryStore, cleanup: () -> Void) {
    let pasteboard = NSPasteboard.withUniqueName()
    let tempHistoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_pipeline_history_\(UUID().uuidString).json")
    let historyStore = HistoryStore(fileURL: tempHistoryURL)
    let injector = TextInjector(restoreDelayMs: 50, pasteboard: pasteboard)
    let coordinator = DictationCoordinator(
        recorder: recorder,
        injector: injector,
        historyStore: historyStore,
        activeEngine: engine
    )
    return (coordinator, historyStore, {
        try? FileManager.default.removeItem(at: tempHistoryURL)
    })
}

@MainActor
private func testStaleTranscriptionIgnoredWhenSupersededByNewCycle() async {
    let recorder = PipelineMockAudioRecorder(stubbedDuration: 1.0)
    let engine = ControllableSTTEngine()
    let (coordinator, historyStore, cleanup) = makeTestCoordinator(recorder: recorder, engine: engine)
    defer { cleanup() }

    // Cycle 1: start -> stop -> suspended in .transcribing
    coordinator.startDictation()
    assert(coordinator.state == .recording, "Cycle 1 should be recording")
    coordinator.stopDictation()
    assert(coordinator.state == .transcribing, "Cycle 1 should be transcribing")
    await engine.waitForCall(count: 1)

    // Cycle 2 supersedes Cycle 1 while Cycle 1 is still transcribing
    coordinator.startDictation()
    assert(coordinator.state == .recording, "Cycle 2 startDictation must supersede .transcribing and enter .recording")
    assert(engine.observedCancellations == 1, "Superseded Cycle 1 task must be cancelled")

    // Stale Cycle 1 finishes even though it was cancelled
    engine.resumeCall(at: 0, with: "Stale first transcript")
    try? await Task.sleep(nanoseconds: 50_000_000)

    assert(coordinator.state == .recording, "Stale Cycle 1 must NOT overwrite Cycle 2 .recording state; got \(coordinator.state)")
    assert(coordinator.lastTranscribedText.isEmpty, "Stale Cycle 1 must NOT overwrite lastTranscribedText")
    assert(historyStore.records.isEmpty, "Stale Cycle 1 must NOT append to history")

    // Complete Cycle 2
    coordinator.stopDictation()
    assert(coordinator.state == .transcribing, "Cycle 2 should enter .transcribing")
    await engine.waitForCall(count: 2)
    engine.resumeCall(at: 1, with: "Fresh second transcript")

    var waits = 0
    while waits < 50 && coordinator.state != .idle {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waits += 1
    }

    assert(coordinator.state == .idle, "Cycle 2 should complete and return to .idle; got \(coordinator.state)")
    assert(coordinator.lastTranscribedText == "Fresh second transcript", "lastTranscribedText should be Cycle 2 output")
    assert(historyStore.records.count == 1, "Only Cycle 2 should be recorded in history")
    assert(historyStore.records.first?.text == "Fresh second transcript")
}

@MainActor
private func testCancelDictationResetsAndIgnoresLateErrorAndResult() async {
    let recorder = PipelineMockAudioRecorder(stubbedDuration: 1.0)
    let engine = ControllableSTTEngine()
    let (coordinator, historyStore, cleanup) = makeTestCoordinator(recorder: recorder, engine: engine)
    defer { cleanup() }

    var notifiedErrors: [String] = []
    coordinator.onErrorNotification = { message in
        notifiedErrors.append(message)
    }

    // 1. Cancel during .recording stops recorder and resets to .idle
    coordinator.startDictation()
    assert(coordinator.state == .recording)
    assert(recorder.isRecording)
    coordinator.cancelDictation()
    assert(coordinator.state == .idle, "cancelDictation during .recording must return to .idle")
    assert(!recorder.isRecording, "cancelDictation must stop active recorder")

    // 2. Cancel during .transcribing cancels task and ignores late error
    coordinator.startDictation()
    coordinator.stopDictation()
    assert(coordinator.state == .transcribing)
    await engine.waitForCall(count: 1)

    coordinator.cancelDictation()
    assert(coordinator.state == .idle, "cancelDictation during .transcribing must return to .idle")
    assert(engine.observedCancellations == 1, "cancelDictation must cancel in-flight transcription task")

    engine.failCall(at: 0, with: STTError.networkError("Stale network failure"))
    try? await Task.sleep(nanoseconds: 50_000_000)

    assert(coordinator.state == .idle, "Late error from cancelled task must NOT enter .error; got \(coordinator.state)")
    assert(notifiedErrors.isEmpty, "Late error from cancelled task must NOT notify")

    // 3. Rapid micro-tap cycle after superseding an in-flight transcription ignores late success
    coordinator.startDictation()
    coordinator.stopDictation()
    assert(coordinator.state == .transcribing)
    await engine.waitForCall(count: 2)

    coordinator.startDictation()
    recorder.stubbedDuration = 0.1
    coordinator.stopDictation()
    assert(coordinator.state == .idle, "Micro-tap cycle must return to .idle")

    engine.resumeCall(at: 1, with: "Ghost transcript after micro-tap")
    try? await Task.sleep(nanoseconds: 50_000_000)

    assert(coordinator.state == .idle, "Stale task after rapid micro-tap cycle must stay .idle")
    assert(coordinator.lastTranscribedText.isEmpty, "Stale task must NOT set lastTranscribedText")
    assert(historyStore.records.isEmpty, "Stale task must NOT add history record")
}

@MainActor
private func testOutOfOrderCompletionAcrossRapidCycles() async {
    let recorder = PipelineMockAudioRecorder(stubbedDuration: 1.0)
    let engine = ControllableSTTEngine()
    let (coordinator, historyStore, cleanup) = makeTestCoordinator(recorder: recorder, engine: engine)
    defer { cleanup() }

    // Cycle 1 enters .transcribing
    coordinator.startDictation()
    coordinator.stopDictation()
    await engine.waitForCall(count: 1)

    // Cycle 2 supersedes Cycle 1 and also enters .transcribing
    coordinator.startDictation()
    coordinator.stopDictation()
    await engine.waitForCall(count: 2)

    // Cycle 2 finishes FIRST and transitions coordinator back to .idle
    engine.resumeCall(at: 1, with: "Cycle 2 won")
    var waits = 0
    while waits < 50 && coordinator.state != .idle {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waits += 1
    }
    assert(coordinator.state == .idle, "Cycle 2 should return coordinator to .idle")
    assert(coordinator.lastTranscribedText == "Cycle 2 won")
    assert(historyStore.records.count == 1)

    // Cycle 1 resolves AFTER Cycle 2 already completed
    engine.resumeCall(at: 0, with: "Cycle 1 late arrival")
    try? await Task.sleep(nanoseconds: 50_000_000)

    assert(coordinator.state == .idle, "Late Cycle 1 must NOT perturb .idle state")
    assert(coordinator.lastTranscribedText == "Cycle 2 won", "Late Cycle 1 must NOT overwrite Cycle 2 transcript")
    assert(historyStore.records.count == 1, "Late Cycle 1 must NOT append duplicate history record")
}

@MainActor
func runCoordinatorPipelineTests() async {
    await testStaleTranscriptionIgnoredWhenSupersededByNewCycle()
    print("✔ DictationCoordinator stale transcription superseded by new cycle verified")
    await testCancelDictationResetsAndIgnoresLateErrorAndResult()
    print("✔ DictationCoordinator cancelDictation and stale error/micro-tap ignoring verified")
    await testOutOfOrderCompletionAcrossRapidCycles()
    print("✔ DictationCoordinator out-of-order stale completion across rapid cycles verified")
}
