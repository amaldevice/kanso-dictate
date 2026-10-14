import Foundation

/// Configuration for the Deepgram pre-recorded Remote STT Engine.
public struct DeepgramSTTConfig: Sendable, Equatable {
    public static let defaultModel = "nova-3"

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

/// Remote STT engine backed by Deepgram pre-recorded REST (`POST /v1/listen`).
/// Batch only — no WebSocket streaming in v1.
public final class DeepgramSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: DeepgramSTTConfig

    private let session: URLSession

    public static let baseListenURL = URL(string: "https://api.deepgram.com/v1/listen")!

    public init(
        config: DeepgramSTTConfig,
        session: URLSession = .shared
    ) {
        self.config = config
        self.identifier = "deepgram.\(config.model)"
        self.displayName = "Deepgram (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Resolves the Deepgram language param: id|en passthrough, everything else falls back to multi.
    public static func resolvedLanguage(_ language: String?) -> String {
        guard let language else { return "multi" }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "multi" }
        if trimmed.hasPrefix("id") { return "id" }
        if trimmed.hasPrefix("en") { return "en" }
        return "multi"
    }

    /// Splits a vocabulary prompt into keyword terms (cap ~100).
    public static func keywords(from prompt: String?) -> [String]? {
        guard let prompt else { return nil }
        let terms = prompt
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return Array(terms.prefix(100))
    }

    /// Builds the `POST /v1/listen` request carrying raw WAV bytes.
    public func buildRequest(audioData: Data, language: String?, prompt: String?) throws -> URLRequest {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Deepgram API key. Paste one from Deepgram Console in Settings.")
        }
        var components = URLComponents(url: Self.baseListenURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "language", value: Self.resolvedLanguage(language)),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        if let terms = Self.keywords(from: prompt) {
            items += terms.map { URLQueryItem(name: "keywords", value: $0) }
            items.append(URLQueryItem(name: "topics", value: "true"))
            items.append(URLQueryItem(name: "custom_topic_mode", value: "extended"))
            items += terms.map { URLQueryItem(name: "custom_topic", value: $0) }
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        return request
    }

    public func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        let request = try buildRequest(audioData: audioData, language: language, prompt: prompt)
        let startTime = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw STTError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.networkError("Invalid non-HTTP response received.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, serverMessage: parseErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return try parseSuccessResponse(from: data, fallbackDuration: elapsed)
    }

    private func mapHTTPError(statusCode: Int, serverMessage: String) -> STTError {
        switch statusCode {
        case 400:
            return .httpError(statusCode: statusCode, message: "Invalid Deepgram request (check audio/model): \(serverMessage)")
        case 401, 403:
            return .httpError(statusCode: statusCode, message: "Invalid Deepgram API key: \(serverMessage)")
        case 429:
            return .httpError(statusCode: statusCode, message: "Deepgram quota exceeded: \(serverMessage)")
        case 500...599:
            return .httpError(statusCode: statusCode, message: "Deepgram service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default:
            return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Wrapper: Decodable {
            let err_msg: String?
            let error: String?
            let message: String?
        }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            for msg in [decoded.err_msg, decoded.error, decoded.message] {
                if let msg, !msg.isEmpty { return msg }
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct Alternative: Decodable {
            let transcript: String?
        }
        struct Channel: Decodable {
            let alternatives: [Alternative]?
        }
        struct Results: Decodable {
            let channels: [Channel]?
        }
        struct Metadata: Decodable {
            let duration: Double?
        }
        struct ListenResponse: Decodable {
            let results: Results?
            let metadata: Metadata?
        }
        do {
            let decoded = try JSONDecoder().decode(ListenResponse.self, from: data)
            guard let raw = decoded.results?.channels?.first?.alternatives?.first?.transcript else {
                throw STTError.decodingError("Listen response missing results.channels[0].alternatives[0].transcript.")
            }
            return TranscriptionResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: decoded.metadata?.duration ?? fallbackDuration,
                engineIdentifier: identifier,
                timestamp: Date()
            )
        } catch let err as STTError {
            throw err
        } catch {
            throw STTError.decodingError(error.localizedDescription)
        }
    }
}
