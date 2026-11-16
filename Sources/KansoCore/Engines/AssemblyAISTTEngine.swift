import Foundation

/// Configuration for the AssemblyAI async-polling Remote STT Engine.
public struct AssemblyAISTTConfig: Sendable, Equatable {
    public static let defaultModel = "universal-2"
    public static let baseURL = URL(string: "https://api.assemblyai.com")!

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

/// Remote STT engine backed by AssemblyAI async transcription
/// (`POST /v1/upload` bytes, `POST /v1/transcript`, poll `GET /v1/transcript/{id}`).
/// Batch polling only — no realtime WebSocket in v1.
public final class AssemblyAISTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: AssemblyAISTTConfig

    private let session: URLSession

    public init(config: AssemblyAISTTConfig, session: URLSession = .shared) {
        self.config = config
        self.identifier = "assemblyai.\(config.model)"
        self.displayName = "AssemblyAI (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Splits a vocabulary prompt into word-boost terms (cap ~100).
    public static func wordBoost(from prompt: String?) -> [String]? {
        guard let prompt else { return nil }
        let terms = prompt.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return Array(terms.prefix(100))
    }

    /// Builds the raw-bytes upload request (`POST /v1/upload`).
    public func buildUploadRequest(audioData: Data) throws -> URLRequest {
        guard !audioData.isEmpty else { throw STTError.emptyAudioData }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing AssemblyAI API key. Paste one from the AssemblyAI dashboard in Settings.")
        }
        var request = URLRequest(url: Self.baseUploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        return request
    }

    public static var baseUploadURL: URL { AssemblyAISTTConfig.baseURL.appendingPathComponent("/v1/upload") }
    public static var baseTranscriptURL: URL { AssemblyAISTTConfig.baseURL.appendingPathComponent("/v1/transcript") }

    /// Builds the transcript-create request (`POST /v1/transcript`).
    public func buildCreateRequest(audioURL: String, language: String?, prompt: String?) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing AssemblyAI API key. Paste one from the AssemblyAI dashboard in Settings.")
        }
        var request = URLRequest(url: Self.baseTranscriptURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["audio_url": audioURL, "speech_model": config.model]
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["language_code"] = language }
        if let boost = Self.wordBoost(from: prompt) { body["word_boost"] = boost }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Builds the status-poll request (`GET /v1/transcript/{id}`).
    public func buildPollRequest(transcriptID: String) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing AssemblyAI API key. Paste one from the AssemblyAI dashboard in Settings.")
        }
        var request = URLRequest(url: Self.baseTranscriptURL.appendingPathComponent(transcriptID))
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "Authorization")
        return request
    }

    public func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        struct CompletedPayload: Sendable {
            let text: String
            let duration: Double?
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let send: @Sendable (URLRequest) async throws -> Data = { request in
            try await BatchJobPoller.send(
                request,
                using: self.session,
                parseErrorMessage: { self.parseErrorMessage(from: $0, statusCode: $1) },
                mapHTTPError: { self.mapHTTPError(statusCode: $0, serverMessage: $1) }
            )
        }
        return try await BatchJobPoller.run(
            pollInterval: config.pollInterval,
            maxPollAttempts: config.maxPollAttempts,
            submit: {
                let uploadData = try await send(try self.buildUploadRequest(audioData: audioData))
                let audioURL = try self.parseUploadURL(from: uploadData)
                let createData = try await send(try self.buildCreateRequest(audioURL: audioURL, language: language, prompt: prompt))
                return try self.parseTranscriptID(from: createData)
            },
            poll: { transcriptID -> BatchJobPollOutcome<CompletedPayload> in
                let pollData = try await send(try self.buildPollRequest(transcriptID: transcriptID))
                if let done = try self.parsePollResult(from: pollData) {
                    return .ready(CompletedPayload(text: done.text, duration: done.duration))
                }
                return .pending
            },
            fetch: { _, payload in
                TranscriptionResult(
                    text: payload.text,
                    durationSeconds: payload.duration ?? (CFAbsoluteTimeGetCurrent() - startTime),
                    engineIdentifier: self.identifier,
                    timestamp: Date()
                )
            },
            timeoutError: { attempts in
                STTError.networkError("AssemblyAI transcription timed out after \(attempts) polls.")
            }
        )
    }

    private func mapHTTPError(statusCode: Int, serverMessage: String) -> STTError {
        switch statusCode {
        case 400: return .httpError(statusCode: statusCode, message: "Invalid AssemblyAI request (check audio/model): \(serverMessage)")
        case 401, 403: return .httpError(statusCode: statusCode, message: "Invalid AssemblyAI API key: \(serverMessage)")
        case 429: return .httpError(statusCode: statusCode, message: "AssemblyAI quota exceeded: \(serverMessage)")
        case 500...599: return .httpError(statusCode: statusCode, message: "AssemblyAI service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default: return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Wrapper: Decodable { let error: String?; let message: String? }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            for msg in [decoded.error, decoded.message] { if let msg, !msg.isEmpty { return msg } }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseUploadURL(from data: Data) throws -> String {
        struct UploadResponse: Decodable { let upload_url: String? }
        do {
            guard let url = try JSONDecoder().decode(UploadResponse.self, from: data).upload_url, !url.isEmpty else {
                throw STTError.decodingError("Upload response missing upload_url.")
            }
            return url
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    private func parseTranscriptID(from data: Data) throws -> String {
        struct CreateResponse: Decodable { let id: String? }
        do {
            guard let id = try JSONDecoder().decode(CreateResponse.self, from: data).id, !id.isEmpty else {
                throw STTError.decodingError("Transcript create response missing id.")
            }
            return id
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }

    /// Returns the completed result, nil while queued/processing; throws on error status.
    private func parsePollResult(from data: Data) throws -> (text: String, duration: Double?)? {
        struct PollResponse: Decodable { let status: String?; let text: String?; let audio_duration: Double?; let error: String? }
        do {
            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            switch decoded.status {
            case "completed":
                guard let raw = decoded.text else { throw STTError.decodingError("Completed transcript missing text.") }
                return (raw.trimmingCharacters(in: .whitespacesAndNewlines), decoded.audio_duration)
            case "error": throw STTError.httpError(statusCode: 500, message: "AssemblyAI transcription failed: \(decoded.error ?? "unknown error")")
            default: return nil
            }
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }
}
