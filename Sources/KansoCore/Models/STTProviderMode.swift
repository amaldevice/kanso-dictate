import Foundation

/// Supported Speech-to-Text provider execution modes.
public enum STTProviderMode: String, Codable, Sendable, CaseIterable {
    case remote
    case local
}
