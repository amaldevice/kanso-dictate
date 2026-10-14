import Foundation

/// Configuration for the Gemini Developer API Remote STT Engine.
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
        self.model = model
        self.timeoutInterval = timeoutInterval
    }
}

/// Remote STT engine backed by the Gemini Developer API dedicated transcribe path.
/// Two-step flow: upload 16kHz WAV bytes via Files API, then transcribe by URI
/// via the Interactions endpoint.
public final class GeminiSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: GeminiSTTConfig

    private let session: URLSession

    public static let interactionsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    public static let filesUploadURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!

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

    /// Builds the Files-API upload request carrying raw WAV bytes.
    public func buildUploadRequest(audioData: Data) throws -> URLRequest {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Gemini API key. Paste one from AI Studio in Settings.")
        }
        var request = URLRequest(url: Self.filesUploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        return request
    }

    /// Builds the Interactions transcribe-by-URI request.
    public func buildInteractionsRequest(fileURI: String, language: String?, prompt: String?) throws -> URLRequest {
        guard let key = trimmedKey else {
            throw STTError.httpError(statusCode: 401, message: "Missing Gemini API key. Paste one from AI Studio in Settings.")
        }
        var request = URLRequest(url: Self.interactionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var transcriptionConfig: [String: Any] = ["mode": "verbatim"]
        if let vocab = Self.customVocabulary(from: prompt), !vocab.isEmpty {
            transcriptionConfig["custom_vocabulary"] = vocab
        }
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcriptionConfig["language_code"] = language
        }

        let body: [String: Any] = [
            "model": config.model,
            "input": [["type": "audio", "audio_uri": fileURI, "mime_type": "audio/wav"]],
            "generation_config": ["transcription_config": transcriptionConfig],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Splits a vocabulary prompt into custom terms (cap ~100).
    public static func customVocabulary(from prompt: String?) -> [String]? {
        guard let prompt else { return nil }
        let terms = prompt
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return Array(terms.prefix(100))
    }

    public func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let uploadRequest = try buildUploadRequest(audioData: audioData)

        let uploadData: Data
        let uploadResponse: URLResponse
        do {
            (uploadData, uploadResponse) = try await session.data(for: uploadRequest)
        } catch {
            throw STTError.networkError(error.localizedDescription)
        }
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
            throw STTError.networkError("Invalid non-HTTP response received.")
        }
        guard (200...299).contains(uploadHTTP.statusCode) else {
            throw mapHTTPError(statusCode: uploadHTTP.statusCode, serverMessage: parseErrorMessage(from: uploadData, statusCode: uploadHTTP.statusCode))
        }
        let fileURI = try parseUploadURI(from: uploadData)

        let interactionsRequest = try buildInteractionsRequest(fileURI: fileURI, language: language, prompt: prompt)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: interactionsRequest)
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
            return .httpError(statusCode: statusCode, message: "Invalid Gemini request (check audio/model): \(serverMessage)")
        case 401, 403:
            return .httpError(statusCode: statusCode, message: "Invalid Gemini API key: \(serverMessage)")
        case 429:
            return .httpError(statusCode: statusCode, message: "Gemini free-tier quota exceeded: \(serverMessage)")
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

    private func parseUploadURI(from data: Data) throws -> String {
        struct FileObject: Decodable {
            let uri: String?
            let name: String?
        }
        struct UploadResponse: Decodable {
            let file: FileObject?
            let uri: String?
            let name: String?
        }
        do {
            let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
            if let uri = decoded.file?.uri ?? decoded.uri, !uri.isEmpty { return uri }
            if let name = decoded.file?.name ?? decoded.name, !name.isEmpty { return name }
            throw STTError.decodingError("Files upload response missing file URI.")
        } catch let err as STTError {
            throw err
        } catch {
            throw STTError.decodingError(error.localizedDescription)
        }
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct OutputPart: Decodable {
            let text: String?
        }
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        struct Candidate: Decodable {
            let content: Content?
            let text: String?
        }
        struct InteractionsResponse: Decodable {
            let output_text: String?
            let text: String?
            let duration: Double?
            let durationSeconds: Double?
            let output: [OutputPart]?
            let candidates: [Candidate]?
        }
        do {
            let decoded = try JSONDecoder().decode(InteractionsResponse.self, from: data)
            let raw = decoded.output_text
                ?? decoded.text
                ?? decoded.output?.compactMap(\.text).first
                ?? decoded.candidates?.compactMap(\.text).first
                ?? decoded.candidates?.compactMap { $0.content?.parts?.compactMap(\.text).first }.first
            guard let raw else {
                throw STTError.decodingError("Interactions response missing output text.")
            }
            return TranscriptionResult(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: decoded.duration ?? decoded.durationSeconds ?? fallbackDuration,
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
