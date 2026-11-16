import Foundation
import KansoCore

private enum MockWhisperTestError: Error, Equatable {
    case loadFailed
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.withLock { value = newValue }
    }

    func get() -> Bool {
        lock.withLock { value }
    }
}

private final class MockWhisperRuntime: WhisperRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var _unloadCount = 0
    private var _transcribeCount = 0
    let transcript: String

    init(transcript: String = "mock transcript") {
        self.transcript = transcript
    }

    var unloadCount: Int {
        lock.withLock { _unloadCount }
    }

    var transcribeCount: Int {
        lock.withLock { _transcribeCount }
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        prompt: String?
    ) async throws -> String {
        lock.withLock { _transcribeCount += 1 }
        return transcript
    }

    func unloadModels() async {
        lock.withLock { _unloadCount += 1 }
    }
}

private actor AsyncLoadGate {
    private var loadCount = 0
    private var awaitingContinuationCount = 0
    private var startedWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var parkedLoaders: [CheckedContinuation<Result<any WhisperRuntime, Error>, Never>] = []

    func currentLoadCount() -> Int {
        loadCount
    }

    func waitUntilParked(count targetCount: Int = 1) async {
        if awaitingContinuationCount >= targetCount {
            return
        }
        await withCheckedContinuation { continuation in
            if awaitingContinuationCount >= targetCount {
                continuation.resume()
            } else {
                startedWaiters.append((targetCount, continuation))
            }
        }
    }

    func loader(_ config: WhisperKitConfig) async throws -> any WhisperRuntime {
        loadCount += 1
        let result = await awaitRelease()
        return try result.get()
    }

    private func awaitRelease() async -> Result<any WhisperRuntime, Error> {
        await withCheckedContinuation { continuation in
            parkedLoaders.append(continuation)
            awaitingContinuationCount += 1
            let current = awaitingContinuationCount
            var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
            for waiter in startedWaiters {
                if current >= waiter.target {
                    waiter.continuation.resume()
                } else {
                    remaining.append(waiter)
                }
            }
            startedWaiters = remaining
        }
    }

    func releaseNext(with result: Result<any WhisperRuntime, Error>) {
        precondition(!parkedLoaders.isEmpty, "No loader parked on gate")
        let continuation = parkedLoaders.removeFirst()
        continuation.resume(returning: result)
    }
}

func runWhisperActorStateTests() async throws {
    try await testBasicLifecycleAndUnload()
    try await testConcurrentInitializeAndTranscribeCoalescing()
    try await testWhisperKitEngineConcurrentTranscribeCoalescing()
    try await testSharedErrorPropagationAndRecovery()
    try await testUnloadAndReinitializationLifecycle()
    print("✔ WhisperTranscriptionActor state lifecycle and coalescing verified")
}

private func testBasicLifecycleAndUnload() async throws {
    let runtime = MockWhisperRuntime(transcript: "hello world")
    let actor = WhisperTranscriptionActor { _ in runtime }

    let initialReady = await actor.isReady
    assert(!initialReady, "Actor must start uninitialized")

    // Unload while uninitialized is a no-op
    await actor.unload()
    let readyAfterIdleUnload = await actor.isReady
    assert(!readyAfterIdleUnload, "Actor must remain uninitialized after unload")

    // Transcribe while uninitialized throws .notInitialized
    do {
        _ = try await actor.transcribe(audioSamples: [0.1, 0.2])
        assertionFailure("Expected .notInitialized when uninitialized")
    } catch let error as WhisperTranscriberError {
        assert(error == .notInitialized, "Expected .notInitialized, got \(error)")
    }

    // Initialize transitions to ready
    try await actor.initialize(config: WhisperKitConfig())
    let readyAfterInit = await actor.isReady
    assert(readyAfterInit, "Actor must be ready after initialize()")

    let text = try await actor.transcribe(audioSamples: [0.1, 0.2])
    assert(text == "hello world", "Expected mock transcript, got \(text)")
    assert(runtime.transcribeCount == 1, "Runtime transcribe should be called once")

    // Unload transitions back to uninitialized and calls unloadModels()
    await actor.unload()
    let readyAfterUnload = await actor.isReady
    assert(!readyAfterUnload, "Actor must not be ready after unload()")
    assert(runtime.unloadCount == 1, "Runtime unloadModels() must be called once")

    do {
        _ = try await actor.transcribe(audioSamples: [0.1, 0.2])
        assertionFailure("Expected .notInitialized after unload()")
    } catch let error as WhisperTranscriberError {
        assert(error == .notInitialized, "Expected .notInitialized after unload, got \(error)")
    }
}

