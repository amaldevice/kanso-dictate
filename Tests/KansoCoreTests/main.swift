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
let mismatchedRestore = TextInjector.restoreSnapshot(snapshot, to: customPasteboard, expectedChangeCount: expectedCount - 1)
assert(!mismatchedRestore, "Restore should be skipped when changeCount mismatches")
assert(customPasteboard.string(forType: .string) == "Transcribed voice fragment")
print("✔ TextInjector changeCount guard verified")

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

// Test 12: HistoryStore Persistence & Operations
let tempHistoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_history_\(UUID().uuidString).json")
let historyStore = HistoryStore(fileURL: tempHistoryURL)
assert(historyStore.records.isEmpty, "History store should initialize empty")

let record1 = HistoryRecord(text: "Test dictation 1", durationSeconds: 2.1, engineIdentifier: "remote.test")
let record2 = HistoryRecord(text: "Test dictation 2", durationSeconds: 4.5, engineIdentifier: "remote.test")

historyStore.addRecord(record1)
historyStore.addRecord(record2)

assert(historyStore.records.count == 2, "Expected 2 records")
assert(historyStore.records[0].text == "Test dictation 2", "Newest record must be first")
assert(historyStore.records[1].text == "Test dictation 1", "Second record mismatch")

// Verify re-loading from disk
let reloadedStore = HistoryStore(fileURL: tempHistoryURL)
assert(reloadedStore.records.count == 2, "Reloaded store must read persisted records")
assert(reloadedStore.records[0].text == "Test dictation 2")

// Verify clear
historyStore.clear()
assert(historyStore.records.isEmpty, "Cleared store must be empty")
let clearedReloadedStore = HistoryStore(fileURL: tempHistoryURL)
assert(clearedReloadedStore.records.isEmpty, "Persisted file should be cleared")
try? FileManager.default.removeItem(at: tempHistoryURL)
print("✔ HistoryStore add, persist, and clear verified")

// Test 13: EventTapManager Constants & Accessibility Inspection
assert(EventTapManager.Constants.rightOptionKeyCode == 0x3D, "Right Option keycode must be 0x3D")
assert(EventTapManager.Constants.rightOptionMask == 0x0020_0000, "Right Option mask must be 0x0020_0000")
_ = EventTapManager.isAccessibilityTrusted(prompt: false)
print("✔ EventTapManager constants and permission inspection verified")
// Test 14: WhisperKitConfig Defaults & Initialization
let defaultWKConfig = WhisperKitConfig()
assert(defaultWKConfig.modelFolder == nil, "Default modelFolder should be nil")
assert(defaultWKConfig.modelVariant == "openai_whisper-base", "Default variant should be openai_whisper-base")
assert(defaultWKConfig.downloadBase.path.contains("Library/Application Support/KansoDictate/models"), "Default downloadBase should point to Application Support/KansoDictate/models")
print("✔ WhisperKitConfig default properties verified")

// Test 15: WhisperKitEngine Model Path Normalization
let customModelFolder = URL(fileURLWithPath: "/Library/Application Support/KansoDictate/models/custom-model/")
let customWKConfig = WhisperKitConfig(
    modelFolder: customModelFolder,
    modelVariant: "openai_whisper-small",
    downloadBase: URL(fileURLWithPath: "/custom/cache/dir/")
)
let customWKEngine = WhisperKitEngine(config: customWKConfig)
assert(customWKEngine.effectiveModelFolder.path == "/Library/Application Support/KansoDictate/models/custom-model", "Explicit modelFolder should be standardized without trailing slash")

// Test derived hub cache path when modelFolder is nil
let defaultWKEngine = WhisperKitEngine(config: defaultWKConfig)
let expectedDerivedSuffix = "Library/Application Support/KansoDictate/models/models/argmaxinc/whisperkit-coreml/openai_whisper-base"
assert(defaultWKEngine.effectiveModelFolder.path.hasSuffix(expectedDerivedSuffix), "Effective model folder should derive canonical hub path: \(defaultWKEngine.effectiveModelFolder.path)")

// Test tilde expansion and path normalization
let tildeConfig = WhisperKitConfig(
    modelFolder: URL(fileURLWithPath: "~/models/whisper-test/"),
    downloadBase: URL(fileURLWithPath: "~/cache/whisper-test/")
)
assert(!tildeConfig.effectiveModelFolder.path.hasPrefix("~"), "Tilde should be expanded in effectiveModelFolder")
assert(!tildeConfig.downloadBase.path.hasPrefix("~"), "Tilde should be expanded in downloadBase")
assert(!tildeConfig.effectiveModelFolder.path.hasSuffix("/"), "Trailing slashes should be removed in normalized path")
print("✔ WhisperKitEngine model path normalization verified")

// Test 16: WhisperKitEngine SpeechToTextEngine Protocol Conformance
let engineAsSTT: any SpeechToTextEngine = defaultWKEngine
assert(engineAsSTT.isLocal == true, "WhisperKitEngine must be local (isLocal == true)")
assert(engineAsSTT.identifier == "whisperkit.openai_whisper-base", "Engine identifier mismatch: \(engineAsSTT.identifier)")
assert(engineAsSTT.displayName == "Local Whisper (openai_whisper-base)", "Display name mismatch: \(engineAsSTT.displayName)")
assert(customWKEngine.isLocal == true, "Custom engine must also be local")
assert(customWKEngine.identifier == "whisperkit.openai_whisper-small")
print("✔ WhisperKitEngine protocol conformance verified")

// Test 17: AudioDataParser Sample Extraction & Empty Guard
let testFloatSamples: [Float] = [0.5, -0.5, 0.25, -0.25]
let encodedWAV = WAVWriter.createWAVData(from: testFloatSamples, sampleRate: 16_000, channels: 1)
let decodedSamples = try AudioDataParser.extractFloatSamples(from: encodedWAV)
assert(decodedSamples.count == testFloatSamples.count, "Sample count mismatch")
for (orig, dec) in zip(testFloatSamples, decodedSamples) {
    assert(abs(orig - dec) < 0.001, "Decoded sample \(dec) differs from original \(orig)")
}

// Raw PCM extraction
var rawInt16Bytes = Data()
var int16Val: Int16 = 16384 // approx 0.5
rawInt16Bytes.append(Data(bytes: &int16Val, count: 2))
let rawDecoded = try AudioDataParser.extractFloatSamples(from: rawInt16Bytes)
assert(rawDecoded.count == 1)
assert(abs(rawDecoded[0] - 0.5) < 0.001)

do {
    _ = try AudioDataParser.extractFloatSamples(from: Data())
    assertionFailure("AudioDataParser should throw on empty data")
} catch let err as STTError {
    assert(err == .emptyAudioData)
}
print("✔ AudioDataParser sample extraction and empty audio guard verified")

// Test 18: WhisperTranscriptionActor Uninitialized Invariant
let isolatedActor = WhisperTranscriptionActor()
let actorReady = await isolatedActor.isReady
assert(!actorReady, "WhisperTranscriptionActor should not be ready prior to initialization")

do {
    _ = try await isolatedActor.transcribe(audioSamples: [0.1, 0.2])
    assertionFailure("transcribe() should throw when uninitialized")
} catch let transcriberError as WhisperTranscriberError {
    assert(transcriberError == .notInitialized, "Expected .notInitialized error, got \(transcriberError)")
    assert(transcriberError.localizedDescription.contains("not been initialized"))
}
print("✔ WhisperTranscriptionActor actor isolation and error invariants verified")

print("All KansoCore tests passed successfully! 🎉")
