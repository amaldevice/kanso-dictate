import Foundation
import AppKit
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

// Test 6: OpenAICompatibleSTTEngine Endpoint Normalization
let groqConfig = OpenAICompatibleConfig(
    baseURL: URL(string: "https://api.groq.com/openai/v1")!,
    apiKey: "gsk_test123",
    model: "whisper-large-v3-turbo"
)
let groqEngine = OpenAICompatibleSTTEngine(config: groqConfig)
assert(groqEngine.endpointURL.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions", "Endpoint mismatch")

let trailingConfig = OpenAICompatibleConfig(
    baseURL: URL(string: "https://api.groq.com/openai/v1/")!,
    apiKey: "gsk_test123"
)
let trailingEngine = OpenAICompatibleSTTEngine(config: trailingConfig)
assert(trailingEngine.endpointURL.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions", "Trailing slash mismatch")

let fullConfig = OpenAICompatibleConfig(
    baseURL: URL(string: "http://localhost:8080/v1/audio/transcriptions")!
)
let fullEngine = OpenAICompatibleSTTEngine(config: fullConfig)
assert(fullEngine.endpointURL.absoluteString == "http://localhost:8080/v1/audio/transcriptions", "Full path mismatch")
print("✔ OpenAICompatibleSTTEngine endpoint URL resolution verified")

// Test 7: Multipart Request Building & Header Injection
let mockAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let fixedBoundary = "StaticTestBoundary"
let request = try groqEngine.buildRequest(
    audioData: mockAudio,
    language: "en",
    prompt: "Test context",
    boundary: fixedBoundary
)

assert(request.httpMethod == "POST", "Method must be POST")
assert(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=\(fixedBoundary)", "Content-Type header mismatch")
assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test123", "Authorization header mismatch")

guard let httpBody = request.httpBody, let bodyString = String(data: httpBody, encoding: .utf8) else {
    fatalError("Failed to decode HTTP body as UTF-8")
}

assert(bodyString.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"), "Missing model in body")
assert(bodyString.contains("name=\"response_format\"\r\n\r\nverbose_json"), "Missing response_format in body")
assert(bodyString.contains("name=\"language\"\r\n\r\nen"), "Missing language in body")
assert(bodyString.contains("name=\"prompt\"\r\n\r\nTest context"), "Missing prompt in body")
assert(bodyString.contains("filename=\"audio.wav\""), "Missing audio filename in body")
assert(bodyString.contains("--\(fixedBoundary)--"), "Missing closing boundary")
print("✔ OpenAICompatibleSTTEngine multipart body serialization verified")

// Test 8: Empty Audio Guard
do {
    _ = try groqEngine.buildRequest(audioData: Data(), language: nil, prompt: nil)
    assertionFailure("buildRequest must throw on empty audio")
} catch let error as STTError {
    assert(error == .emptyAudioData, "Expected .emptyAudioData, got \(error)")
    print("✔ Empty audio data rejection verified")
} catch {
    assertionFailure("Unexpected error type: \(error)")
}

// Test 9: TextInjector Pasteboard Snapshot & Restoration
let customPasteboard = NSPasteboard.withUniqueName()
customPasteboard.clearContents()
customPasteboard.setString("User original clipboard text", forType: .string)

let snapshot = TextInjector.captureSnapshot(from: customPasteboard)
assert(!snapshot.isEmpty, "Snapshot should not be empty")

// Mutate pasteboard with transient text
let injector = TextInjector(restoreDelayMs: 50, pasteboard: customPasteboard)
let expectedCount = injector.stageTransientText("Transcribed voice fragment")

// Verify transient types exist
let stagedTypes = customPasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? []
assert(stagedTypes.contains("org.nspasteboard.TransientType"), "Missing transient type")
assert(stagedTypes.contains("org.nspasteboard.AutoGeneratedType"), "Missing auto-generated type")
assert(customPasteboard.string(forType: .string) == "Transcribed voice fragment")
print("✔ TextInjector transient tagging verified")

// Test 10: ChangeCount Concurrency Guard
// If changeCount doesn't match expected, restore should fail and protect newer content
let mismatchedRestore = TextInjector.restoreSnapshot(snapshot, to: customPasteboard, expectedChangeCount: expectedCount - 1)
assert(!mismatchedRestore, "Restore should be skipped when changeCount mismatches")
assert(customPasteboard.string(forType: .string) == "Transcribed voice fragment")
print("✔ TextInjector changeCount guard verified")

// Valid restore should succeed and restore original content
let validRestore = TextInjector.restoreSnapshot(snapshot, to: customPasteboard, expectedChangeCount: expectedCount)
assert(validRestore, "Restore should succeed when changeCount matches")
assert(customPasteboard.string(forType: .string) == "User original clipboard text")
print("✔ TextInjector snapshot restore verified")

// Test 11: Empty Text Injection Guard
do {
    let dummyInjector = TextInjector(restoreDelayMs: 10, pasteboard: customPasteboard)
    _ = Task {
        do {
            try await dummyInjector.inject(text: "   \n\t  ")
            assertionFailure("inject() should throw on empty text")
        } catch let error as TextInjectorError {
            assert(error == .emptyText)
        }
    }
}
print("✔ TextInjector empty text guard verified")

print("All KansoCore tests passed successfully! 🎉")
