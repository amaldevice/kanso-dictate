import Foundation
import AppKit
import KansoCore

if CommandLine.arguments.contains("--test-mic") {
    print("🎙️ Kanso Dictate: Testing Microphone & AudioRecorder...")
    let recorder = AudioRecorder()

    do {
        print("Starting recording for 3 seconds...")
        try recorder.startRecording()
        Thread.sleep(forTimeInterval: 3.0)
        let recording = try recorder.stopRecording()

        let sampleCount = recording.samples.count
        var peak: Float = 0.0
        var sumSquares: Double = 0.0
        for s in recording.samples {
            let absVal = abs(s)
            if absVal > peak { peak = absVal }
            sumSquares += Double(s * s)
        }
        let rms = sqrt(sumSquares / Double(max(1, sampleCount)))

        print("✔ Recording stopped successfully:")
        print("  - Samples captured: \(sampleCount) (16kHz mono)")
        print("  - Measured duration: \(String(format: "%.2f", recording.durationSeconds))s")
        print("  - In-memory WAV size: \(recording.wavData.count) bytes")
        print("  - Peak volume: \(String(format: "%.4f", peak))")
        print("  - RMS volume: \(String(format: "%.4f", rms))")
        if peak > 0.001 {
            print("  - Status: Audible sound captured! 🔊")
        } else {
            print("  - Status: Silence or zero audio input captured.")
        }
    } catch {
        print("❌ Audio recording failed: \(error.localizedDescription)")
    }
} else if let keyIndex = CommandLine.arguments.firstIndex(of: "--test-remote"), keyIndex + 1 < CommandLine.arguments.count {
    let apiKey = CommandLine.arguments[keyIndex + 1]
    print("🌐 Kanso Dictate: Testing Remote STT with Groq / OpenAI...")
    let recorder = AudioRecorder()
    let config = OpenAICompatibleConfig(
        baseURL: URL(string: "https://api.groq.com/openai/v1")!,
        apiKey: apiKey,
        model: "whisper-large-v3-turbo"
    )
    let engine = OpenAICompatibleSTTEngine(config: config)

    Task {
        do {
            print("🎙️ Recording 3 seconds for transcription test...")
            try recorder.startRecording()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let recording = try recorder.stopRecording()
            print("⏳ Uploading \(recording.wavData.count) bytes to \(engine.displayName)...")
            let result = try await engine.transcribe(audioData: recording.wavData, language: "en", prompt: nil)
            print("✔ Transcription Succeeded! Result:")
            print("  - Text: \"\(result.text)\"")
            print("  - Duration: \(String(format: "%.2f", result.durationSeconds))s")
            exit(0)
        } catch {
            print("❌ Remote transcription failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let injectIndex = CommandLine.arguments.firstIndex(of: "--test-inject"), injectIndex + 1 < CommandLine.arguments.count {
    let textToPaste = CommandLine.arguments[injectIndex + 1]
    print("⌨️ Kanso Dictate: Testing TextInjector with simulated Cmd+V...")
    print("Switch focus to any text box in 2 seconds...")

    Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let injector = TextInjector(restoreDelayMs: 200)
        do {
            try await injector.inject(text: textToPaste)
            print("✔ Text injected successfully: \"\(textToPaste)\"")
            print("  - Clipboard will restore in 200ms.")
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        } catch {
            print("❌ Text injection failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    print("Kanso Dictate v0.1.0 (Menu Bar Dictation Assistant)")
    print("Usage options:")
    print("  swift run KansoDictate --test-mic")
    print("  swift run KansoDictate --test-remote <GROQ_OR_OPENAI_API_KEY>")
    print("  swift run KansoDictate --test-inject \"Hello world from Kanso\"")
}
