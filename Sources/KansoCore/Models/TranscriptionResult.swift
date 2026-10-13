import Foundation

/// Represents the completed transcription result from an STT engine.
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let durationSeconds: Double
    public let engineIdentifier: String
    public let timestamp: Date

    public init(
        text: String,
        durationSeconds: Double,
        engineIdentifier: String,
        timestamp: Date = Date()
    ) {
        self.text = text
        self.durationSeconds = durationSeconds
        self.engineIdentifier = engineIdentifier
        self.timestamp = timestamp
    }
}
