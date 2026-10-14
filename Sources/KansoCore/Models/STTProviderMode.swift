import Foundation

/// Supported Speech-to-Text provider execution modes.
public enum STTProviderMode: String, Codable, Sendable, CaseIterable {
    case remote
    case local
    case gemini
    case deepgram
    case cloudflare
    case assemblyai
    case speechmatics
    case revai
    case elevenlabs
}
