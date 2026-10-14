import Foundation

/// Verified OpenAI-compatible remote presets (Track 0). No new engine code:
/// each preset resolves to baseURL + model for the existing remote engine.
public enum STTRemotePreset: String, CaseIterable, Sendable {
    case voxtral
    case fireworks
    case together

    public var displayName: String {
        switch self {
        case .voxtral: "Mistral Voxtral"
        case .fireworks: "Fireworks AI"
        case .together: "Together AI"
        }
    }

    public var baseURL: URL {
        switch self {
        case .voxtral: URL(string: "https://api.mistral.ai/v1")!
        case .fireworks: URL(string: "https://api.fireworks.ai/inference/v1")!
        case .together: URL(string: "https://api.together.xyz/v1")!
        }
    }

    public var model: String {
        switch self {
        case .voxtral: "voxtral-mini-latest"
        case .fireworks: "whisper-v3-turbo"
        case .together: "openai/whisper-large-v3"
        }
    }

    public func makeConfig(apiKey: String?) -> OpenAICompatibleConfig {
        OpenAICompatibleConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}
