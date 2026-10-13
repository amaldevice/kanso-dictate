import Foundation

/// Protocol abstracting audio recording capabilities for the dictation coordinator.
public protocol AudioRecordingService: Sendable {
    var isRecording: Bool { get }
    func startRecording() throws
    func stopRecording() throws -> AudioRecording
}

extension AudioRecorder: AudioRecordingService {}
