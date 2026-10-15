import Foundation

/// Configuration for the Google Gemini Developer API Remote STT Engine.
public struct GeminiSTTConfig: Sendable, Equatable {
    public static let defaultModel = "gemini-3.5-transcribe"

    public let apiKey: String?
    public let model: String
    public let timeoutInterval: TimeInterval

    public init(
        apiKey: String? = nil,
        model: String = defaultModel,
        timeoutInterval: TimeInterval = 30.0
    ) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.timeoutInterval = timeoutInterval
    }
}

/// Remote STT engine backed by the Google Gemini Developer API (AI Studio).
/// Uses official `v1beta/models/gemini-3.5-transcribe:generateContent` with
/// base64 `inline_data` plus `generationConfig.audioTranscriptionConfig`.
/// Docs: https://ai.google.dev/gemini-api/docs/generate-content/transcribe
public final class GeminiSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: GeminiSTTConfig

    private let session: URLSession

    public init(
        config: GeminiSTTConfig,
        session: URLSession = .shared
    ) {
        self.config = config
        self.identifier = "gemini.\(config.model)"
        self.displayName = "Gemini (\(config.model))"
        self.session = session
    }

    private var trimmedKey: String? {
        guard let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    public func endpointURL(for model: String) -> URL {
        let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = clean.isEmpty ? GeminiSTTConfig.defaultModel : clean
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(effective):generateContent")!
    }

    /// Maps a short language tag ("id", "en") to BCP-47 for Gemini.
    public static func bcp47Code(for language: String?) -> String? {
        guard let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty else {
            return nil
        }
        let lower = lang.lowercased()
        if lower.contains("-") { return lang } // already BCP-47
        switch lower {
        case "id": return "id-ID"
        case "en": return "en-US"
        default: return lang
        }
    }

    /// Builds the `generateContent` URLRequest with base64 audio and transcription config.
    public func buildRequest(audioData: Data, language: String?, prompt: String?) throws -> URLRequest {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Gemini API key. Paste one from Google AI Studio in Settings.")
        }

        var components = URLComponents(url: endpointURL(for: config.model), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let fullURL = components.url else {
            throw STTError.invalidEndpoint("Could not construct Gemini API URL")
        }

        var request = URLRequest(url: fullURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let base64Audio = audioData.base64EncodedString()
        var transcriptionConfig: [String: Any] = ["mode": "SMART"]
        if let code = Self.bcp47Code(for: language) {
            transcriptionConfig["languageCodes"] = [code]
        }
        if let userPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !userPrompt.isEmpty {
            let terms = userPrompt.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !terms.isEmpty {
                transcriptionConfig["customVocabulary"] = terms
            }
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["inline_data": ["mime_type": "audio/wav", "data": base64Audio]]
                    ]
                ]
            ],
            "generationConfig": ["audioTranscriptionConfig": transcriptionConfig]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let request = try buildRequest(audioData: audioData, language: language, prompt: prompt)
        // ponytail: fixed 2-retry backoff for transient 503 overload; exponential schedule if spikes persist
        var lastError: STTError?
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw STTError.networkError("Invalid non-HTTP response received.")
                }
                guard (200...299).contains(http.statusCode) else {
                    let mapped = mapHTTPError(statusCode: http.statusCode, serverMessage: parseErrorMessage(from: data, statusCode: http.statusCode))
                    if http.statusCode == 503, attempt < 2 {
                        lastError = mapped
                        continue
                    }
                    throw mapped
                }
                return try parseSuccessResponse(from: data, fallbackDuration: CFAbsoluteTimeGetCurrent() - startTime)
            } catch let err as STTError {
                throw err
            } catch {
                throw STTError.networkError(error.localizedDescription)
            }
        }
        throw lastError ?? STTError.networkError("Gemini service unavailable after retries.")
    }

    private func mapHTTPError(statusCode: Int, serverMessage: String) -> STTError {
        switch statusCode {
        case 400:
            return .httpError(statusCode: statusCode, message: "Invalid Gemini request (check model/audio): \(serverMessage)")
        case 401, 403:
            return .httpError(statusCode: statusCode, message: "Invalid Gemini API key: \(serverMessage)")
        case 404:
            return .httpError(statusCode: statusCode, message: "Gemini model not found (check model name): \(serverMessage)")
        case 429:
            return .httpError(statusCode: statusCode, message: "Gemini quota exceeded: \(serverMessage)")
        case 503:
            return .httpError(statusCode: statusCode, message: "Gemini sedang sibuk (overload sementara). Coba lagi beberapa detik. Detail: \(serverMessage)")
        case 500...599:
            return .httpError(statusCode: statusCode, message: "Gemini service unavailable (HTTP \(statusCode)): \(serverMessage)")
        default:
            return .httpError(statusCode: statusCode, message: serverMessage)
        }
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct Wrapper: Decodable {
            struct Inner: Decodable {
                let message: String?
            }
            let error: Inner?
            let message: String?
        }
        if let decoded = try? JSONDecoder().decode(Wrapper.self, from: data) {
            if let msg = decoded.error?.message, !msg.isEmpty { return msg }
            if let msg = decoded.message, !msg.isEmpty { return msg }
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct Part: Decodable {
            let text: String?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Candidate: Decodable {
            let content: Content?
            let text: String?
        }
        struct GenerateContentResponse: Decodable {
            let candidates: [Candidate]?
            let text: String?
        }

        do {
            let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
            let raw = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined(separator: " ")
                ?? decoded.candidates?.first?.text
                ?? decoded.text

            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return TranscriptionResult(
                    text: "",
                    durationSeconds: fallbackDuration,
                    engineIdentifier: identifier,
                    timestamp: Date()
                )
            }

            return TranscriptionResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: fallbackDuration,
                engineIdentifier: identifier,
                timestamp: Date()
            )
        } catch {
            throw STTError.decodingError(error.localizedDescription)
        }
    }
}
