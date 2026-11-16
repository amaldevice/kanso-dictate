import Foundation
import KansoCore

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class BatchPollingStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let req = request
        let client = self.client
        let handler = Self.requestHandler
        Task {
            do {
                guard let handler else {
                    throw URLError(.unknown)
                }
                let (response, data) = try await handler(req)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private func makeBatchPollingStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BatchPollingStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func stubHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

func runBatchJobPollingTests() async throws {
    try await testSharedPollingProgression()
    print("✔ BatchJobPoller shared polling progression verified")

    await testTerminalFailureHandling()
    print("✔ BatchJobPoller terminal failure handling verified")

    await testTimeoutExhaustion()
    print("✔ BatchJobPoller timeout exhaustion verified")

    await testTaskCancellation()
    print("✔ BatchJobPoller task cancellation verified")

    try await testBatchJobSendHelper()
    print("✔ BatchJobPoller HTTP send and cancellation verified")

    try await testEngineMultiPollAndCancellation()
    print("✔ AssemblyAI, Speechmatics, and Rev.ai batch polling & cancellation verified")
}

private func testSharedPollingProgression() async throws {
    let states = LockedBox<[BatchJobState]>([])
    let pollCalls = LockedBox<Int>(0)
    let sleepDurations = LockedBox<[UInt64]>([])

    let result: String = try await BatchJobPoller.run(
        pollInterval: 0.25,
        maxPollAttempts: 3,
        sleep: { nanoseconds in
            sleepDurations.withLock { $0.append(nanoseconds) }
        },
        onStateChange: { state in
            states.withLock { $0.append(state) }
        },
        submit: {
            "job-42"
        },
        poll: { jobID -> BatchJobPollOutcome<String> in
            assert(jobID == "job-42", "Poll must receive submitted job ID")
            let attempt = pollCalls.withLock {
                $0 += 1
                return $0
            }
            if attempt == 1 {
                return .pending
            }
            return .ready("payload-\(jobID)")
        },
        fetch: { jobID, payload in
            assert(jobID == "job-42", "Fetch must receive submitted job ID")
            assert(payload == "payload-job-42", "Fetch must receive ready payload")
            return "final-transcript"
        },
        timeoutError: { attempts in
            STTError.networkError("timed out after \(attempts)")
        }
    )

    assert(result == "final-transcript", "Expected final transcript, got \(result)")
    let recordedStates = states.withLock { $0 }
    assert(
        recordedStates == [.submitting, .polling(attempt: 1), .polling(attempt: 2), .fetching, .completed],
        "Unexpected state progression: \(recordedStates)"
    )
    let sleeps = sleepDurations.withLock { $0 }
    assert(sleeps == [250_000_000], "Expected 1 sleep of 250ms between polls, got \(sleeps)")
}

private func testTerminalFailureHandling() async {
    // 1. Submit failure transitions submitting -> failed and skips poll/fetch/sleep
    do {
        let states = LockedBox<[BatchJobState]>([])
        let pollCalled = LockedBox<Bool>(false)
        let fetchCalled = LockedBox<Bool>(false)

        do {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.1,
                maxPollAttempts: 3,
                sleep: { _ in assertionFailure("Sleep must not run on submit failure") },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { throw STTError.httpError(statusCode: 401, message: "bad key") },
                poll: { (_: String) -> BatchJobPollOutcome<String> in
                    pollCalled.withLock { $0 = true }
                    return .pending
                },
                fetch: { _, _ in
                    fetchCalled.withLock { $0 = true }
                    return ""
                },
                timeoutError: { STTError.networkError("timeout \($0)") }
            )
            assertionFailure("Expected submit error")
        } catch let error as STTError {
            assert(error == .httpError(statusCode: 401, message: "bad key"), "Unexpected submit error: \(error)")
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        assert(states.withLock { $0 } == [.submitting, .failed], "Expected [.submitting, .failed]")
        assert(!pollCalled.withLock { $0 }, "Poll must not run after submit failure")
        assert(!fetchCalled.withLock { $0 }, "Fetch must not run after submit failure")
    }

    // 2. Poll failure on attempt 2 transitions submitting -> polling(1) -> polling(2) -> failed
    do {
        let states = LockedBox<[BatchJobState]>([])
        let pollAttempts = LockedBox<Int>(0)
        let fetchCalled = LockedBox<Bool>(false)
        let sleepCount = LockedBox<Int>(0)

        do {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.1,
                maxPollAttempts: 3,
                sleep: { _ in sleepCount.withLock { $0 += 1 } },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { "job-99" },
                poll: { (_: String) -> BatchJobPollOutcome<String> in
                    let attempt = pollAttempts.withLock { $0 += 1; return $0 }
                    if attempt == 1 { return .pending }
                    throw STTError.httpError(statusCode: 500, message: "job failed")
                },
                fetch: { _, _ in
                    fetchCalled.withLock { $0 = true }
                    return ""
                },
                timeoutError: { STTError.networkError("timeout \($0)") }
            )
            assertionFailure("Expected poll failure")
        } catch let error as STTError {
            assert(error == .httpError(statusCode: 500, message: "job failed"), "Unexpected poll error: \(error)")
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        assert(
            states.withLock { $0 } == [.submitting, .polling(attempt: 1), .polling(attempt: 2), .failed],
            "Unexpected states on poll failure"
        )
        assert(sleepCount.withLock { $0 } == 1, "Expected 1 sleep before attempt 2")
        assert(!fetchCalled.withLock { $0 }, "Fetch must not run after poll failure")
    }

    // 3. Fetch failure transitions submitting -> polling(1) -> fetching -> failed
    do {
        let states = LockedBox<[BatchJobState]>([])

        do {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.1,
                maxPollAttempts: 3,
                sleep: { _ in },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { "job-100" },
                poll: { (_: String) -> BatchJobPollOutcome<String> in .ready("ok") },
                fetch: { _, _ in throw STTError.decodingError("missing text") },
                timeoutError: { STTError.networkError("timeout \($0)") }
            )
            assertionFailure("Expected fetch failure")
        } catch let error as STTError {
            assert(error == .decodingError("missing text"), "Unexpected fetch error: \(error)")
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        assert(
            states.withLock { $0 } == [.submitting, .polling(attempt: 1), .fetching, .failed],
            "Unexpected states on fetch failure"
        )
    }
}

private func testTimeoutExhaustion() async {
    // 1. Exhausts maxPollAttempts = 3 with 2 sleeps and transitions to .timedOut
    do {
        let states = LockedBox<[BatchJobState]>([])
        let sleepCount = LockedBox<Int>(0)

        do {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.05,
                maxPollAttempts: 3,
                sleep: { _ in sleepCount.withLock { $0 += 1 } },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { "job-slow" },
                poll: { (_: String) -> BatchJobPollOutcome<String> in .pending },
                fetch: { _, _ in
                    assertionFailure("Fetch must not run on timeout")
                    return ""
                },
                timeoutError: { STTError.networkError("Timed out after \($0) polls.") }
            )
            assertionFailure("Expected timeout error")
        } catch let error as STTError {
            assert(error == .networkError("Timed out after 3 polls."), "Unexpected timeout error: \(error)")
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        assert(
            states.withLock { $0 } == [.submitting, .polling(attempt: 1), .polling(attempt: 2), .polling(attempt: 3), .timedOut],
            "Unexpected states on timeout exhaustion"
        )
        assert(sleepCount.withLock { $0 } == 2, "Must sleep only between attempts (2 times for 3 attempts)")
    }

    // 2. maxPollAttempts = 0 immediately transitions submitting -> timedOut without polling
    do {
        let states = LockedBox<[BatchJobState]>([])
        let pollCalled = LockedBox<Bool>(false)

        do {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.05,
                maxPollAttempts: 0,
                sleep: { _ in assertionFailure("Must not sleep when maxPollAttempts == 0") },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { "job-zero" },
                poll: { (_: String) -> BatchJobPollOutcome<String> in
                    pollCalled.withLock { $0 = true }
                    return .pending
                },
                fetch: { _, _ in "" },
                timeoutError: { STTError.networkError("Timed out after \($0) polls.") }
            )
            assertionFailure("Expected timeout error for 0 maxPollAttempts")
        } catch let error as STTError {
            assert(error == .networkError("Timed out after 0 polls."), "Unexpected error: \(error)")
        } catch {
            assertionFailure("Unexpected error type: \(error)")
        }

        assert(states.withLock { $0 } == [.submitting, .timedOut], "Expected [.submitting, .timedOut]")
        assert(!pollCalled.withLock { $0 }, "Poll must not run when maxPollAttempts == 0")
    }
}

private func testTaskCancellation() async {
    // 1. Pre-cancelled task aborts before submit and transitions submitting -> failed
    do {
        let states = LockedBox<[BatchJobState]>([])
        let submitCalled = LockedBox<Bool>(false)

        let task = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 50_000_000)
            let _: String = try await BatchJobPoller.run(
                pollInterval: 0.1,
                maxPollAttempts: 3,
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: {
                    submitCalled.withLock { $0 = true }
                    return "job-cancel-early"
                },
                poll: { (_: String) -> BatchJobPollOutcome<String> in .pending },
                fetch: { _, _ in "" },
                timeoutError: { STTError.networkError("timeout \($0)") }
            )
        }
        task.cancel()

        do {
            try await task.value
            assertionFailure("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            assertionFailure("Expected CancellationError, got \(error)")
        }
        assert(!submitCalled.withLock { $0 }, "Submit must not run when task is already cancelled")
    }

    // 2. Cancellation during sleep between polls propagates CancellationError (not swallowed as timeout)
    do {
        let states = LockedBox<[BatchJobState]>([])
        let pollAttempts = LockedBox<Int>(0)
        let enteredSleep = LockedBox<CheckedContinuation<Void, Never>?>(nil)

        let task = Task<Void, Error> {
            let _: String = try await BatchJobPoller.run(
                pollInterval: 5.0,
                maxPollAttempts: 3,
                sleep: { nanoseconds in
                    await withCheckedContinuation { continuation in
                        enteredSleep.withLock { $0 = continuation }
                    }
                    try await Task.sleep(nanoseconds: nanoseconds)
                },
                onStateChange: { state in states.withLock { $0.append(state) } },
                submit: { "job-cancel-sleep" },
                poll: { (_: String) -> BatchJobPollOutcome<String> in
                    pollAttempts.withLock { $0 += 1 }
                    return .pending
                },
                fetch: { _, _ in "" },
                timeoutError: { STTError.networkError("timeout \($0)") }
            )
        }

        while enteredSleep.withLock({ $0 == nil }) {
            await Task.yield()
        }
        task.cancel()
        enteredSleep.withLock {
            $0?.resume()
            $0 = nil
        }

        do {
            try await task.value
            assertionFailure("Expected CancellationError during sleep")
        } catch is CancellationError {
        } catch {
            assertionFailure("Expected CancellationError, got \(error)")
        }

        assert(pollAttempts.withLock { $0 } == 1, "Must stop after first poll when cancelled during sleep")
        assert(
            states.withLock { $0 } == [.submitting, .polling(attempt: 1), .failed],
            "Expected [.submitting, .polling(attempt: 1), .failed], got \(states.withLock { $0 })"
        )
    }
}

