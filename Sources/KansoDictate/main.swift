import Foundation
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
} else {
    print("Kanso Dictate v0.1.0 (Menu Bar Dictation Assistant)")
    print("Run with '--test-mic' to test 3-second audio recording.")
}
