import Foundation

/// Configuration for the Cloudflare Workers AI Remote STT Engine.
public struct CloudflareSTTConfig: Sendable, Equatable {
    public static let shortModel = "whisper-large-v3-turbo"
    public static let modelID = "@cf/openai/whisper-large-v3-turbo"

    public let accountID: String?
    public let apiToken: String?
    public let timeoutInterval: TimeInterval

    public init(
        accountID: String? = nil,
        apiToken: String? = nil,
        timeoutInterval: TimeInterval = 30.0
    ) {
        self.accountID = accountID
        self.apiToken = apiToken
        self.timeoutInterval = timeoutInterval
    }
}

/// Remote STT engine backed by Cloudflare Workers AI (`POST /client/v4/accounts/{id}/ai/run/...`).
/// Batch only — a single run call per PTT release.
public final class CloudflareSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: CloudflareSTTConfig

    private let session: URLSession

    public init(
        config: CloudflareSTTConfig,
        session: URLSession = .shared
    ) {
        self.config = config
        self.identifier = "cloudflare.\(CloudflareSTTConfig.shortModel)"
        self.displayName = "Cloudflare (\(CloudflareSTTConfig.shortModel))"
        self.session = session
    }

    private var trimmedAccountID: String? {
        guard let id = config.accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return id
    }

    private var trimmedToken: String? {
        guard let token = config.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Account-scoped Workers AI run endpoint for Whisper.
    public static func runURL(accountID: String) -> URL {
        URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/\(CloudflareSTTConfig.modelID)")!
    }

    /// Builds the Workers AI run request carrying base64 WAV audio as JSON.
    public func buildRequest(audioData: Data, language: String?, prompt: String?) throws -> URLRequest {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }
        guard let accountID = trimmedAccountID else {
            throw STTError.httpError(statusCode: 401, message: "Missing Cloudflare account ID. Paste one from the Cloudflare dashboard in Settings.")
        }
        guard let token = trimmedToken else {
            throw STTError.httpError(statusCode: 401, message: "Missing Cloudflare API token. Paste one from the Cloudflare dashboard in Settings.")
        }
        var request = URLRequest(url: Self.runURL(accountID: accountID))
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "audio": audioData.base64EncodedString(),
            "task": "transcribe",
        ]
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["language"] = language
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["initial_prompt"] = prompt
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
            return .httpError(statusCode: statusCode, message: "Invalid Cloudflare request (check audio/account): \(serverMessage)")
        case 401, 403:
            return .httpError(statusCode: statusCode, message: "Invalid Cloudflare API token or account ID: \(serverMessage)")
        case 429:
            return .httpError(statusCode: statusCode, message: "Cloudflare Workers AI quota exceeded: \(serverMessage)")
        case 500...599:
            return .httpError(statusCode: statusCode, message: "Cloudflare service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default:
            return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct CFError: Decodable {
            let message: String?
        }
        struct Wrapper: Decodable {
            let errors: [CFError]?
            let error: String?
            let message: String?
        }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            if let msg = decoded.errors?.compactMap(\.message).first, !msg.isEmpty { return msg }
            for msg in [decoded.error, decoded.message] {
                if let msg, !msg.isEmpty { return msg }
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct Inner: Decodable {
            let text: String?
            let duration: Double?
        }
        struct RunResponse: Decodable {
            // `result` is an object for Whisper; tolerate a bare string or top-level text.
            struct ResultValue: Decodable {
                let text: String?
                let duration: Double?

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let str = try? container.decode(String.self) {
                        self.text = str
                        self.duration = nil
                        return
                    }
                    let obj = try container.decode(Inner.self)
                    self.text = obj.text
                    self.duration = obj.duration
                }
            }
            let result: ResultValue?
            let text: String?
            let output_text: String?
            let duration: Double?
        }
        do {
            let decoded = try JSONDecoder().decode(RunResponse.self, from: data)
            guard let raw = decoded.result?.text ?? decoded.text ?? decoded.output_text else {
                throw STTError.decodingError("Workers AI response missing result text.")
            }
            return TranscriptionResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: decoded.result?.duration ?? decoded.duration ?? fallbackDuration,
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