private func testBatchJobSendHelper() async throws {
    let session = makeBatchPollingStubSession()
    let testURL = URL(string: "https://example.com/jobs")!

    // 1. 2xx response returns raw Data
    BatchPollingStubURLProtocol.requestHandler = { request in
        (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"ok\"}".utf8))
    }
    let okData = try await BatchJobPoller.send(
        URLRequest(url: testURL),
        using: session,
        parseErrorMessage: { _, code in "err \(code)" },
        mapHTTPError: { code, msg in .httpError(statusCode: code, message: msg) }
    )
    assert(String(data: okData, encoding: .utf8) == "{\"id\":\"ok\"}", "Unexpected response body")

    // 2. Non-2xx maps via parseErrorMessage + mapHTTPError
    BatchPollingStubURLProtocol.requestHandler = { request in
        (stubHTTPResponse(url: request.url!, status: 429), Data("slow down".utf8))
    }
    do {
        _ = try await BatchJobPoller.send(
            URLRequest(url: testURL),
            using: session,
            parseErrorMessage: { data, _ in String(data: data, encoding: .utf8) ?? "" },
            mapHTTPError: { code, msg in .httpError(statusCode: code, message: "quota: \(msg)") }
        )
        assertionFailure("Expected mapped HTTP error")
    } catch let error as STTError {
        assert(error == .httpError(statusCode: 429, message: "quota: slow down"), "Unexpected HTTP error: \(error)")
    }

    // 3. Cancellation while request is in flight throws CancellationError
    let startedRequest = LockedBox<Bool>(false)
    BatchPollingStubURLProtocol.requestHandler = { request in
        startedRequest.withLock { $0 = true }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return (stubHTTPResponse(url: request.url!, status: 200), Data())
    }
    let task = Task<Data, Error> {
        try await BatchJobPoller.send(
            URLRequest(url: testURL),
            using: session,
            parseErrorMessage: { _, _ in "" },
            mapHTTPError: { code, msg in .httpError(statusCode: code, message: msg) }
        )
    }
    while !startedRequest.withLock({ $0 }) {
        await Task.yield()
    }
    task.cancel()
    do {
        _ = try await task.value
        assertionFailure("Expected CancellationError for cancelled HTTP request")
    } catch is CancellationError {
    }
}

