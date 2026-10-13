import Foundation

/// Unified interface for all Speech-to-Text engines in Kanso Dictate.
public protocol SpeechToTextEngine: Sendable {
    /// Unique identifier for this engine implementation (e.g. "whisperkit.base", "groq.whisper-turbo").
    var identifier: String { get }

    /// Human-friendly display name.
    var displayName: String { get }

    /// Indicates whether this engine runs 100% locally on-device.
    var isLocal: Bool { get }

    /// Transcribes an audio payload (16kHz mono WAV or PCM data).
    /// - Parameters:
    ///   - audioData: Raw audio bytes (WAV or raw PCM).
    ///   - language: Optional ISO language code (e.g., "en", "id").
    ///   - prompt: Optional context prompt to bias vocabulary.
    /// - Returns: A completed `TranscriptionResult`.
    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult
}
