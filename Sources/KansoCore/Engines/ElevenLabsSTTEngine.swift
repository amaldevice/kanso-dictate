import Foundation

/// Configuration for the ElevenLabs Scribe Remote STT Engine.
public struct ElevenLabsSTTConfig: Sendable, Equatable {
    public static let defaultModel = "scribe_v2"
    public static let transcribeURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public let apiKey: String?
    public let model: String
    public let timeoutInterval: TimeInterval

    public init(
        apiKey: String? = nil,
        model: String = defaultModel,
        timeoutInterval: TimeInterval = 30.0
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutInterval = timeoutInterval
    }
}

/// Remote STT engine backed by ElevenLabs Scribe (`POST /v1/speech-to-text`).
/// Single REST call per PTT release — no realtime WebSocket in v1.
/// Auth uses the `xi-api-key` header, NOT Bearer.
public final class ElevenLabsSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: ElevenLabsSTTConfig

    private let session: URLSession

    public init(config: ElevenLabsSTTConfig, session: URLSession = .shared) {
        self.config = config
        self.identifier = "elevenlabs.\(config.model.replacingOccurrences(of: "_", with: "-"))"
        self.displayName = "ElevenLabs (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Builds the Scribe multipart request carrying the WAV file + model id.
    /// Scribe v2 exposes no vocabulary-bias field, so prompt is intentionally unused.
    public func buildRequest(audioData: Data, language: String?, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        guard !audioData.isEmpty else { throw STTError.emptyAudioData }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing ElevenLabs API key. Paste one from the ElevenLabs dashboard in Settings.")
        }
        var request = URLRequest(url: ElevenLabsSTTConfig.transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func appendField(name: String, value: String) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }
        appendField(name: "model_id", value: config.model)
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField(name: "language_code", value: language)
        }
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    public func transcribe(audioData: Data, language: String?, prompt: String?) async throws -> TranscriptionResult {
        let request = try buildRequest(audioData: audioData, language: language)
        let startTime = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw STTError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.networkError("Invalid non-HTTP response received.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, serverMessage: parseErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }
        return try parseSuccessResponse(from: data, fallbackDuration: CFAbsoluteTimeGetCurrent() - startTime)
    }

    private func mapHTTPError(statusCode: Int, serverMessage: String) -> STTError {
        switch statusCode {
        case 400: return .httpError(statusCode: statusCode, message: "Invalid ElevenLabs request (check audio/model): \(serverMessage)")
        case 401, 403: return .httpError(statusCode: statusCode, message: "Invalid ElevenLabs API key: \(serverMessage)")
        case 429: return .httpError(statusCode: statusCode, message: "ElevenLabs quota exceeded: \(serverMessage)")
        case 500...599: return .httpError(statusCode: statusCode, message: "ElevenLabs service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default: return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Detail: Decodable { let message: String? }
        struct Wrapper: Decodable { let detail: Detail?; let message: String?; let error: String? }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            for msg in [decoded.detail?.message, decoded.message, decoded.error] { if let msg, !msg.isEmpty { return msg } }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct ScribeResponse: Decodable { let text: String?; let duration: Double?; let duration_seconds: Double? }
        do {
            let decoded = try JSONDecoder().decode(ScribeResponse.self, from: data)
            guard let raw = decoded.text else { throw STTError.decodingError("Scribe response missing text.") }
            return TranscriptionResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: decoded.duration ?? decoded.duration_seconds ?? fallbackDuration,
                engineIdentifier: identifier,
                timestamp: Date()
            )
        } catch let err as STTError { throw err } catch { throw STTError.decodingError(error.localizedDescription) }
    }
}