private func testEngineMultiPollAndCancellation() async throws {
    let session = makeBatchPollingStubSession()
    let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])

    // 1. AssemblyAI multi-poll progression (pending -> completed) + cancellation
    do {
        let engine = AssemblyAISTTEngine(
            config: AssemblyAISTTConfig(apiKey: "aai-key", pollInterval: 0.01, maxPollAttempts: 3),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/v1/upload" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"upload_url\":\"https://example.com/a.wav\"}".utf8))
            } else if path == "/v1/transcript" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_1\",\"status\":\"queued\"}".utf8))
            } else {
                let attempt = pollAttempts.withLock { $0 += 1; return $0 }
                if attempt == 1 {
                    return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_1\",\"status\":\"processing\"}".utf8))
                }
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_1\",\"status\":\"completed\",\"text\":\"multi poll ok\",\"audio_duration\":1.2}".utf8))
            }
        }
        let result = try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        assert(result.text == "multi poll ok", "AssemblyAI multi-poll text mismatch")
        assert(pollAttempts.withLock { $0 } == 2, "Expected 2 poll attempts for AssemblyAI")
    }

    do {
        let engine = AssemblyAISTTEngine(
            config: AssemblyAISTTConfig(apiKey: "aai-key", pollInterval: 0.2, maxPollAttempts: 2),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/v1/upload" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"upload_url\":\"https://example.com/a.wav\"}".utf8))
            } else if path == "/v1/transcript" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_1\",\"status\":\"queued\"}".utf8))
            } else {
                pollAttempts.withLock { $0 += 1 }
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_1\",\"status\":\"processing\"}".utf8))
            }
        }
        let task = Task<TranscriptionResult, Error> {
            try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        }
        while pollAttempts.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            assertionFailure("Expected CancellationError for AssemblyAI")
        } catch is CancellationError {
        }
        assert(pollAttempts.withLock { $0 } == 1, "AssemblyAI must not poll again after cancellation")
    }

    // 2. Speechmatics multi-poll progression (running -> done -> transcript) + cancellation
    do {
        let engine = SpeechmaticsSTTEngine(
            config: SpeechmaticsSTTConfig(apiKey: "sm-key", pollInterval: 0.01, maxPollAttempts: 3),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/v2/jobs" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"sm_1\"}".utf8))
            } else if path == "/v2/jobs/sm_1" {
                let attempt = pollAttempts.withLock { $0 += 1; return $0 }
                let status = attempt == 1 ? "running" : "done"
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"job\":{\"id\":\"sm_1\",\"status\":\"\(status)\"}}".utf8))
            } else {
                assert(path == "/v2/jobs/sm_1/transcript", "Unexpected path: \(path)")
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"content\":\"sm multi ok\"}".utf8))
            }
        }
        let result = try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        assert(result.text == "sm multi ok", "Speechmatics multi-poll text mismatch")
        assert(pollAttempts.withLock { $0 } == 2, "Expected 2 poll attempts for Speechmatics")
    }

    do {
        let engine = SpeechmaticsSTTEngine(
            config: SpeechmaticsSTTConfig(apiKey: "sm-key", pollInterval: 0.2, maxPollAttempts: 2),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/v2/jobs" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"sm_1\"}".utf8))
            } else {
                pollAttempts.withLock { $0 += 1 }
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"job\":{\"id\":\"sm_1\",\"status\":\"running\"}}".utf8))
            }
        }
        let task = Task<TranscriptionResult, Error> {
            try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        }
        while pollAttempts.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            assertionFailure("Expected CancellationError for Speechmatics")
        } catch is CancellationError {
        }
        assert(pollAttempts.withLock { $0 } == 1, "Speechmatics must not poll again after cancellation")
    }

    // 3. Rev.ai multi-poll progression (in_progress -> transcribed -> transcript) + cancellation
    do {
        let engine = RevAISTTEngine(
            config: RevAISTTConfig(apiKey: "rev-key", pollInterval: 0.01, maxPollAttempts: 3),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/speechtotext/v1/jobs" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"rev_1\"}".utf8))
            } else if path == "/speechtotext/v1/jobs/rev_1" {
                let attempt = pollAttempts.withLock { $0 += 1; return $0 }
                let status = attempt == 1 ? "in_progress" : "transcribed"
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"rev_1\",\"status\":\"\(status)\"}".utf8))
            } else {
                assert(path == "/speechtotext/v1/jobs/rev_1/transcript", "Unexpected path: \(path)")
                return (stubHTTPResponse(url: request.url!, status: 200), Data("rev multi ok".utf8))
            }
        }
        let result = try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        assert(result.text == "rev multi ok", "Rev.ai multi-poll text mismatch")
        assert(pollAttempts.withLock { $0 } == 2, "Expected 2 poll attempts for Rev.ai")
    }

    do {
        let engine = RevAISTTEngine(
            config: RevAISTTConfig(apiKey: "rev-key", pollInterval: 0.2, maxPollAttempts: 2),
            session: session
        )
        let pollAttempts = LockedBox<Int>(0)
        BatchPollingStubURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path == "/speechtotext/v1/jobs" {
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"rev_1\"}".utf8))
            } else {
                pollAttempts.withLock { $0 += 1 }
                return (stubHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"rev_1\",\"status\":\"in_progress\"}".utf8))
            }
        }
        let task = Task<TranscriptionResult, Error> {
            try await engine.transcribe(audioData: audio, language: "en", prompt: nil)
        }
        while pollAttempts.withLock({ $0 }) < 1 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            assertionFailure("Expected CancellationError for Rev.ai")
        } catch is CancellationError {
        }
        assert(pollAttempts.withLock { $0 } == 1, "Rev.ai must not poll again after cancellation")
    }
}
