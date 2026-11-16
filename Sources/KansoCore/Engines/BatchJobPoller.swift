import Foundation

/// Explicit lifecycle state of an async batch transcription job.
public enum BatchJobState: Sendable, Equatable {
    case submitting
    case polling(attempt: Int)
    case fetching
    case completed
    case failed
    case timedOut
}

/// Outcome of a single batch-job status poll.
public enum BatchJobPollOutcome<ReadyPayload: Sendable>: Sendable {
    case pending
    case ready(ReadyPayload)
}

/// Coordinates the shared async batch transcription job lifecycle:
/// `submitting` -> `polling` -> `fetching` -> `completed` / `failed` / `timedOut`.
public enum BatchJobPoller {
    /// Executes an async batch job lifecycle with explicit state transitions,
    /// cooperative cancellation, and bounded polling attempts.
    public static func run<JobID: Sendable, ReadyPayload: Sendable, Output: Sendable>(
        pollInterval: TimeInterval,
        maxPollAttempts: Int,
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        onStateChange: (@Sendable (BatchJobState) -> Void)? = nil,
        submit: @Sendable () async throws -> JobID,
        poll: @Sendable (JobID) async throws -> BatchJobPollOutcome<ReadyPayload>,
        fetch: @Sendable (JobID, ReadyPayload) async throws -> Output,
        timeoutError: @Sendable (Int) -> STTError
    ) async throws -> Output {
        onStateChange?(.submitting)

        let jobID: JobID
        do {
            try Task.checkCancellation()
            jobID = try await submit()
        } catch {
            onStateChange?(.failed)
            throw error
        }

        let sleepNanoseconds = UInt64(max(0, pollInterval) * 1_000_000_000)

        if maxPollAttempts > 0 {
            for attempt in 1...maxPollAttempts {
                do {
                    try Task.checkCancellation()
                    onStateChange?(.polling(attempt: attempt))
                    switch try await poll(jobID) {
                    case .ready(let payload):
                        try Task.checkCancellation()
                        onStateChange?(.fetching)
                        let output = try await fetch(jobID, payload)
                        onStateChange?(.completed)
                        return output
                    case .pending:
                        if attempt < maxPollAttempts {
                            if sleepNanoseconds > 0 {
                                try await sleep(sleepNanoseconds)
                            } else {
                                try Task.checkCancellation()
                            }
                        }
                    }
                } catch {
                    onStateChange?(.failed)
                    throw error
                }
            }
        }

        onStateChange?(.timedOut)
        throw timeoutError(maxPollAttempts)
    }

    /// Sends a URLRequest, propagates task cancellation, validates 2xx HTTP status,
    /// and maps non-2xx responses through provider-specific error parsing/mapping.
    public static func send(
        _ request: URLRequest,
        using session: URLSession,
        parseErrorMessage: (Data, Int) -> String,
        mapHTTPError: (Int, String) -> STTError
    ) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw STTError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw STTError.networkError("Invalid non-HTTP response received.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw mapHTTPError(http.statusCode, parseErrorMessage(data, http.statusCode))
        }
        return data
    }
}