private func testConcurrentInitializeAndTranscribeCoalescing() async throws {
    let gate = AsyncLoadGate()
    let runtime = MockWhisperRuntime(transcript: "coalesced transcript")
    let actor = WhisperTranscriptionActor { config in
        try await gate.loader(config)
    }

    let caller1 = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 1)

    let caller2Finished = AtomicFlag()
    let caller2 = Task {
        try await actor.initialize(config: WhisperKitConfig())
        caller2Finished.set(true)
    }

    let caller3Finished = AtomicFlag()
    let caller3 = Task { () -> String in
        let text = try await actor.transcribe(audioSamples: [0.1, 0.2])
        caller3Finished.set(true)
        return text
    }

    try await Task.sleep(nanoseconds: 25_000_000)
    let readyWhileInitializing = await actor.isReady
    let loadsWhileInitializing = await gate.currentLoadCount()
    assert(!readyWhileInitializing, "Actor must not report ready while initializing")
    assert(!caller2Finished.get(), "Concurrent initialize() must wait for in-flight load")
    assert(!caller3Finished.get(), "Concurrent transcribe() must wait for in-flight load")
    assert(loadsWhileInitializing == 1, "Loader must be invoked only once")

    await gate.releaseNext(with: .success(runtime))

    try await caller1.value
    try await caller2.value
    let transcribed = try await caller3.value

    let loadsAfterFinish = await gate.currentLoadCount()
    let readyAfterLoad = await actor.isReady
    assert(caller2Finished.get(), "Concurrent initialize() must finish after load")
    assert(caller3Finished.get(), "Concurrent transcribe() must finish after load")
    assert(transcribed == "coalesced transcript", "Expected coalesced transcript, got \(transcribed)")
    assert(runtime.transcribeCount == 1, "Expected 1 transcription on shared runtime")
    assert(loadsAfterFinish == 1, "Loader must still have been invoked only once")
    assert(readyAfterLoad, "Actor must be ready after coalesced load")
}

private func testWhisperKitEngineConcurrentTranscribeCoalescing() async throws {
    let gate = AsyncLoadGate()
    let runtime = MockWhisperRuntime(transcript: "engine transcript")
    let actor = WhisperTranscriptionActor { config in
        try await gate.loader(config)
    }
    let engine = WhisperKitEngine(config: WhisperKitConfig(), actor: actor)

    let t1 = Task {
        try await engine.transcribe(samples: [0.1, 0.2])
    }
    await gate.waitUntilParked(count: 1)

    let t2 = Task {
        try await engine.transcribe(samples: [0.3, 0.4])
    }
    let t3 = Task {
        try await engine.transcribe(samples: [0.5, 0.6])
    }

    try await Task.sleep(nanoseconds: 25_000_000)
    let loadsWhileParked = await gate.currentLoadCount()
    assert(loadsWhileParked == 1, "Engine concurrent calls must coalesce to single model load")

    await gate.releaseNext(with: .success(runtime))

    let r1 = try await t1.value
    let r2 = try await t2.value
    let r3 = try await t3.value

    let loadsAfterFinish = await gate.currentLoadCount()
    assert(r1.text == "engine transcript")
    assert(r2.text == "engine transcript")
    assert(r3.text == "engine transcript")
    assert(runtime.transcribeCount == 3, "All 3 concurrent engine calls must transcribe")
    assert(loadsAfterFinish == 1, "Loader must be called only once across concurrent engine calls")
}

