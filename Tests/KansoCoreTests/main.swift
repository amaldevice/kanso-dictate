import Foundation
import KansoCore

print("Running KansoCore test suite...")

// Test 1: TranscriptionResult properties
let now = Date()
let result = TranscriptionResult(
    text: "Hello world",
    durationSeconds: 1.5,
    engineIdentifier: "test.engine",
    timestamp: now
)
assert(result.text == "Hello world", "Text mismatch")
assert(result.durationSeconds == 1.5, "Duration mismatch")
assert(result.engineIdentifier == "test.engine", "Engine mismatch")
assert(result.timestamp == now, "Timestamp mismatch")
print("✔ TranscriptionResult verified")

// Test 2: WAVWriter generation
let sampleCount = 16_000 // 1 second of audio at 16kHz
let samples: [Float] = Array(repeating: 0.5, count: sampleCount)
let wavData = WAVWriter.createWAVData(from: samples, sampleRate: 16_000, channels: 1)

assert(wavData.count == 32_044, "Expected 32,044 bytes, got \(wavData.count)")

let riffHeader = String(data: wavData.subdata(in: 0..<4), encoding: .utf8)
let waveHeader = String(data: wavData.subdata(in: 8..<12), encoding: .utf8)
let fmtHeader = String(data: wavData.subdata(in: 12..<16), encoding: .utf8)
let dataHeader = String(data: wavData.subdata(in: 36..<40), encoding: .utf8)

assert(riffHeader == "RIFF", "RIFF header mismatch")
assert(waveHeader == "WAVE", "WAVE header mismatch")
assert(fmtHeader == "fmt ", "fmt header mismatch")
assert(dataHeader == "data", "data header mismatch")

let sampleRate = wavData.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
assert(sampleRate == 16_000, "Sample rate mismatch: \(sampleRate)")

let channels = wavData.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
assert(channels == 1, "Channels mismatch: \(channels)")

let bitsPerSample = wavData.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
assert(bitsPerSample == 16, "Bits per sample mismatch: \(bitsPerSample)")
print("✔ WAVWriter standard header & byte count verified")

// Test 3: Float clamping
let extremeSamples: [Float] = [-2.5, 0.0, 3.0]
let clampedWav = WAVWriter.createWAVData(from: extremeSamples, sampleRate: 16_000, channels: 1)
assert(clampedWav.count == 44 + (3 * 2), "Clamped WAV size mismatch")

let pcmData = clampedWav.subdata(in: 44..<clampedWav.count)
pcmData.withUnsafeBytes { buffer in
    let int16s = buffer.bindMemory(to: Int16.self)
    assert(int16s[0] == -32767, "Negative clamping failed: \(int16s[0])")
    assert(int16s[1] == 0, "Zero conversion failed: \(int16s[1])")
    assert(int16s[2] == 32767, "Positive clamping failed: \(int16s[2])")
}
print("✔ WAVWriter float clamping verified")

// Test 4: AudioRecorder State Machine & Invariants
let recorder = AudioRecorder()
assert(!recorder.isRecording, "AudioRecorder should initialize with isRecording == false")

do {
    _ = try recorder.stopRecording()
    assertionFailure("stopRecording should throw .notRecording when not active")
} catch let error as AudioRecorderError {
    assert(error.localizedDescription.contains("not currently recording"), "Wrong error description: \(error)")
    print("✔ AudioRecorder throws expected .notRecording when idle")
} catch {
    assertionFailure("Unexpected error type: \(error)")
}

// Test 5: AudioRecording Data Container
let testRecording = AudioRecording(wavData: wavData, samples: samples, durationSeconds: 1.0)
assert(testRecording.wavData.count == 32_044)
assert(testRecording.samples.count == 16_000)
assert(testRecording.durationSeconds == 1.0)
print("✔ AudioRecording container contract verified")

print("All KansoCore tests passed successfully! 🎉")
