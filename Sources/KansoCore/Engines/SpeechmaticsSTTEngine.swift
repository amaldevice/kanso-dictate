import Foundation

/// Configuration for the Speechmatics batch Remote STT Engine.
public struct SpeechmaticsSTTConfig: Sendable, Equatable {
    public static let defaultModel = "enhanced"
    public static let baseJobsURL = URL(string: "https://asr.api.speechmatics.com/v2/jobs")!

    public let apiKey: String?
    public let model: String
    public let timeoutInterval: TimeInterval
    public let pollInterval: TimeInterval
    public let maxPollAttempts: Int

    public init(
        apiKey: String? = nil,
        model: String = defaultModel,
        timeoutInterval: TimeInterval = 30.0,
        pollInterval: TimeInterval = 1.0,
        maxPollAttempts: Int = 60
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutInterval = timeoutInterval
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
    }
}

/// Remote STT engine backed by Speechmatics batch (`POST /v2/jobs` multipart,
/// poll `GET /v2/jobs/{id}`, fetch `GET /v2/jobs/{id}/transcript`).
/// Batch only — no realtime WebSocket in v1.
public final class SpeechmaticsSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: SpeechmaticsSTTConfig

    private let session: URLSession

    public init(config: SpeechmaticsSTTConfig, session: URLSession = .shared) {
        self.config = config
        self.identifier = "speechmatics.\(config.model)"
        self.displayName = "Speechmatics (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Splits a vocabulary prompt into additional-vocab entries (cap ~100).
    public static func additionalVocab(from prompt: String?) -> [[String: String]]? {
        guard let prompt else { return nil }
        let terms = prompt.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return Array(terms.prefix(100)).map { ["content": $0] }
    }

    /// Builds the batch job-create request carrying multipart config + WAV bytes.
    public func buildCreateRequest(audioData: Data, language: String?, prompt: String?, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        guard !audioData.isEmpty else { throw STTError.emptyAudioData }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Speechmatics API key. Paste one from the Speechmatics portal in Settings.")
        }
        var request = URLRequest(url: SpeechmaticsSTTConfig.baseJobsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var transcription: [String: Any] = ["operating_point": config.model]
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { transcription["language"] = language }
        if let vocab = Self.additionalVocab(from: prompt) { transcription["additional_vocab"] = vocab }
        let configJSON = try JSONSerialization.data(withJSONObject: ["type": "transcription", "transcription_config": transcription])
        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"config\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        body.append(configJSON)
        body.append(contentsOf: "\r\n".utf8)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"data_file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    /// Builds the job-status poll request (`GET /v2/jobs/{id}`).
    public func buildPollRequest(jobID: String) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Speechmatics API key. Paste one from the Speechmatics portal in Settings.")
        }
        var request = URLRequest(url: SpeechmaticsSTTConfig.baseJobsURL.appendingPathComponent(jobID))
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the transcript-fetch request (`GET /v2/jobs/{id}/transcript`).
    public func buildTranscriptRequest(jobID: String) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Speechmatics API key. Paste one from the Speechmatics portal in Settings.")
        }
        var request = URLRequest(url: SpeechmaticsSTTConfig.baseJobsURL.appendingPathComponent("\(jobID)/transcript"))
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let (createData, createHTTP) = try await send(try buildCreateRequest(audioData: audioData, language: language, prompt: prompt))
        guard (200...299).contains(createHTTP.statusCode) else {
            throw mapHTTPError(statusCode: createHTTP.statusCode, serverMessage: parseErrorMessage(from: createData, statusCode: createHTTP.statusCode))
        }
        let jobID = try parseJobID(from: createData)
        for _ in 0..<config.maxPollAttempts {
            let (pollData, pollHTTP) = try await send(try buildPollRequest(jobID: jobID))
            guard (200...299).contains(pollHTTP.statusCode) else {
                throw mapHTTPError(statusCode: pollHTTP.statusCode, serverMessage: parseErrorMessage(from: pollData, statusCode: pollHTTP.statusCode))
            }
            if try parseJobDone(from: pollData) {
                let (tData, tHTTP) = try await send(try buildTranscriptRequest(jobID: jobID))
                guard (200...299).contains(tHTTP.statusCode) else {
                    throw mapHTTPError(statusCode: tHTTP.statusCode, serverMessage: parseErrorMessage(from: tData, statusCode: tHTTP.statusCode))
                }
                return try parseTranscript(from: tData, fallbackDuration: CFAbsoluteTimeGetCurrent() - startTime)
            }
            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
        throw STTError.networkError("Speechmatics transcription timed out after \(config.maxPollAttempts) polls.")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw STTError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw STTError.networkError("Invalid non-HTTP response received.") }
        return (data, http)
    }

    private func mapHTTPError(statusCode: Int, serverMessage: String) -> STTError {
        switch statusCode {
        case 400: return .httpError(statusCode: statusCode, message: "Invalid Speechmatics request (check audio/config): \(serverMessage)")
        case 401, 403: return .httpError(statusCode: statusCode, message: "Invalid Speechmatics API key: \(serverMessage)")
        case 429: return .httpError(statusCode: statusCode, message: "Speechmatics quota exceeded: \(serverMessage)")
        case 500...599: return .httpError(statusCode: statusCode, message: "Speechmatics service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default: return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Wrapper: Decodable { let error: String?; let message: String?; let detail: String? }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            for msg in [decoded.error, decoded.message, decoded.detail] { if let msg, !msg.isEmpty { return msg } }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseJobID(from data: Data) throws -> String {
        struct CreateResponse: Decodable { struct Job: Decodable { let id: String? }; let id: String?; let job: Job? }
        do {
            let decoded = try JSONDecoder().decode(CreateResponse.self, from: data)
            if let id = decoded.id ?? decoded.job?.id, !id.isEmpty { return id }
            throw STTError.decodingError("Job create response missing id.")
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    /// True when the job reached a terminal done state; throws on rejected/failed.
    private func parseJobDone(from data: Data) throws -> Bool {
        struct PollResponse: Decodable { struct Job: Decodable { let status: String?; let errors: String? }; let status: String?; let job: Job? }
        do {
            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            let status = decoded.job?.status ?? decoded.status ?? ""
            switch status {
            case "done": return true
            case "rejected", "failed", "error":
                throw STTError.httpError(statusCode: 500, message: "Speechmatics job failed: \(decoded.job?.errors ?? "unknown error")")
            default: return false
            }
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    private func parseTranscript(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct TranscriptResponse: Decodable { let content: String?; let transcript: String?; let text: String?; let duration: Double? }
        do {
            if let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: data),
               let raw = decoded.content ?? decoded.transcript ?? decoded.text {
                return TranscriptionResult(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds: decoded.duration ?? fallbackDuration, engineIdentifier: identifier, timestamp: Date())
            }
            guard let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw STTError.decodingError("Transcript response missing content.")
            }
            return TranscriptionResult(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds: fallbackDuration, engineIdentifier: identifier, timestamp: Date())
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }
}
