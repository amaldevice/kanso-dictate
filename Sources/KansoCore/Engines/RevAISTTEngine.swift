import Foundation

/// Configuration for the Rev.ai async Remote STT Engine.
public struct RevAISTTConfig: Sendable, Equatable {
    public static let defaultModel = "reverb"
    public static let baseJobsURL = URL(string: "https://api.rev.ai/speechtotext/v1/jobs")!

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

/// Remote STT engine backed by Rev.ai async jobs (`POST /speechtotext/v1/jobs`
/// multipart, poll `GET /jobs/{id}`, fetch `GET /jobs/{id}/transcript`).
/// Batch only — no streaming WebSocket in v1.
public final class RevAISTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: RevAISTTConfig

    private let session: URLSession

    public init(config: RevAISTTConfig, session: URLSession = .shared) {
        self.config = config
        self.identifier = "revai.\(config.model)"
        self.displayName = "Rev.ai (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Splits a vocabulary prompt into custom-vocabulary phrases (cap ~100).
    public static func customPhrases(from prompt: String?) -> [String]? {
        guard let prompt else { return nil }
        let terms = prompt.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return Array(terms.prefix(100))
    }

    /// Builds the async job-submit request carrying multipart media bytes + options.
    public func buildSubmitRequest(audioData: Data, language: String?, prompt: String?, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        guard !audioData.isEmpty else { throw STTError.emptyAudioData }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Rev.ai access token. Paste one from the Rev.ai dashboard in Settings.")
        }
        var request = URLRequest(url: RevAISTTConfig.baseJobsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var options: [String: Any] = ["model": config.model]
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { options["language"] = language }
        if let phrases = Self.customPhrases(from: prompt) { options["custom_vocabularies"] = [["phrases": phrases]] }
        let optionsJSON = try JSONSerialization.data(withJSONObject: options)
        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"options\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        body.append(optionsJSON)
        body.append(contentsOf: "\r\n".utf8)
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"media\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    /// Builds the job-status poll request (`GET /jobs/{id}`).
    public func buildPollRequest(jobID: String) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Rev.ai access token. Paste one from the Rev.ai dashboard in Settings.")
        }
        var request = URLRequest(url: RevAISTTConfig.baseJobsURL.appendingPathComponent(jobID))
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Builds the transcript-fetch request (`GET /jobs/{id}/transcript`).
    public func buildTranscriptRequest(jobID: String) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Rev.ai access token. Paste one from the Rev.ai dashboard in Settings.")
        }
        var request = URLRequest(url: RevAISTTConfig.baseJobsURL.appendingPathComponent("\(jobID)/transcript"))
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        return request
    }

    public func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let (submitData, submitHTTP) = try await send(try buildSubmitRequest(audioData: audioData, language: language, prompt: prompt))
        guard (200...299).contains(submitHTTP.statusCode) else {
            throw mapHTTPError(statusCode: submitHTTP.statusCode, serverMessage: parseErrorMessage(from: submitData, statusCode: submitHTTP.statusCode))
        }
        let jobID = try parseJobID(from: submitData)
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
        throw STTError.networkError("Rev.ai transcription timed out after \(config.maxPollAttempts) polls.")
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
        case 400: return .httpError(statusCode: statusCode, message: "Invalid Rev.ai request (check audio/options): \(serverMessage)")
        case 401, 403: return .httpError(statusCode: statusCode, message: "Invalid Rev.ai access token: \(serverMessage)")
        case 429: return .httpError(statusCode: statusCode, message: "Rev.ai quota exceeded: \(serverMessage)")
        case 500...599: return .httpError(statusCode: statusCode, message: "Rev.ai service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default: return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Detail: Decodable { let message: String? }
        struct Wrapper: Decodable { let title: String?; let detail: Detail?; let message: String? }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            for msg in [decoded.detail?.message, decoded.title, decoded.message] { if let msg, !msg.isEmpty { return msg } }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseJobID(from data: Data) throws -> String {
        struct SubmitResponse: Decodable { let id: String? }
        do {
            guard let id = try JSONDecoder().decode(SubmitResponse.self, from: data).id, !id.isEmpty else {
                throw STTError.decodingError("Job submit response missing id.")
            }
            return id
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    /// True when the job reached transcribed state; throws on failed.
    private func parseJobDone(from data: Data) throws -> Bool {
        struct PollResponse: Decodable { let status: String?; let failure_detail: String? }
        do {
            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            switch decoded.status {
            case "transcribed": return true
            case "failed": throw STTError.httpError(statusCode: 500, message: "Rev.ai job failed: \(decoded.failure_detail ?? "unknown error")")
            default: return false
            }
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    private func parseTranscript(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct TranscriptResponse: Decodable { let text: String? }
        do {
            if let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: data), let raw = decoded.text {
                return TranscriptionResult(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds: fallbackDuration, engineIdentifier: identifier, timestamp: Date())
            }
            guard let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw STTError.decodingError("Transcript response missing text.")
            }
            return TranscriptionResult(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds: fallbackDuration, engineIdentifier: identifier, timestamp: Date())
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }
}