private func testSharedErrorPropagationAndRecovery() async throws {
    let gate = AsyncLoadGate()
    let actor = WhisperTranscriptionActor { config in
        try await gate.loader(config)
    }

    let initCaller1 = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 1)

    let initCaller2 = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    let transcribeCaller = Task {
        try await actor.transcribe(audioSamples: [0.1, 0.2])
    }

    try await Task.sleep(nanoseconds: 25_000_000)
    await gate.releaseNext(with: .failure(MockWhisperTestError.loadFailed))

    for task in [initCaller1, initCaller2] {
        do {
            try await task.value
            assertionFailure("Expected shared load error on concurrent initialize()")
        } catch let error as MockWhisperTestError {
            assert(error == .loadFailed, "Expected .loadFailed, got \(error)")
        }
    }

    do {
        _ = try await transcribeCaller.value
        assertionFailure("Expected shared load error on concurrent transcribe()")
    } catch let error as MockWhisperTestError {
        assert(error == .loadFailed, "Expected .loadFailed on transcribe(), got \(error)")
    }

    let readyAfterFailure = await actor.isReady
    assert(!readyAfterFailure, "Actor must return to uninitialized after failed load")

    // Transcribe after failure (no load in flight) throws .notInitialized
    do {
        _ = try await actor.transcribe(audioSamples: [0.1, 0.2])
        assertionFailure("Expected .notInitialized after failed initialization")
    } catch let error as WhisperTranscriberError {
        assert(error == .notInitialized, "Expected .notInitialized, got \(error)")
    }

    // Subsequent initialization attempt recovers cleanly
    let recoveredRuntime = MockWhisperRuntime(transcript: "recovered")
    let retryTask = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 2)
    await gate.releaseNext(with: .success(recoveredRuntime))
    try await retryTask.value

    let readyAfterRecovery = await actor.isReady
    assert(readyAfterRecovery, "Actor must recover and become ready on subsequent initialize()")
    let recoveredText = try await actor.transcribe(audioSamples: [0.1, 0.2])
    let totalLoads = await gate.currentLoadCount()
    assert(recoveredText == "recovered", "Expected recovered transcript, got \(recoveredText)")
    assert(totalLoads == 2, "Loader should have been invoked twice (initial failure + retry)")
}

private func testUnloadAndReinitializationLifecycle() async throws {
    let gate = AsyncLoadGate()
    let actor = WhisperTranscriptionActor { config in
        try await gate.loader(config)
    }

    // 1. Initialize -> Unload -> Re-initialize
    let firstRuntime = MockWhisperRuntime(transcript: "first")
    let firstInit = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 1)
    await gate.releaseNext(with: .success(firstRuntime))
    try await firstInit.value

    let firstText = try await actor.transcribe(audioSamples: [0.1])
    assert(firstText == "first")
    await actor.unload()
    assert(firstRuntime.unloadCount == 1, "First runtime must be unloaded")
    let readyAfterUnload = await actor.isReady
    assert(!readyAfterUnload, "Actor must be uninitialized after unload")

    // 2. Unload while initialization is in-flight cleans up late-arriving runtime and stays uninitialized
    let orphanedRuntime = MockWhisperRuntime(transcript: "orphaned")
    let cancelledInit = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 2)

    await actor.unload()
    let readyAfterMidInitUnload = await actor.isReady
    assert(!readyAfterMidInitUnload, "Actor must be uninitialized after mid-init unload")

    await gate.releaseNext(with: .success(orphanedRuntime))
    do {
        try await cancelledInit.value
        assertionFailure("In-flight initialize() invalidated by unload() should not succeed silently")
    } catch {
        // Expected CancellationError
    }

    assert(orphanedRuntime.unloadCount == 1, "Orphaned runtime finishing after unload() must be unloaded")
    let readyAfterOrphanCleanup = await actor.isReady
    assert(!readyAfterOrphanCleanup, "Actor must remain uninitialized after orphaned load cleanup")

    // 3. Subsequent re-initialization succeeds cleanly
    let thirdRuntime = MockWhisperRuntime(transcript: "reinitialized")
    let reinit = Task {
        try await actor.initialize(config: WhisperKitConfig())
    }
    await gate.waitUntilParked(count: 3)
    await gate.releaseNext(with: .success(thirdRuntime))
    try await reinit.value

    let readyAfterReinit = await actor.isReady
    let reinitText = try await actor.transcribe(audioSamples: [0.1])
    let totalLoads = await gate.currentLoadCount()
    assert(readyAfterReinit, "Actor must be ready after re-initialization")
    assert(reinitText == "reinitialized")
    assert(totalLoads == 3, "Expected 3 total loads across lifecycle")
}
