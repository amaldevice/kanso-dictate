import Foundation

/// Errors produced during remote STT transcription requests.
public enum STTError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case emptyAudioData
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url):
            return "Invalid STT endpoint URL: \(url)"
        case .emptyAudioData:
            return "Cannot transcribe empty audio data."
        case .httpError(let code, let message):
            return "STT server returned HTTP \(code): \(message)"
        case .decodingError(let detail):
            return "Failed to parse STT server response: \(detail)"
        case .networkError(let detail):
            return "Network communication failure: \(detail)"
        }
    }
}

/// Configuration options for OpenAI-compatible transcription services (Groq, OpenAI, Ollama, etc.).
public struct OpenAICompatibleConfig: Sendable, Equatable {
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let timeoutInterval: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.groq.com/openai/v1")!,
        apiKey: String? = nil,
        model: String = "whisper-large-v3-turbo",
        timeoutInterval: TimeInterval = 30.0
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeoutInterval = timeoutInterval
    }
}

/// Polymorphic STT engine communicating with any OpenAI-compatible `/v1/audio/transcriptions` API.
public final class OpenAICompatibleSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    public let identifier: String
    public let displayName: String
    public let isLocal: Bool = false
    public let config: OpenAICompatibleConfig

    private let session: URLSession

    public init(
        config: OpenAICompatibleConfig,
        session: URLSession = .shared
    ) {
        self.config = config
        self.identifier = "remote.\(config.model)"
        self.displayName = "Remote (\(config.model))"
        self.session = session
    }

    /// Resolves the canonical full transcription endpoint URL.
    public var endpointURL: URL {
        let path = config.baseURL.absoluteString
        if path.hasSuffix("/audio/transcriptions") {
            return config.baseURL
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return URL(string: "\(trimmed)/audio/transcriptions") ?? config.baseURL
    }

    /// Builds a multipart/form-data POST URLRequest for transcription.
    public func buildRequest(
        audioData: Data,
        language: String?,
        prompt: String?,
        boundary: String = "Boundary-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard !audioData.isEmpty else {
            throw STTError.emptyAudioData
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()

        // Helper to append a form field
        func appendFormField(name: String, value: String) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }

        // 1. Model field
        appendFormField(name: "model", value: config.model)

        // 2. Response format
        appendFormField(name: "response_format", value: "verbose_json")

        // 3. Optional Language
        if let language = language, !language.isEmpty {
            appendFormField(name: "language", value: language)
        }

        // 4. Optional Prompt
        if let prompt = prompt, !prompt.isEmpty {
            appendFormField(name: "prompt", value: prompt)
        }

        // 5. Audio File field
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n".utf8)

        // Closing boundary
        body.append(contentsOf: "--\(boundary)--\r\n".utf8)

        request.httpBody = body
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

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.networkError("Invalid non-HTTP response received.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = parseErrorMessage(from: data, statusCode: httpResponse.statusCode)
            throw STTError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        return try parseSuccessResponse(from: data, fallbackDuration: elapsed)
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        struct ErrorWrapper: Decodable {
            struct InnerError: Decodable {
                let message: String?
            }
            let error: InnerError?
            let message: String?
        }

        if let decoded = try? JSONDecoder().decode(ErrorWrapper.self, from: data) {
            if let msg = decoded.error?.message, !msg.isEmpty {
                return msg
            }
            if let msg = decoded.message, !msg.isEmpty {
                return msg
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "Unknown error (HTTP \(statusCode))"
    }

    private func parseSuccessResponse(from data: Data, fallbackDuration: Double) throws -> TranscriptionResult {
        struct RawResponse: Decodable {
            let text: String
            let duration: Double?
        }

        do {
            let decoded = try JSONDecoder().decode(RawResponse.self, from: data)
            let trimmedText = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptionResult(
                text: trimmedText,
                durationSeconds: decoded.duration ?? fallbackDuration,
                engineIdentifier: identifier,
                timestamp: Date()
            )
        } catch {
            throw STTError.decodingError(error.localizedDescription)
        }
    }
}
