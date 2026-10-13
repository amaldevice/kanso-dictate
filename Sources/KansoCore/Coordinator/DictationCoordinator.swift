import Foundation
import AppKit

/// Observable state of the dictation pipeline.
public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    case error(String)
}

/// Central coordinator driving audio recording, transcription, text injection, and persistence.
@MainActor
public final class DictationCoordinator: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var lastTranscribedText: String = ""

    public let recorder: AudioRecorder
    public let injector: TextInjector
    public let historyStore: HistoryStore
    public var activeEngine: any SpeechToTextEngine

    public init(
        recorder: AudioRecorder = AudioRecorder(),
        injector: TextInjector = TextInjector(),
        historyStore: HistoryStore = HistoryStore(),
        activeEngine: any SpeechToTextEngine
    ) {
        self.recorder = recorder
        self.injector = injector
        self.historyStore = historyStore
        self.activeEngine = activeEngine
    }

    /// Starts audio recording for dictation.
    public func startDictation() {
        guard state == .idle || (ifCaseError(state)) else { return }

        do {
            try recorder.startRecording()
            state = .recording
            NSSound.beep() // Subtle auditory feedback
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops audio recording, invokes STT engine, and injects transcribed text.
    public func stopDictation() {
        guard state == .recording else { return }

        state = .transcribing
        NSSound.beep()

        Task {
            do {
                let recording = try recorder.stopRecording()
                guard recording.durationSeconds >= 0.3 else {
                    // Tap was too brief; abort without error
                    state = .idle
                    return
                }

                let result = try await activeEngine.transcribe(
                    audioData: recording.wavData,
                    language: nil,
                    prompt: nil
                )

                lastTranscribedText = result.text

                if !result.text.isEmpty {
                    state = .inserting
                    try await injector.inject(text: result.text)

                    let record = HistoryRecord(
                        text: result.text,
                        durationSeconds: recording.durationSeconds,
                        engineIdentifier: result.engineIdentifier,
                        timestamp: Date()
                    )
                    historyStore.addRecord(record)
                }

                state = .idle
            } catch {
                state = .error("Transcription/Injection failed: \(error.localizedDescription)")
            }
        }
    }

    private func ifCaseError(_ state: DictationState) -> Bool {
        if case .error = state { return true }
        return false
    }
}
