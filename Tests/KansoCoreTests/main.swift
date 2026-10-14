import Foundation
import AppKit
import Combine
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

// Test 19: DictationCoordinator Micro-Tap Guard & Flow
final class MockAudioRecorder: AudioRecordingService, @unchecked Sendable {
    var stubbedDuration: Double
    var isRecording: Bool = false
    var startRecordingCalled = false
    var stopRecordingCalled = false

    init(stubbedDuration: Double = 0.1) {
        self.stubbedDuration = stubbedDuration
    }

    func startRecording() throws {
        startRecordingCalled = true
        isRecording = true
    }

    func stopRecording() throws -> AudioRecording {
        stopRecordingCalled = true
        isRecording = false
        return AudioRecording(
            wavData: Data([0x52, 0x49, 0x46, 0x46]),
            samples: [0.0],
            durationSeconds: stubbedDuration
        )
    }
}

final class MockSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    let identifier = "mock.stt"
    let displayName = "Mock STT"
    let isLocal = true

    var transcribeCallCount = 0

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        return TranscriptionResult(
            text: "Mock transcript",
            durationSeconds: 1.0,
            engineIdentifier: identifier,
            timestamp: Date()
        )
    }
}

// Test 20: DictationCoordinator Error Notification & Automatic Recovery
struct MockFailingSTTEngine: SpeechToTextEngine {
    let identifier: String = "mock.failing"
    let displayName: String = "Mock Failing Engine"
    let isLocal: Bool = false
    let errorMessage: String

    init(errorMessage: String = "Simulated network failure") {
        self.errorMessage = errorMessage
    }

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        throw STTError.networkError(errorMessage)
    }
}
@MainActor
func testMicroTapGuard() async {
    let mockRecorderA = MockAudioRecorder(stubbedDuration: 0.15)
    let mockEngineA = MockSTTEngine()
    let coordinatorA = DictationCoordinator(
        recorder: mockRecorderA,
        activeEngine: mockEngineA
    )

    assert(coordinatorA.state == .idle, "Initial state must be idle")
    coordinatorA.startDictation()
    assert(coordinatorA.state == .recording, "State must be recording after start")
    assert(mockRecorderA.startRecordingCalled, "startRecording must be called")

    coordinatorA.stopDictation()
    assert(coordinatorA.state == .idle, "State must immediately reset to idle on micro-tap (<0.3s)")
    assert(mockRecorderA.stopRecordingCalled, "stopRecording must be called")
    assert(mockEngineA.transcribeCallCount == 0, "STT must NOT be invoked on micro-tap")

    let mockRecorderB = MockAudioRecorder(stubbedDuration: 0.29)
    let mockEngineB = MockSTTEngine()
    let coordinatorB = DictationCoordinator(
        recorder: mockRecorderB,
        activeEngine: mockEngineB
    )
    coordinatorB.startDictation()
    assert(coordinatorB.state == .recording)
    coordinatorB.stopDictation()
    assert(coordinatorB.state == .idle, "Boundary 0.29s tap must reset to idle")
    assert(mockEngineB.transcribeCallCount == 0, "STT must NOT be invoked on 0.29s tap")

    let mockRecorderC = MockAudioRecorder(stubbedDuration: 0.5)
    let mockEngineC = MockSTTEngine()
    let coordinatorC = DictationCoordinator(
        recorder: mockRecorderC,
        activeEngine: mockEngineC
    )
    coordinatorC.startDictation()
    assert(coordinatorC.state == .recording)
    coordinatorC.stopDictation()
    assert(coordinatorC.state == .transcribing, "State must transition to transcribing for valid duration")

    try? await Task.sleep(nanoseconds: 100_000_000)
    assert(mockEngineC.transcribeCallCount == 1, "STT must be invoked for recording >= 0.3s")
    assert(coordinatorC.state == .idle, "State must return to idle after transcription & injection")
    assert(coordinatorC.lastTranscribedText == "Mock transcript", "Transcribed text mismatch")
}

await testMicroTapGuard()
print("✔ DictationCoordinator micro-tap guard (<0.3s rejection) verified")

@MainActor
func testErrorNotificationAndRecovery() async {
    let mockRecorder = MockAudioRecorder(stubbedDuration: 1.0)
    let mockEngine = MockFailingSTTEngine(errorMessage: "Simulated network failure")
    let coordinator = DictationCoordinator(
        recorder: mockRecorder,
        activeEngine: mockEngine
    )

    var receivedErrorNotification: String?
    coordinator.onErrorNotification = { message in
        receivedErrorNotification = message
    }

    assert(coordinator.state == .idle, "Coordinator must start in .idle state")
    coordinator.startDictation()
    assert(coordinator.state == .recording, "Coordinator should transition to .recording")

    coordinator.stopDictation()
    assert(coordinator.state == .transcribing, "Coordinator should transition to .transcribing")

    var waitCount = 0
    while waitCount < 50 {
        if case .error = coordinator.state {
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitCount += 1
    }

    guard case .error(let err) = coordinator.state else {
        fatalError("Coordinator failed to enter .error state")
    }
    assert(err.contains("Simulated network failure"), "Error message mismatch: \(err)")
    assert(receivedErrorNotification != nil, "onErrorNotification callback should have been fired")
    assert(receivedErrorNotification?.contains("Simulated network failure") == true, "Notification callback received wrong message")

    // Automatic recovery on next startDictation
    coordinator.startDictation()
    assert(coordinator.state == .recording, "startDictation must clear .error state and transition to .recording")

    mockRecorder.stubbedDuration = 0.1
    coordinator.stopDictation()
    assert(coordinator.state == .idle, "Brief stop should return coordinator to .idle")
}

await testErrorNotificationAndRecovery()
print("✔ DictationCoordinator error notification and recovery verified")

// Test 21: DictationCoordinator Dynamic Engine Switching
final class MockLocalEngine: SpeechToTextEngine, @unchecked Sendable {
    let identifier = "mock.local.whisperkit"
    let displayName = "Mock Local Whisper"
    let isLocal = true
    var transcribeCallCount = 0

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        return TranscriptionResult(
            text: "Transcribed locally",
            durationSeconds: 1.0,
            engineIdentifier: identifier,
            timestamp: Date()
        )
    }
}

final class MockRemoteEngine: SpeechToTextEngine, @unchecked Sendable {
    let identifier = "mock.remote.openai"
    let displayName = "Mock Remote OpenAI"
    let isLocal = false
    var transcribeCallCount = 0

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        return TranscriptionResult(
            text: "Transcribed remotely",
            durationSeconds: 1.0,
            engineIdentifier: identifier,
            timestamp: Date()
        )
    }
}

@MainActor
func testDynamicEngineSwitching() async {
    let recorder = MockAudioRecorder(stubbedDuration: 1.0)
    let localEngine = MockLocalEngine()
    let remoteEngine = MockRemoteEngine()

    let coordinator = DictationCoordinator(
        recorder: recorder,
        activeEngine: localEngine
    )

    // 1. Initial engine state
    assert(coordinator.activeEngine.identifier == "mock.local.whisperkit", "Initial engine should be local")
    assert(coordinator.activeEngine.displayName == "Mock Local Whisper", "Initial displayName mismatch")
    assert(coordinator.activeEngine.isLocal == true, "Initial engine should be local")

    // Dispatch dictation using local engine
    coordinator.startDictation()
    coordinator.stopDictation()

    var waitCount = 0
    while waitCount < 50 {
        if coordinator.state == .idle && localEngine.transcribeCallCount == 1 {
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitCount += 1
    }

    assert(localEngine.transcribeCallCount == 1, "Local engine should have received transcription dispatch")
    assert(remoteEngine.transcribeCallCount == 0, "Remote engine should not have been called")
    assert(coordinator.lastTranscribedText == "Transcribed locally", "Transcript should match local engine output")

    // 2. Switch to remote engine dynamically via setEngine
    coordinator.setEngine(remoteEngine)
    assert(coordinator.activeEngine.identifier == "mock.remote.openai", "Switched engine identifier should be remote")
    assert(coordinator.activeEngine.displayName == "Mock Remote OpenAI", "Switched engine displayName mismatch")
    assert(coordinator.activeEngine.isLocal == false, "Switched engine should not be local")

    // Dispatch dictation using remote engine
    coordinator.startDictation()
    coordinator.stopDictation()

    waitCount = 0
    while waitCount < 50 {
        if coordinator.state == .idle && remoteEngine.transcribeCallCount == 1 {
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitCount += 1
    }

    assert(remoteEngine.transcribeCallCount == 1, "Remote engine should now have received transcription dispatch")
    assert(localEngine.transcribeCallCount == 1, "Local engine call count should not change")
    assert(coordinator.lastTranscribedText == "Transcribed remotely", "Transcript should match remote engine output")

    // 3. Switch back to local engine
    coordinator.setEngine(localEngine)
    assert(coordinator.activeEngine.identifier == "mock.local.whisperkit", "Switched back to local engine")
    assert(coordinator.activeEngine.displayName == "Mock Local Whisper")
    assert(coordinator.activeEngine.isLocal == true)

    coordinator.startDictation()
    coordinator.stopDictation()

    waitCount = 0
    while waitCount < 50 {
        if coordinator.state == .idle && localEngine.transcribeCallCount == 2 {
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitCount += 1
    }

    assert(localEngine.transcribeCallCount == 2, "Local engine should receive second transcription dispatch")
    assert(remoteEngine.transcribeCallCount == 1, "Remote engine call count should still be 1")
    assert(coordinator.lastTranscribedText == "Transcribed locally")

    // 4. Test configureEngineFromPreferences(defaults:) switching
    let suiteName = "test.dictation.switching.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    // Verify STTProviderMode enum
    assert(STTProviderMode.allCases == [.remote, .local, .gemini, .deepgram, .cloudflare, .assemblyai, .speechmatics, .revai, .elevenlabs])
    assert(STTProviderMode.remote.rawValue == "remote")
    assert(STTProviderMode.local.rawValue == "local")
    assert(STTProviderMode(rawValue: "remote") == .remote)
    assert(STTProviderMode(rawValue: "local") == .local)

    // Test local configuration from preferences
    testDefaults.set(STTProviderMode.local.rawValue, forKey: "stt_provider_mode")
    testDefaults.set("openai_whisper-base", forKey: "whisperkit_model_variant")
    coordinator.configureEngineFromPreferences(defaults: testDefaults)
    assert(coordinator.activeEngine.identifier == "whisperkit.openai_whisper-base", "Configured engine should be WhisperKit base")
    assert(coordinator.activeEngine.displayName == "Local Whisper (openai_whisper-base)")
    assert(coordinator.activeEngine.isLocal == true)

    // Test remote configuration from preferences
    testDefaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    testDefaults.set("whisper-large-v3-turbo", forKey: "stt_model")
    coordinator.configureEngineFromPreferences(defaults: testDefaults)
    assert(coordinator.activeEngine.identifier == "remote.whisper-large-v3-turbo", "Configured engine should be remote whisper")
    assert(coordinator.activeEngine.displayName == "Remote (whisper-large-v3-turbo)")
    assert(coordinator.activeEngine.isLocal == false)

    testDefaults.removePersistentDomain(forName: suiteName)
}

await testDynamicEngineSwitching()
print("✔ DictationCoordinator dynamic engine switching verified")

// Test 22: Exhaustive End-to-End Walking Skeleton Integration Test
final class E2EMockAudioRecorder: AudioRecordingService, @unchecked Sendable {
    var stubbedDuration: Double
    var isRecording: Bool = false
    var startRecordingCalled = false
    var stopRecordingCalled = false
    let sampleData: Data

    init(stubbedDuration: Double = 1.2) {
        self.stubbedDuration = stubbedDuration
        let sampleCount = Int(16_000 * stubbedDuration)
        let samples: [Float] = Array(repeating: 0.1, count: sampleCount)
        self.sampleData = WAVWriter.createWAVData(from: samples, sampleRate: 16_000, channels: 1)
    }

    func startRecording() throws {
        startRecordingCalled = true
        isRecording = true
    }

    func stopRecording() throws -> AudioRecording {
        stopRecordingCalled = true
        isRecording = false
        let sampleCount = Int(16_000 * stubbedDuration)
        return AudioRecording(
            wavData: sampleData,
            samples: Array(repeating: 0.1, count: sampleCount),
            durationSeconds: stubbedDuration
        )
    }
}

final class E2EMockSTTEngine: SpeechToTextEngine, @unchecked Sendable {
    let identifier = "e2e.mock.engine"
    let displayName = "E2E Mock Engine"
    let isLocal = true

    var transcribeCallCount = 0
    var receivedAudioData: Data?
    let transcriptionText: String

    init(transcriptionText: String = "Walking skeleton end-to-end integration transcription text") {
        self.transcriptionText = transcriptionText
    }

    func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        receivedAudioData = audioData
        return TranscriptionResult(
            text: transcriptionText,
            durationSeconds: 1.2,
            engineIdentifier: identifier,
            timestamp: Date()
        )
    }
}

@MainActor
func testEndToEndWalkingSkeleton() async {
    let testStartTime = Date()
    let expectedText = "Walking skeleton end-to-end integration transcription text"
    let recordingDuration = 1.2

    // 1. Isolated custom pasteboard
    let customPasteboard = NSPasteboard.withUniqueName()
    customPasteboard.clearContents()
    customPasteboard.setString("Prior clipboard content", forType: .string)

    // 2. Temporary file-backed HistoryStore
    let tempHistoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_e2e_history_\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: tempHistoryURL)
    }
    let historyStore = HistoryStore(fileURL: tempHistoryURL)
    assert(historyStore.records.isEmpty, "Initial history store must be empty")

    // 3. Mock audio recorder & mock STT engine
    let recorder = E2EMockAudioRecorder(stubbedDuration: recordingDuration)
    let engine = E2EMockSTTEngine(transcriptionText: expectedText)
    let injector = TextInjector(restoreDelayMs: 400, pasteboard: customPasteboard)

    let coordinator = DictationCoordinator(
        recorder: recorder,
        injector: injector,
        historyStore: historyStore,
        activeEngine: engine
    )

    // 4. Simulated hotkey trigger wiring (EventTapManager Right Option Push-To-Talk)
    let eventTapManager = EventTapManager()
    eventTapManager.onKeyDown = { [weak coordinator] in
        Task { @MainActor in
            coordinator?.startDictation()
        }
    }
    eventTapManager.onKeyUp = { [weak coordinator] in
        Task { @MainActor in
            coordinator?.stopDictation()
        }
    }

    // 5. Track state progression (.idle -> .recording -> .transcribing -> .inserting -> .idle)
    var observedStates: [DictationState] = []
    var cancellables = Set<AnyCancellable>()
    coordinator.$state
        .sink { state in
            observedStates.append(state)
        }
        .store(in: &cancellables)

    assert(coordinator.state == .idle, "Initial coordinator state must be .idle")

    // 6. Simulate hotkey press (Key Down)
    eventTapManager.onKeyDown?()

    // Wait for transition to .recording
    var waitCount = 0
    while waitCount < 50 && coordinator.state != .recording {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waitCount += 1
    }
    assert(coordinator.state == .recording, "Coordinator must be in .recording state")
    assert(recorder.startRecordingCalled, "AudioRecorder startRecording must have been called")
    assert(recorder.isRecording, "AudioRecorder isRecording must be true")

    // 7. Simulate hotkey release (Key Up)
    eventTapManager.onKeyUp?()

    // 8. Wait for pipeline completion: recording -> transcribing -> inserting -> idle
    waitCount = 0
    while waitCount < 100 {
        if coordinator.state == .idle && !historyStore.records.isEmpty {
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitCount += 1
    }

    // 9. Validate state progression
    let expectedStates: [DictationState] = [.idle, .recording, .transcribing, .inserting, .idle]
    assert(
        observedStates == expectedStates,
        "Observed state progression mismatch. Expected \(expectedStates), got \(observedStates)"
    )
    assert(coordinator.state == .idle, "Final coordinator state must be .idle")
    assert(recorder.stopRecordingCalled, "AudioRecorder stopRecording must have been called")
    assert(engine.transcribeCallCount == 1, "Mock STT engine transcribe must be called once")
    assert(engine.receivedAudioData?.count == recorder.sampleData.count, "Transcribed audio data mismatch")
    assert(coordinator.lastTranscribedText == expectedText, "Coordinator lastTranscribedText mismatch")

    // 10. Validate text appeared on pasteboard and transient markers were applied
    assert(
        customPasteboard.string(forType: .string) == expectedText,
        "Transcribed text must appear on isolated pasteboard"
    )
    let pasteboardTypes = customPasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? []
    assert(
        pasteboardTypes.contains("org.nspasteboard.TransientType"),
        "Pasteboard must contain TransientType marker"
    )
    assert(
        pasteboardTypes.contains("org.nspasteboard.AutoGeneratedType"),
        "Pasteboard must contain AutoGeneratedType marker"
    )

    // 11. Validate persistent HistoryStore append with correct metadata
    assert(historyStore.records.count == 1, "HistoryStore must contain exactly 1 record")
    let record = historyStore.records[0]
    assert(record.text == expectedText, "Record text mismatch: \(record.text)")
    assert(record.durationSeconds == recordingDuration, "Record duration mismatch: \(record.durationSeconds)")
    assert(record.engineIdentifier == "e2e.mock.engine", "Record engineIdentifier mismatch: \(record.engineIdentifier)")
    assert(record.timestamp >= testStartTime, "Record timestamp must be >= testStartTime")
    assert(record.timestamp <= Date(), "Record timestamp must be <= now")

    // 12. Validate disk persistence: re-read from temporary JSON file
    let reloadedStore = HistoryStore(fileURL: tempHistoryURL)
    assert(reloadedStore.records.count == 1, "Reloaded HistoryStore must contain 1 persisted record")
    let persistedRecord = reloadedStore.records[0]
    assert(persistedRecord.id == record.id, "Persisted record ID mismatch")
    assert(persistedRecord.text == expectedText, "Persisted record text mismatch")
    assert(persistedRecord.durationSeconds == recordingDuration, "Persisted record duration mismatch")
    assert(persistedRecord.engineIdentifier == "e2e.mock.engine", "Persisted record engine mismatch")
    assert(persistedRecord.timestamp == record.timestamp, "Persisted record timestamp mismatch")

    // 13. Validate clipboard snapshot restoration after restore delay
    try? await Task.sleep(nanoseconds: 500_000_000)
    assert(
        customPasteboard.string(forType: .string) == "Prior clipboard content",
        "Pasteboard must be restored to prior clipboard content after restore delay"
    )
}

await testEndToEndWalkingSkeleton()
print("✔ End-to-End Walking Skeleton integration test verified")

// Test 23: STTRemotePreset resolution (Track 0 presets)
assert(STTRemotePreset.allCases.count == 3, "Expected 3 remote presets")
assert(STTRemotePreset.voxtral.baseURL.absoluteString == "https://api.mistral.ai/v1", "Voxtral baseURL mismatch")
assert(STTRemotePreset.voxtral.model == "voxtral-mini-latest", "Voxtral model mismatch")
assert(STTRemotePreset.fireworks.baseURL.absoluteString == "https://api.fireworks.ai/inference/v1", "Fireworks baseURL mismatch")
assert(STTRemotePreset.fireworks.model == "whisper-v3-turbo", "Fireworks model mismatch")
assert(STTRemotePreset.together.baseURL.absoluteString == "https://api.together.xyz/v1", "Together baseURL mismatch")
assert(STTRemotePreset.together.model == "openai/whisper-large-v3", "Together model mismatch")
let voxtralCfg = STTRemotePreset.voxtral.makeConfig(apiKey: "test-key")
assert(voxtralCfg.baseURL == STTRemotePreset.voxtral.baseURL, "Preset config baseURL mismatch")
assert(voxtralCfg.model == "voxtral-mini-latest", "Preset config model mismatch")
assert(voxtralCfg.apiKey == "test-key", "Preset config apiKey mismatch")
print("✔ STTRemotePreset resolution verified")

// Test 24: Preset request shape at the Speech-to-Text Engine seam
let presetEngine = OpenAICompatibleSTTEngine(config: STTRemotePreset.fireworks.makeConfig(apiKey: "fw-test"))
assert(presetEngine.endpointURL.absoluteString == "https://api.fireworks.ai/inference/v1/audio/transcriptions", "Preset endpoint mismatch")
let presetReq = try presetEngine.buildRequest(audioData: mockAudio, language: "id", prompt: nil, boundary: fixedBoundary)
assert(presetReq.value(forHTTPHeaderField: "Authorization") == "Bearer fw-test", "Preset auth header mismatch")
guard let presetBody = presetReq.httpBody, let presetStr = String(data: presetBody, encoding: .utf8) else {
    fatalError("Failed to decode preset HTTP body")
}
assert(presetStr.contains("name=\"model\"\r\n\r\nwhisper-v3-turbo"), "Preset model missing in body")
assert(presetStr.contains("name=\"language\"\r\n\r\nid"), "Preset language missing in body")
print("✔ Preset request shape at STT seam verified")

// Test 23: GeminiSTTEngine request shape (Files upload + Interactions)
// Test 23: GeminiSTTEngine request shape (generateContent with inline_data)
let geminiConfig = GeminiSTTConfig(apiKey: "AIza-test-key", model: "gemini-1.5-flash")
let geminiEngine = GeminiSTTEngine(config: geminiConfig)
assert(geminiEngine.identifier == "gemini.gemini-1.5-flash", "Gemini identifier mismatch: \(geminiEngine.identifier)")
assert(geminiEngine.isLocal == false, "Gemini must be remote (isLocal == false)")
assert(GeminiSTTConfig.defaultModel == "gemini-1.5-flash", "Default model mismatch")
let geminiAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let genRequest = try geminiEngine.buildRequest(audioData: geminiAudio, language: "id", prompt: "Kanso, Whisper")
assert(genRequest.httpMethod == "POST", "Request must be POST")
assert(genRequest.url?.absoluteString.contains("generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent") == true, "URL mismatch: \(genRequest.url?.absoluteString ?? "")")
assert(genRequest.url?.query?.contains("key=AIza-test-key") == true, "Query must contain key")
assert(genRequest.value(forHTTPHeaderField: "Content-Type") == "application/json", "Content-Type mismatch")
let genBody = try JSONSerialization.jsonObject(with: genRequest.httpBody!) as! [String: Any]
let contents = genBody["contents"] as! [[String: Any]]
let parts = contents[0]["parts"] as! [[String: Any]]
assert(parts.count == 2, "Expected 2 parts: prompt and inline_data")
let instructionText = parts[0]["text"] as! String
assert(instructionText.contains("Spoken language code: id"), "Instruction must contain language hint")
assert(instructionText.contains("Context vocabulary: Kanso, Whisper"), "Instruction must contain prompt")
let inlineData = parts[1]["inline_data"] as! [String: Any]
assert((inlineData["mime_type"] as? String) == "audio/wav", "MIME mismatch")
assert((inlineData["data"] as? String) == geminiAudio.base64EncodedString(), "Base64 audio mismatch")
print("✔ GeminiSTTEngine request shape verified")

// Stub harness for Gemini transcribe()
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.requestCount += 1
        do {
            let (response, data) = try StubURLProtocol.requestHandler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

func makeGeminiStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

func geminiHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// Test 24: Gemini success parse incl. trim + single-step generateContent
@MainActor
func testGeminiSuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = GeminiSTTEngine(config: GeminiSTTConfig(apiKey: "AIza-test-key", model: "gemini-1.5-flash"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        let responseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {"text": "  halo dunia  "}
                ]
              }
            }
          ]
        }
        """
        return (geminiHTTPResponse(url: request.url!, status: 200), Data(responseJSON.utf8))
    }
    let res = try await engine.transcribe(audioData: geminiAudio, language: nil, prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(res.engineIdentifier == "gemini.gemini-1.5-flash", "Engine badge mismatch: \(res.engineIdentifier)")
    assert(StubURLProtocol.requestCount == 1, "Must make 1 direct generateContent call")
}

try await testGeminiSuccess()
print("✔ GeminiSTTEngine success parse verified")

// Test 25: Gemini error taxonomy (400/401/403/429/5xx/network/empty-audio)
@MainActor
func testGeminiErrors() async {
    let session = makeGeminiStubSession()
    let engine = GeminiSTTEngine(config: GeminiSTTConfig(apiKey: "AIza-test-key"), session: session)
    func checkStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"error\":{\"message\":\"server says no\"}}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: geminiAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class: \(msg)")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkStatus(400, matches: "Invalid")
    await checkStatus(401, matches: "API key")
    await checkStatus(403, matches: "API key")
    await checkStatus(429, matches: "quota")
    await checkStatus(500, matches: "unavailable")
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: geminiAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing key surfaces distinct auth error
    let keyless = GeminiSTTEngine(config: GeminiSTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: geminiAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-key auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing key must be 401")
            assert(msg.contains("API key"), "Missing key message mismatch")
        } else {
            assert(false, "Wrong error for missing key")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testGeminiErrors()
print("✔ GeminiSTTEngine error taxonomy verified")

// Test 26: Coordinator factory maps Gemini mode with isolated keys
@MainActor
func testGeminiFactory() async {
    let suite = "test.gemini.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.gemini.rawValue, forKey: "stt_provider_mode")
    defaults.set("AIza-gemini-secret", forKey: "gemini_api_key")
    defaults.set("gemini-1.5-flash", forKey: "gemini_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "gemini.gemini-1.5-flash", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory Gemini must be remote")
    let geminiBuilt = built as! GeminiSTTEngine
    assert(geminiBuilt.config.apiKey == "AIza-gemini-secret", "Factory must use isolated gemini key, not Groq key")
    // Default model fallback
    defaults.removeObject(forKey: "gemini_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! GeminiSTTEngine
    assert(defaulted.config.model == "gemini-1.5-flash", "Factory default model mismatch: \(defaulted.config.model)")
    // Existing modes unchanged
    defaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    let remote = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(remote.identifier == "remote.whisper-large-v3-turbo" || remote.identifier.hasPrefix("remote."), "Remote factory broke: \(remote.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testGeminiFactory()
print("✔ DictationCoordinator Gemini factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_GEMINI"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "GEMINI_API_KEY required for live check")
    let live = GeminiSTTEngine(config: GeminiSTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live Gemini check: [\(liveResult.text)]")
} else {
    print("○ Live Gemini check skipped (set KANSO_LIVE_GEMINI=1 + GEMINI_API_KEY to run)")
}
// Test 27: DeepgramSTTEngine request shape (Token auth, WAV bytes, query params)
let deepgramConfig = DeepgramSTTConfig(apiKey: "dg-test-key", model: "nova-3")
let deepgramEngine = DeepgramSTTEngine(config: deepgramConfig)
assert(deepgramEngine.identifier == "deepgram.nova-3", "Deepgram identifier mismatch: \(deepgramEngine.identifier)")
assert(deepgramEngine.isLocal == false, "Deepgram must be remote (isLocal == false)")
assert(DeepgramSTTConfig.defaultModel == "nova-3", "Default model mismatch")
let deepgramAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let dgRequest = try deepgramEngine.buildRequest(audioData: deepgramAudio, language: "id", prompt: "Kanso, Whisper")
assert(dgRequest.httpMethod == "POST", "Deepgram must be POST")
let dgURL = dgRequest.url!
assert(dgURL.host == "api.deepgram.com", "Deepgram host mismatch")
assert(dgURL.path == "/v1/listen", "Deepgram path mismatch")
let dgQuery = dgURL.query ?? ""
assert(dgQuery.contains("model=nova-3"), "Missing model param: \(dgQuery)")
assert(dgQuery.contains("language=id"), "Missing language param: \(dgQuery)")
assert(dgQuery.contains("smart_format=true"), "Missing smart_format param: \(dgQuery)")
assert(dgQuery.contains("keywords=Kanso") && dgQuery.contains("keywords=Whisper"), "Prompt must map to keywords params: \(dgQuery)")
assert(dgQuery.contains("topics=true"), "Prompt must enable topics bias: \(dgQuery)")
assert(dgQuery.contains("custom_topic_mode=extended"), "Prompt must set extended custom_topic_mode: \(dgQuery)")
assert(dgQuery.contains("custom_topic=Kanso") && dgQuery.contains("custom_topic=Whisper"), "Prompt must map to custom_topic terms: \(dgQuery)")
assert(dgRequest.value(forHTTPHeaderField: "Authorization") == "Token dg-test-key", "Deepgram must use Token auth scheme")
assert(dgRequest.value(forHTTPHeaderField: "Content-Type") == "audio/wav", "Deepgram Content-Type mismatch")
assert(dgRequest.httpBody == deepgramAudio, "Deepgram body must be raw WAV bytes")
// Unset language falls back to multi; empty prompt sends no keywords
let dgBare = try deepgramEngine.buildRequest(audioData: deepgramAudio, language: nil, prompt: nil)
assert((dgBare.url!.query ?? "").contains("language=multi"), "Unset language must fall back to multi")
assert(!((dgBare.url!.query ?? "").contains("keywords=")), "Empty prompt must omit keywords")
assert(!((dgBare.url!.query ?? "").contains("custom_topic")), "Empty prompt must omit custom_topic bias")
assert(!((dgBare.url!.query ?? "").contains("topics=")), "Empty prompt must omit topics bias")
let dgEn = try deepgramEngine.buildRequest(audioData: deepgramAudio, language: "en", prompt: nil)
assert((dgEn.url!.query ?? "").contains("language=en"), "English hint mismatch")
print("✔ DeepgramSTTEngine request shape verified")

// Test 28: Deepgram success parse incl. trim + duration fallback
@MainActor
func testDeepgramSuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = DeepgramSTTEngine(config: DeepgramSTTConfig(apiKey: "dg-test-key"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        assert(request.value(forHTTPHeaderField: "Authorization") == "Token dg-test-key", "Stub must see Token auth")
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"  halo dunia  \"}]}]},\"metadata\":{\"duration\":2.5}}".utf8))
    }
    let res = try await engine.transcribe(audioData: deepgramAudio, language: "id", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(abs(res.durationSeconds - 2.5) < 0.001, "Duration mismatch")
    assert(res.engineIdentifier == "deepgram.nova-3", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 1, "Must make exactly one listen call")
    // Duration fallback when server omits metadata
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"hello\"}]}]}}".utf8))
    }
    let res2 = try await engine.transcribe(audioData: deepgramAudio, language: "en", prompt: nil)
    assert(res2.text == "hello", "Fallback text mismatch")
    assert(res2.durationSeconds >= 0, "Fallback duration must be measured")
}

try await testDeepgramSuccess()
print("✔ DeepgramSTTEngine success parse verified")

// Test 29: Deepgram error taxonomy (400/401/403/429/5xx/network/empty-audio)
@MainActor
func testDeepgramErrors() async {
    let session = makeGeminiStubSession()
    let engine = DeepgramSTTEngine(config: DeepgramSTTConfig(apiKey: "dg-test-key"), session: session)
    func checkStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"err_msg\":\"server says no\"}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: deepgramAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkStatus(400, matches: "Invalid")
    await checkStatus(401, matches: "API key")
    await checkStatus(403, matches: "API key")
    await checkStatus(429, matches: "quota")
    await checkStatus(500, matches: "unavailable")
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: deepgramAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing key surfaces distinct auth error
    let keyless = DeepgramSTTEngine(config: DeepgramSTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: deepgramAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-key auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing key must be 401")
            assert(msg.contains("API key"), "Missing key message mismatch")
        } else {
            assert(false, "Wrong error for missing key")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testDeepgramErrors()
print("✔ DeepgramSTTEngine error taxonomy verified")

// Test 30: Coordinator factory maps Deepgram mode with isolated keys
@MainActor
func testDeepgramFactory() async {
    let suite = "test.deepgram.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.deepgram.rawValue, forKey: "stt_provider_mode")
    defaults.set("dg-secret", forKey: "deepgram_api_key")
    defaults.set("nova-3", forKey: "deepgram_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    defaults.set("AIza-gemini-secret", forKey: "gemini_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "deepgram.nova-3", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory Deepgram must be remote")
    let dgBuilt = built as! DeepgramSTTEngine
    assert(dgBuilt.config.apiKey == "dg-secret", "Factory must use isolated deepgram key")
    // Default model fallback
    defaults.removeObject(forKey: "deepgram_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! DeepgramSTTEngine
    assert(defaulted.config.model == "nova-3", "Factory default model mismatch")
    // Existing modes unchanged
    defaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    let remote = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(remote.identifier.hasPrefix("remote."), "Remote factory broke: \(remote.identifier)")
    defaults.set(STTProviderMode.gemini.rawValue, forKey: "stt_provider_mode")
    let gemini = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(gemini.identifier.hasPrefix("gemini."), "Gemini factory broke: \(gemini.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testDeepgramFactory()
print("✔ DictationCoordinator Deepgram factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_DEEPGRAM"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "DEEPGRAM_API_KEY required for live check")
    let live = DeepgramSTTEngine(config: DeepgramSTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live Deepgram check: [\(liveResult.text)]")
} else {
    print("○ Live Deepgram check skipped (set KANSO_LIVE_DEEPGRAM=1 + DEEPGRAM_API_KEY to run)")
}
// Test 31: CloudflareSTTEngine request shape (Bearer auth, base64 JSON body, account-scoped URL)
let cloudflareConfig = CloudflareSTTConfig(accountID: "test-acct-id", apiToken: "cf-test-token")
let cloudflareEngine = CloudflareSTTEngine(config: cloudflareConfig)
assert(cloudflareEngine.identifier == "cloudflare.whisper-large-v3-turbo", "Cloudflare identifier mismatch: \(cloudflareEngine.identifier)")
assert(cloudflareEngine.isLocal == false, "Cloudflare must be remote (isLocal == false)")
let cloudflareAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let cfRequest = try cloudflareEngine.buildRequest(audioData: cloudflareAudio, language: "id", prompt: "Kanso, Whisper")
assert(cfRequest.httpMethod == "POST", "Cloudflare must be POST")
let cfURL = cfRequest.url!
assert(cfURL.host == "api.cloudflare.com", "Cloudflare host mismatch")
assert(cfURL.path == "/client/v4/accounts/test-acct-id/ai/run/@cf/openai/whisper-large-v3-turbo", "Cloudflare path mismatch: \(cfURL.path)")
assert(cfRequest.value(forHTTPHeaderField: "Authorization") == "Bearer cf-test-token", "Cloudflare must use Bearer auth scheme")
assert(cfRequest.value(forHTTPHeaderField: "Content-Type") == "application/json", "Cloudflare Content-Type mismatch")
let cfBody = try JSONSerialization.jsonObject(with: cfRequest.httpBody!) as! [String: Any]
assert((cfBody["audio"] as? String) == cloudflareAudio.base64EncodedString(), "Audio must be base64 WAV bytes")
assert((cfBody["task"] as? String) == "transcribe", "Task must be transcribe")
assert((cfBody["language"] as? String) == "id", "Language hint mismatch")
assert((cfBody["initial_prompt"] as? String) == "Kanso, Whisper", "Prompt must map to initial_prompt")
// Unset language/prompt omits optional keys but keeps audio + task
let cfBare = try cloudflareEngine.buildRequest(audioData: cloudflareAudio, language: nil, prompt: nil)
let cfBareBody = try JSONSerialization.jsonObject(with: cfBare.httpBody!) as! [String: Any]
assert(cfBareBody["audio"] != nil, "Bare request must keep audio")
assert((cfBareBody["task"] as? String) == "transcribe", "Bare request must keep task")
assert(cfBareBody["language"] == nil, "Unset language must be omitted")
assert(cfBareBody["initial_prompt"] == nil, "Empty prompt must be omitted")
print("✔ CloudflareSTTEngine request shape verified")

// Test 32: Cloudflare success parse incl. trim + duration fallback
@MainActor
func testCloudflareSuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = CloudflareSTTEngine(config: CloudflareSTTConfig(accountID: "test-acct-id", apiToken: "cf-test-token"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer cf-test-token", "Stub must see Bearer auth")
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"result\":{\"text\":\"  halo dunia  \",\"duration\":2.5},\"success\":true}".utf8))
    }
    let res = try await engine.transcribe(audioData: cloudflareAudio, language: "id", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(abs(res.durationSeconds - 2.5) < 0.001, "Duration mismatch")
    assert(res.engineIdentifier == "cloudflare.whisper-large-v3-turbo", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 1, "Must make exactly one run call")
    // Duration fallback when server omits it
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"result\":{\"text\":\"hello\"},\"success\":true}".utf8))
    }
    let res2 = try await engine.transcribe(audioData: cloudflareAudio, language: "en", prompt: nil)
    assert(res2.text == "hello", "Fallback text mismatch")
    assert(res2.durationSeconds >= 0, "Fallback duration must be measured")
}

try await testCloudflareSuccess()
print("✔ CloudflareSTTEngine success parse verified")

// Test 33: Cloudflare error taxonomy (400/401/403/429/5xx/network/empty-audio)
@MainActor
func testCloudflareErrors() async {
    let session = makeGeminiStubSession()
    let engine = CloudflareSTTEngine(config: CloudflareSTTConfig(accountID: "test-acct-id", apiToken: "cf-test-token"), session: session)
    func checkStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"success\":false,\"errors\":[{\"message\":\"server says no\"}]}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: cloudflareAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkStatus(400, matches: "Invalid")
    await checkStatus(401, matches: "API token")
    await checkStatus(403, matches: "API token")
    await checkStatus(429, matches: "quota")
    await checkStatus(500, matches: "unavailable")
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: cloudflareAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing account/token pair surfaces distinct auth errors
    let keyless = CloudflareSTTEngine(config: CloudflareSTTConfig(accountID: nil, apiToken: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: cloudflareAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-credential auth error")
    } catch let err as STTError {
        if case .httpError(let code, _) = err {
            assert(code == 401, "Missing credentials must be 401")
        } else {
            assert(false, "Wrong error for missing credentials")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testCloudflareErrors()
print("✔ CloudflareSTTEngine error taxonomy verified")

// Test 34: Coordinator factory maps Cloudflare mode with isolated account+token pair
@MainActor
func testCloudflareFactory() async {
    let suite = "test.cloudflare.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.cloudflare.rawValue, forKey: "stt_provider_mode")
    defaults.set("cf-acct-123", forKey: "cloudflare_account_id")
    defaults.set("cf-token-secret", forKey: "cloudflare_api_token")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    defaults.set("AIza-gemini-secret", forKey: "gemini_api_key")
    defaults.set("dg-secret", forKey: "deepgram_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "cloudflare.whisper-large-v3-turbo", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory Cloudflare must be remote")
    let cfBuilt = built as! CloudflareSTTEngine
    assert(cfBuilt.config.accountID == "cf-acct-123", "Factory must use isolated cloudflare account ID")
    assert(cfBuilt.config.apiToken == "cf-token-secret", "Factory must use isolated cloudflare token")
    // Existing modes unchanged
    defaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    let remote = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(remote.identifier.hasPrefix("remote."), "Remote factory broke: \(remote.identifier)")
    defaults.set(STTProviderMode.gemini.rawValue, forKey: "stt_provider_mode")
    let gemini = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(gemini.identifier.hasPrefix("gemini."), "Gemini factory broke: \(gemini.identifier)")
    defaults.set(STTProviderMode.deepgram.rawValue, forKey: "stt_provider_mode")
    let dg = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(dg.identifier.hasPrefix("deepgram."), "Deepgram factory broke: \(dg.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testCloudflareFactory()
print("✔ DictationCoordinator Cloudflare factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_CLOUDFLARE"] == "1" {
    let liveAccount = ProcessInfo.processInfo.environment["CLOUDFLARE_ACCOUNT_ID"] ?? ""
    let liveToken = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"] ?? ""
    assert(!liveAccount.isEmpty && !liveToken.isEmpty, "CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN required for live check")
    let live = CloudflareSTTEngine(config: CloudflareSTTConfig(accountID: liveAccount, apiToken: liveToken))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live Cloudflare check: [\(liveResult.text)]")
} else {
    print("○ Live Cloudflare check skipped (set KANSO_LIVE_CLOUDFLARE=1 + CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_API_TOKEN to run)")
}
// Test 35: AssemblyAISTTEngine request shape (raw-key auth, upload + create + poll)
let assemblyaiConfig = AssemblyAISTTConfig(apiKey: "aai-test-key", model: "universal-2")
let assemblyaiEngine = AssemblyAISTTEngine(config: assemblyaiConfig)
assert(assemblyaiEngine.identifier == "assemblyai.universal-2", "AssemblyAI identifier mismatch: \(assemblyaiEngine.identifier)")
assert(assemblyaiEngine.isLocal == false, "AssemblyAI must be remote (isLocal == false)")
assert(AssemblyAISTTConfig.defaultModel == "universal-2", "Default model mismatch")
let assemblyaiAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let aaiUpload = try assemblyaiEngine.buildUploadRequest(audioData: assemblyaiAudio)
assert(aaiUpload.httpMethod == "POST", "Upload must be POST")
assert(aaiUpload.url?.host == "api.assemblyai.com", "Upload host mismatch")
assert(aaiUpload.url?.path == "/v1/upload", "Upload path mismatch: \(aaiUpload.url?.path ?? "")")
assert(aaiUpload.value(forHTTPHeaderField: "Authorization") == "aai-test-key", "Upload must use raw-key auth")
assert(aaiUpload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream", "Upload Content-Type mismatch")
assert(aaiUpload.httpBody == assemblyaiAudio, "Upload body must be raw WAV bytes")
let aaiCreate = try assemblyaiEngine.buildCreateRequest(audioURL: "https://example.com/audio.wav", language: "id", prompt: "Kanso, Whisper")
assert(aaiCreate.httpMethod == "POST", "Create must be POST")
assert(aaiCreate.url?.path == "/v1/transcript", "Create path mismatch")
assert(aaiCreate.value(forHTTPHeaderField: "Authorization") == "aai-test-key", "Create must use raw-key auth")
let aaiBody = try JSONSerialization.jsonObject(with: aaiCreate.httpBody!) as! [String: Any]
assert((aaiBody["audio_url"] as? String) == "https://example.com/audio.wav", "audio_url mismatch")
assert((aaiBody["speech_model"] as? String) == "universal-2", "Model mismatch in body")
assert((aaiBody["language_code"] as? String) == "id", "Language hint mismatch")
assert(((aaiBody["word_boost"] as? [String]) ?? []).contains("Kanso"), "Prompt must map to word_boost")
let aaiBare = try assemblyaiEngine.buildCreateRequest(audioURL: "https://example.com/audio.wav", language: nil, prompt: nil)
let aaiBareBody = try JSONSerialization.jsonObject(with: aaiBare.httpBody!) as! [String: Any]
assert(aaiBareBody["language_code"] == nil, "Unset language must be omitted")
assert(aaiBareBody["word_boost"] == nil, "Empty prompt must be omitted")
let aaiPoll = try assemblyaiEngine.buildPollRequest(transcriptID: "tr_123")
assert(aaiPoll.httpMethod == "GET", "Poll must be GET")
assert(aaiPoll.url?.path == "/v1/transcript/tr_123", "Poll path mismatch: \(aaiPoll.url?.path ?? "")")
assert(aaiPoll.value(forHTTPHeaderField: "Authorization") == "aai-test-key", "Poll must use raw-key auth")
print("✔ AssemblyAISTTEngine request shape verified")

// Test 36: AssemblyAI success parse incl. trim + duration fallback + poll timeout
@MainActor
func testAssemblyAISuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: "aai-test-key"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/v1/upload" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"upload_url\":\"https://example.com/audio.wav\"}".utf8))
        } else if path == "/v1/transcript" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"processing\"}".utf8))
        } else {
            assert(path == "/v1/transcript/tr_123", "Poll path mismatch: \(path)")
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"completed\",\"text\":\"  halo dunia  \",\"audio_duration\":2.5}".utf8))
        }
    }
    let res = try await engine.transcribe(audioData: assemblyaiAudio, language: "id", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(abs(res.durationSeconds - 2.5) < 0.001, "Duration mismatch")
    assert(res.engineIdentifier == "assemblyai.universal-2", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 3, "Must make upload + create + poll calls")
    // Duration fallback when server omits audio_duration
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/v1/upload" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"upload_url\":\"https://example.com/audio.wav\"}".utf8))
        } else if path == "/v1/transcript" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"processing\"}".utf8))
        } else {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"completed\",\"text\":\"hello\"}".utf8))
        }
    }
    let res2 = try await engine.transcribe(audioData: assemblyaiAudio, language: "en", prompt: nil)
    assert(res2.text == "hello", "Fallback text mismatch")
    assert(res2.durationSeconds >= 0, "Fallback duration must be measured")
    // Poll timeout surfaces networkError
    let slow = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: "aai-test-key", pollInterval: 0, maxPollAttempts: 1), session: session)
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/v1/upload" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"upload_url\":\"https://example.com/audio.wav\"}".utf8))
        } else if path == "/v1/transcript" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"processing\"}".utf8))
        } else {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"processing\"}".utf8))
        }
    }
    do {
        _ = try await slow.transcribe(audioData: assemblyaiAudio, language: nil, prompt: nil)
        assert(false, "Expected timeout networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError on poll timeout")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

try await testAssemblyAISuccess()
print("✔ AssemblyAISTTEngine success parse verified")

// Test 37: AssemblyAI error taxonomy (400/401/403/429/5xx/poll-error/network/empty-audio)
@MainActor
func testAssemblyAIErrors() async {
    let session = makeGeminiStubSession()
    let engine = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: "aai-test-key"), session: session)
    let uploadOK = Data("{\"upload_url\":\"https://example.com/audio.wav\"}".utf8)
    let createOK = Data("{\"id\":\"tr_123\",\"status\":\"processing\"}".utf8)
    func checkCreateStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            if request.url!.path == "/v1/upload" { return (geminiHTTPResponse(url: request.url!, status: 200), uploadOK) }
            return (geminiHTTPResponse(url: request.url!, status: status), Data("{\"error\":\"server says no\"}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: assemblyaiAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkCreateStatus(400, matches: "Invalid")
    await checkCreateStatus(401, matches: "API key")
    await checkCreateStatus(403, matches: "API key")
    await checkCreateStatus(429, matches: "quota")
    await checkCreateStatus(500, matches: "unavailable")
    // Poll error status surfaces httpError
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/v1/upload" { return (geminiHTTPResponse(url: request.url!, status: 200), uploadOK) }
        if path == "/v1/transcript" { return (geminiHTTPResponse(url: request.url!, status: 200), createOK) }
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"tr_123\",\"status\":\"error\",\"error\":\"boom\"}".utf8))
    }
    do {
        _ = try await engine.transcribe(audioData: assemblyaiAudio, language: nil, prompt: nil)
        assert(false, "Expected poll-error httpError")
    } catch let err as STTError {
        if case .httpError = err {
        } else {
            assert(false, "Expected httpError for error status")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: assemblyaiAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing key surfaces distinct auth error
    let keyless = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: assemblyaiAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-key auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing key must be 401")
            assert(msg.contains("API key"), "Missing key message mismatch")
        } else {
            assert(false, "Wrong error for missing key")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testAssemblyAIErrors()
print("✔ AssemblyAISTTEngine error taxonomy verified")

// Test 38: Coordinator factory maps AssemblyAI mode with isolated keys
@MainActor
func testAssemblyAIFactory() async {
    let suite = "test.assemblyai.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.assemblyai.rawValue, forKey: "stt_provider_mode")
    defaults.set("aai-secret", forKey: "assemblyai_api_key")
    defaults.set("universal-2", forKey: "assemblyai_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "assemblyai.universal-2", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory AssemblyAI must be remote")
    let aaiBuilt = built as! AssemblyAISTTEngine
    assert(aaiBuilt.config.apiKey == "aai-secret", "Factory must use isolated assemblyai key")
    defaults.removeObject(forKey: "assemblyai_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! AssemblyAISTTEngine
    assert(defaulted.config.model == "universal-2", "Factory default model mismatch")
    defaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    let remote = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(remote.identifier.hasPrefix("remote."), "Remote factory broke: \(remote.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testAssemblyAIFactory()
print("✔ DictationCoordinator AssemblyAI factory mapping verified")
// Code-review fix: AssemblyAI sends the key raw (primary: assemblyai.com/docs/api-reference
// shows `Authorization: <YOUR_API_KEY>`; Bearer is only optionally accepted).
let aaiSpaced = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: "  aai-test-key  "))
let aaiSpacedUpload = try aaiSpaced.buildUploadRequest(audioData: assemblyaiAudio)
assert(aaiSpacedUpload.value(forHTTPHeaderField: "Authorization") == "aai-test-key", "AssemblyAI must send trimmed raw key, no Bearer prefix")
print("✔ AssemblyAI raw-key auth verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_ASSEMBLYAI"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "ASSEMBLYAI_API_KEY required for live check")
    let live = AssemblyAISTTEngine(config: AssemblyAISTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live AssemblyAI check: [\(liveResult.text)]")
} else {
    print("○ Live AssemblyAI check skipped (set KANSO_LIVE_ASSEMBLYAI=1 + ASSEMBLYAI_API_KEY to run)")
}

// Test 39: SpeechmaticsSTTEngine request shape (Bearer auth, multipart config + WAV)
let speechmaticsConfig = SpeechmaticsSTTConfig(apiKey: "sm-test-key", model: "enhanced")
let speechmaticsEngine = SpeechmaticsSTTEngine(config: speechmaticsConfig)
assert(speechmaticsEngine.identifier == "speechmatics.enhanced", "Speechmatics identifier mismatch: \(speechmaticsEngine.identifier)")
assert(speechmaticsEngine.isLocal == false, "Speechmatics must be remote (isLocal == false)")
assert(SpeechmaticsSTTConfig.defaultModel == "enhanced", "Default model mismatch")
let speechmaticsAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let smCreate = try speechmaticsEngine.buildCreateRequest(audioData: speechmaticsAudio, language: "id", prompt: "Kanso, Whisper", boundary: "test-boundary")
assert(smCreate.httpMethod == "POST", "Create must be POST")
assert(smCreate.url?.host == "asr.api.speechmatics.com", "Create host mismatch")
assert(smCreate.url?.path == "/v2/jobs", "Create path mismatch: \(smCreate.url?.path ?? "")")
assert(smCreate.value(forHTTPHeaderField: "Authorization") == "Bearer sm-test-key", "Create must use Bearer auth")
assert(smCreate.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary", "Content-Type mismatch")
guard let smBodyData = smCreate.httpBody, let smBody = String(data: smBodyData, encoding: .utf8) else {
    fatalError("Failed to decode Speechmatics HTTP body")
}
assert(smBody.contains("name=\"data_file\"; filename=\"audio.wav\""), "Missing data_file part")
assert(smBody.contains("name=\"config\""), "Missing config part")
assert(smBody.contains("\"operating_point\":\"enhanced\"") || smBody.contains("\"operating_point\": \"enhanced\""), "Config must carry operating_point")
assert(smBody.contains("\"language\":\"id\"") || smBody.contains("\"language\": \"id\""), "Config must carry language")
assert(smBody.contains("Kanso"), "Prompt must map to additional_vocab")
let smBare = try speechmaticsEngine.buildCreateRequest(audioData: speechmaticsAudio, language: nil, prompt: nil, boundary: "test-boundary")
let smBareStr = String(data: smBare.httpBody!, encoding: .utf8)!
assert(!smBareStr.contains("\"language\""), "Unset language must be omitted")
assert(!smBareStr.contains("additional_vocab"), "Empty prompt must be omitted")
let smPoll = try speechmaticsEngine.buildPollRequest(jobID: "job1")
assert(smPoll.httpMethod == "GET", "Poll must be GET")
assert(smPoll.url?.path == "/v2/jobs/job1", "Poll path mismatch: \(smPoll.url?.path ?? "")")
assert(smPoll.value(forHTTPHeaderField: "Authorization") == "Bearer sm-test-key", "Poll must use Bearer auth")
let smTranscript = try speechmaticsEngine.buildTranscriptRequest(jobID: "job1")
assert(smTranscript.httpMethod == "GET", "Transcript fetch must be GET")
assert(smTranscript.url?.path == "/v2/jobs/job1/transcript", "Transcript path mismatch: \(smTranscript.url?.path ?? "")")
print("✔ SpeechmaticsSTTEngine request shape verified")

// Test 40: Speechmatics success parse incl. trim + duration fallback + poll timeout
@MainActor
func testSpeechmaticsSuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = SpeechmaticsSTTEngine(config: SpeechmaticsSTTConfig(apiKey: "sm-test-key"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/v2/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        } else if path == "/v2/jobs/job1" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"job\":{\"id\":\"job1\",\"status\":\"done\"}}".utf8))
        } else {
            assert(path == "/v2/jobs/job1/transcript", "Transcript path mismatch: \(path)")
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"content\":\"  halo dunia  \"}".utf8))
        }
    }
    let res = try await engine.transcribe(audioData: speechmaticsAudio, language: "id", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(res.durationSeconds >= 0, "Fallback duration must be measured")
    assert(res.engineIdentifier == "speechmatics.enhanced", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 3, "Must make create + poll + transcript calls")
    // Poll timeout surfaces networkError
    let slow = SpeechmaticsSTTEngine(config: SpeechmaticsSTTConfig(apiKey: "sm-test-key", pollInterval: 0, maxPollAttempts: 1), session: session)
    StubURLProtocol.requestHandler = { request in
        if request.url!.path == "/v2/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        }
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"job\":{\"id\":\"job1\",\"status\":\"in_progress\"}}".utf8))
    }
    do {
        _ = try await slow.transcribe(audioData: speechmaticsAudio, language: nil, prompt: nil)
        assert(false, "Expected timeout networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError on poll timeout")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

try await testSpeechmaticsSuccess()
print("✔ SpeechmaticsSTTEngine success parse verified")

// Test 41: Speechmatics error taxonomy (400/401/403/429/5xx/rejected/network/empty-audio)
@MainActor
func testSpeechmaticsErrors() async {
    let session = makeGeminiStubSession()
    let engine = SpeechmaticsSTTEngine(config: SpeechmaticsSTTConfig(apiKey: "sm-test-key"), session: session)
    func checkCreateStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"error\":\"server says no\"}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: speechmaticsAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkCreateStatus(400, matches: "Invalid")
    await checkCreateStatus(401, matches: "API key")
    await checkCreateStatus(403, matches: "API key")
    await checkCreateStatus(429, matches: "quota")
    await checkCreateStatus(500, matches: "unavailable")
    // Rejected job surfaces httpError
    StubURLProtocol.requestHandler = { request in
        if request.url!.path == "/v2/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        }
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"job\":{\"id\":\"job1\",\"status\":\"rejected\"}}".utf8))
    }
    do {
        _ = try await engine.transcribe(audioData: speechmaticsAudio, language: nil, prompt: nil)
        assert(false, "Expected rejected-job httpError")
    } catch let err as STTError {
        if case .httpError = err {
        } else {
            assert(false, "Expected httpError for rejected job")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: speechmaticsAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing key surfaces distinct auth error
    let keyless = SpeechmaticsSTTEngine(config: SpeechmaticsSTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: speechmaticsAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-key auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing key must be 401")
            assert(msg.contains("API key"), "Missing key message mismatch")
        } else {
            assert(false, "Wrong error for missing key")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testSpeechmaticsErrors()
print("✔ SpeechmaticsSTTEngine error taxonomy verified")

// Test 42: Coordinator factory maps Speechmatics mode with isolated keys
@MainActor
func testSpeechmaticsFactory() async {
    let suite = "test.speechmatics.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.speechmatics.rawValue, forKey: "stt_provider_mode")
    defaults.set("sm-secret", forKey: "speechmatics_api_key")
    defaults.set("enhanced", forKey: "speechmatics_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "speechmatics.enhanced", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory Speechmatics must be remote")
    let smBuilt = built as! SpeechmaticsSTTEngine
    assert(smBuilt.config.apiKey == "sm-secret", "Factory must use isolated speechmatics key")
    defaults.removeObject(forKey: "speechmatics_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! SpeechmaticsSTTEngine
    assert(defaulted.config.model == "enhanced", "Factory default model mismatch")
    defaults.set(STTProviderMode.assemblyai.rawValue, forKey: "stt_provider_mode")
    let aai = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(aai.identifier.hasPrefix("assemblyai."), "AssemblyAI factory broke: \(aai.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testSpeechmaticsFactory()
print("✔ DictationCoordinator Speechmatics factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_SPEECHMATICS"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["SPEECHMATICS_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "SPEECHMATICS_API_KEY required for live check")
    let live = SpeechmaticsSTTEngine(config: SpeechmaticsSTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live Speechmatics check: [\(liveResult.text)]")
} else {
    print("○ Live Speechmatics check skipped (set KANSO_LIVE_SPEECHMATICS=1 + SPEECHMATICS_API_KEY to run)")
}

// Test 43: RevAISTTEngine request shape (Bearer access token, multipart media + options)
let revaiConfig = RevAISTTConfig(apiKey: "rev-test-token", model: "reverb")
let revaiEngine = RevAISTTEngine(config: revaiConfig)
assert(revaiEngine.identifier == "revai.reverb", "Rev.ai identifier mismatch: \(revaiEngine.identifier)")
assert(revaiEngine.isLocal == false, "Rev.ai must be remote (isLocal == false)")
assert(RevAISTTConfig.defaultModel == "reverb", "Default model mismatch")
let revaiAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let revSubmit = try revaiEngine.buildSubmitRequest(audioData: revaiAudio, language: "en", prompt: "Kanso, Whisper", boundary: "test-boundary")
assert(revSubmit.httpMethod == "POST", "Submit must be POST")
assert(revSubmit.url?.host == "api.rev.ai", "Submit host mismatch")
assert(revSubmit.url?.path == "/speechtotext/v1/jobs", "Submit path mismatch: \(revSubmit.url?.path ?? "")")
assert(revSubmit.value(forHTTPHeaderField: "Authorization") == "Bearer rev-test-token", "Submit must use Bearer access token")
assert(revSubmit.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary", "Content-Type mismatch")
guard let revBodyData = revSubmit.httpBody, let revBody = String(data: revBodyData, encoding: .utf8) else {
    fatalError("Failed to decode Rev.ai HTTP body")
}
assert(revBody.contains("name=\"media\"; filename=\"audio.wav\""), "Missing media part")
assert(revBody.contains("name=\"options\""), "Missing options part")
assert(revBody.contains("reverb"), "Options must carry model")
assert(revBody.contains("\"language\":\"en\"") || revBody.contains("\"language\": \"en\""), "Options must carry language")
assert(revBody.contains("Kanso"), "Prompt must map to custom_vocabularies")
let revBare = try revaiEngine.buildSubmitRequest(audioData: revaiAudio, language: nil, prompt: nil, boundary: "test-boundary")
let revBareStr = String(data: revBare.httpBody!, encoding: .utf8)!
assert(!revBareStr.contains("\"language\""), "Unset language must be omitted")
assert(!revBareStr.contains("custom_vocabularies"), "Empty prompt must be omitted")
let revPoll = try revaiEngine.buildPollRequest(jobID: "job1")
assert(revPoll.httpMethod == "GET", "Poll must be GET")
assert(revPoll.url?.path == "/speechtotext/v1/jobs/job1", "Poll path mismatch: \(revPoll.url?.path ?? "")")
assert(revPoll.value(forHTTPHeaderField: "Authorization") == "Bearer rev-test-token", "Poll must use Bearer access token")
let revTranscript = try revaiEngine.buildTranscriptRequest(jobID: "job1")
assert(revTranscript.httpMethod == "GET", "Transcript fetch must be GET")
assert(revTranscript.url?.path == "/speechtotext/v1/jobs/job1/transcript", "Transcript path mismatch: \(revTranscript.url?.path ?? "")")
print("✔ RevAISTTEngine request shape verified")

// Test 44: Rev.ai success parse incl. trim + duration fallback + poll timeout
@MainActor
func testRevAISuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = RevAISTTEngine(config: RevAISTTConfig(apiKey: "rev-test-token"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        let path = request.url!.path
        if path == "/speechtotext/v1/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        } else if path == "/speechtotext/v1/jobs/job1" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\",\"status\":\"transcribed\"}".utf8))
        } else {
            assert(path == "/speechtotext/v1/jobs/job1/transcript", "Transcript path mismatch: \(path)")
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("  halo dunia  ".utf8))
        }
    }
    let res = try await engine.transcribe(audioData: revaiAudio, language: "en", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(res.durationSeconds >= 0, "Fallback duration must be measured")
    assert(res.engineIdentifier == "revai.reverb", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 3, "Must make submit + poll + transcript calls")
    // Poll timeout surfaces networkError
    let slow = RevAISTTEngine(config: RevAISTTConfig(apiKey: "rev-test-token", pollInterval: 0, maxPollAttempts: 1), session: session)
    StubURLProtocol.requestHandler = { request in
        if request.url!.path == "/speechtotext/v1/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        }
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\",\"status\":\"in_progress\"}".utf8))
    }
    do {
        _ = try await slow.transcribe(audioData: revaiAudio, language: nil, prompt: nil)
        assert(false, "Expected timeout networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError on poll timeout")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

try await testRevAISuccess()
print("✔ RevAISTTEngine success parse verified")

// Test 45: Rev.ai error taxonomy (400/401/403/429/5xx/failed/network/empty-audio)
@MainActor
func testRevAIErrors() async {
    let session = makeGeminiStubSession()
    let engine = RevAISTTEngine(config: RevAISTTConfig(apiKey: "rev-test-token"), session: session)
    func checkSubmitStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"title\":\"server says no\"}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: revaiAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkSubmitStatus(400, matches: "Invalid")
    await checkSubmitStatus(401, matches: "access token")
    await checkSubmitStatus(403, matches: "access token")
    await checkSubmitStatus(429, matches: "quota")
    await checkSubmitStatus(500, matches: "unavailable")
    // Failed job surfaces httpError
    StubURLProtocol.requestHandler = { request in
        if request.url!.path == "/speechtotext/v1/jobs" {
            return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\"}".utf8))
        }
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"id\":\"job1\",\"status\":\"failed\",\"failure_detail\":\"bad audio\"}".utf8))
    }
    do {
        _ = try await engine.transcribe(audioData: revaiAudio, language: nil, prompt: nil)
        assert(false, "Expected failed-job httpError")
    } catch let err as STTError {
        if case .httpError = err {
        } else {
            assert(false, "Expected httpError for failed job")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: revaiAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing token surfaces distinct auth error
    let keyless = RevAISTTEngine(config: RevAISTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: revaiAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-token auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing token must be 401")
            assert(msg.contains("access token"), "Missing token message mismatch")
        } else {
            assert(false, "Wrong error for missing token")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testRevAIErrors()
print("✔ RevAISTTEngine error taxonomy verified")

// Test 46: Coordinator factory maps Rev.ai mode with isolated keys
@MainActor
func testRevAIFactory() async {
    let suite = "test.revai.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.revai.rawValue, forKey: "stt_provider_mode")
    defaults.set("rev-secret", forKey: "revai_api_key")
    defaults.set("reverb", forKey: "revai_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "revai.reverb", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory Rev.ai must be remote")
    let revBuilt = built as! RevAISTTEngine
    assert(revBuilt.config.apiKey == "rev-secret", "Factory must use isolated revai key")
    defaults.removeObject(forKey: "revai_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! RevAISTTEngine
    assert(defaulted.config.model == "reverb", "Factory default model mismatch")
    defaults.set(STTProviderMode.speechmatics.rawValue, forKey: "stt_provider_mode")
    let sm = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(sm.identifier.hasPrefix("speechmatics."), "Speechmatics factory broke: \(sm.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testRevAIFactory()
print("✔ DictationCoordinator Rev.ai factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_REVAI"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["REVAI_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "REVAI_API_KEY required for live check")
    let live = RevAISTTEngine(config: RevAISTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live Rev.ai check: [\(liveResult.text)]")
} else {
    print("○ Live Rev.ai check skipped (set KANSO_LIVE_REVAI=1 + REVAI_API_KEY to run)")
}

// Test 47: ElevenLabsSTTEngine request shape (xi-api-key auth, multipart file + model_id)
let elevenlabsConfig = ElevenLabsSTTConfig(apiKey: "xi-test-key", model: "scribe_v2")
let elevenlabsEngine = ElevenLabsSTTEngine(config: elevenlabsConfig)
assert(elevenlabsEngine.identifier == "elevenlabs.scribe-v2", "ElevenLabs identifier mismatch: \(elevenlabsEngine.identifier)")
assert(elevenlabsEngine.isLocal == false, "ElevenLabs must be remote (isLocal == false)")
assert(ElevenLabsSTTConfig.defaultModel == "scribe_v2", "Default model mismatch")
let elevenlabsAudio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
let elRequest = try elevenlabsEngine.buildRequest(audioData: elevenlabsAudio, language: "id", boundary: "test-boundary")
assert(elRequest.httpMethod == "POST", "ElevenLabs must be POST")
assert(elRequest.url?.host == "api.elevenlabs.io", "ElevenLabs host mismatch")
assert(elRequest.url?.path == "/v1/speech-to-text", "ElevenLabs path mismatch: \(elRequest.url?.path ?? "")")
assert(elRequest.value(forHTTPHeaderField: "xi-api-key") == "xi-test-key", "ElevenLabs must use xi-api-key header")
assert(elRequest.value(forHTTPHeaderField: "Authorization") == nil, "ElevenLabs must NOT use Bearer auth")
assert(elRequest.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary", "Content-Type mismatch")
guard let elBodyData = elRequest.httpBody, let elBody = String(data: elBodyData, encoding: .utf8) else {
    fatalError("Failed to decode ElevenLabs HTTP body")
}
assert(elBody.contains("name=\"model_id\"\r\n\r\nscribe_v2"), "Missing model_id in body")
assert(elBody.contains("name=\"language_code\"\r\n\r\nid"), "Missing language_code in body")
assert(elBody.contains("name=\"file\"; filename=\"audio.wav\""), "Missing file part in body")
let elBare = try elevenlabsEngine.buildRequest(audioData: elevenlabsAudio, language: nil, boundary: "test-boundary")
let elBareStr = String(data: elBare.httpBody!, encoding: .utf8)!
assert(!elBareStr.contains("language_code"), "Unset language must be omitted")
assert(elBareStr.contains("name=\"model_id\""), "Bare request must keep model_id")
print("✔ ElevenLabsSTTEngine request shape verified")

// Test 48: ElevenLabs success parse incl. trim + duration fallback
@MainActor
func testElevenLabsSuccess() async throws {
    let session = makeGeminiStubSession()
    let engine = ElevenLabsSTTEngine(config: ElevenLabsSTTConfig(apiKey: "xi-test-key"), session: session)
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        assert(request.value(forHTTPHeaderField: "xi-api-key") == "xi-test-key", "Stub must see xi-api-key auth")
        assert(request.value(forHTTPHeaderField: "Authorization") == nil, "Stub must see no Bearer auth")
        return (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"text\":\"  halo dunia  \",\"language_code\":\"id\"}".utf8))
    }
    let res = try await engine.transcribe(audioData: elevenlabsAudio, language: "id", prompt: nil)
    assert(res.text == "halo dunia", "Trim mismatch: [\(res.text)]")
    assert(res.durationSeconds >= 0, "Fallback duration must be measured")
    assert(res.engineIdentifier == "elevenlabs.scribe-v2", "Engine badge mismatch")
    assert(StubURLProtocol.requestCount == 1, "Must make exactly one speech-to-text call")
    // Server duration honored when present
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data("{\"text\":\"hello\",\"duration\":1.5}".utf8))
    }
    let res2 = try await engine.transcribe(audioData: elevenlabsAudio, language: "en", prompt: nil)
    assert(res2.text == "hello", "Fallback text mismatch")
    assert(abs(res2.durationSeconds - 1.5) < 0.001, "Duration mismatch")
}

try await testElevenLabsSuccess()
print("✔ ElevenLabsSTTEngine success parse verified")

// Test 49: ElevenLabs error taxonomy (400/401/403/429/5xx/network/empty-audio)
@MainActor
func testElevenLabsErrors() async {
    let session = makeGeminiStubSession()
    let engine = ElevenLabsSTTEngine(config: ElevenLabsSTTConfig(apiKey: "xi-test-key"), session: session)
    func checkStatus(_ status: Int, matches: String) async {
        StubURLProtocol.requestHandler = { request in
            (geminiHTTPResponse(url: request.url!, status: status), Data("{\"detail\":{\"message\":\"server says no\"}}".utf8))
        }
        do {
            _ = try await engine.transcribe(audioData: elevenlabsAudio, language: nil, prompt: nil)
            assert(false, "Expected httpError")
        } catch let err as STTError {
            if case .httpError(let code, let msg) = err {
                assert(code == status, "Status mismatch")
                assert(msg.lowercased().contains(matches.lowercased()), "Error message must name failure class")
            } else {
                assert(false, "Wrong STTError case")
            }
        } catch {
            assert(false, "Unexpected error type")
        }
    }
    await checkStatus(400, matches: "Invalid")
    await checkStatus(401, matches: "API key")
    await checkStatus(403, matches: "API key")
    await checkStatus(429, matches: "quota")
    await checkStatus(500, matches: "unavailable")
    // Network failure
    StubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    do {
        _ = try await engine.transcribe(audioData: elevenlabsAudio, language: nil, prompt: nil)
        assert(false, "Expected networkError")
    } catch let err as STTError {
        if case .networkError = err {
        } else {
            assert(false, "Expected networkError case")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
    // Empty audio makes no network call
    StubURLProtocol.requestCount = 0
    StubURLProtocol.requestHandler = { request in
        (geminiHTTPResponse(url: request.url!, status: 200), Data())
    }
    do {
        _ = try await engine.transcribe(audioData: Data(), language: nil, prompt: nil)
        assert(false, "Expected emptyAudioData")
    } catch let err as STTError {
        assert(err == .emptyAudioData, "Expected emptyAudioData")
    } catch {
        assert(false, "Unexpected error type")
    }
    assert(StubURLProtocol.requestCount == 0, "Empty audio must make no network call")
    // Missing key surfaces distinct auth error
    let keyless = ElevenLabsSTTEngine(config: ElevenLabsSTTConfig(apiKey: nil), session: session)
    do {
        _ = try await keyless.transcribe(audioData: elevenlabsAudio, language: nil, prompt: nil)
        assert(false, "Expected missing-key auth error")
    } catch let err as STTError {
        if case .httpError(let code, let msg) = err {
            assert(code == 401, "Missing key must be 401")
            assert(msg.contains("API key"), "Missing key message mismatch")
        } else {
            assert(false, "Wrong error for missing key")
        }
    } catch {
        assert(false, "Unexpected error type")
    }
}

await testElevenLabsErrors()
print("✔ ElevenLabsSTTEngine error taxonomy verified")

// Test 50: Coordinator factory maps ElevenLabs mode with isolated keys
@MainActor
func testElevenLabsFactory() async {
    let suite = "test.elevenlabs.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.elevenlabs.rawValue, forKey: "stt_provider_mode")
    defaults.set("xi-secret", forKey: "elevenlabs_api_key")
    defaults.set("scribe_v2", forKey: "elevenlabs_model")
    defaults.set("gsk-groq-secret", forKey: "stt_api_key")
    defaults.set("rev-secret", forKey: "revai_api_key")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(built.identifier == "elevenlabs.scribe-v2", "Factory identifier mismatch: \(built.identifier)")
    assert(built.isLocal == false, "Factory ElevenLabs must be remote")
    let elBuilt = built as! ElevenLabsSTTEngine
    assert(elBuilt.config.apiKey == "xi-secret", "Factory must use isolated elevenlabs key")
    // Default model fallback
    defaults.removeObject(forKey: "elevenlabs_model")
    let defaulted = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! ElevenLabsSTTEngine
    assert(defaulted.config.model == "scribe_v2", "Factory default model mismatch")
    // Existing modes unchanged
    defaults.set(STTProviderMode.remote.rawValue, forKey: "stt_provider_mode")
    let remote = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(remote.identifier.hasPrefix("remote."), "Remote factory broke: \(remote.identifier)")
    defaults.set(STTProviderMode.revai.rawValue, forKey: "stt_provider_mode")
    let rev = DictationCoordinator.makeEngineFromPreferences(defaults: defaults)
    assert(rev.identifier.hasPrefix("revai."), "Rev.ai factory broke: \(rev.identifier)")
    defaults.removePersistentDomain(forName: suite)
}

await testElevenLabsFactory()
print("✔ DictationCoordinator ElevenLabs factory mapping verified")

if ProcessInfo.processInfo.environment["KANSO_LIVE_ELEVENLABS"] == "1" {
    let liveKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
    assert(!liveKey.isEmpty, "ELEVENLABS_API_KEY required for live check")
    let live = ElevenLabsSTTEngine(config: ElevenLabsSTTConfig(apiKey: liveKey))
    let clip = WAVWriter.createWAVData(from: Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000, channels: 1)
    let liveResult = try await live.transcribe(audioData: clip, language: "en", prompt: nil)
    print("✔ Live ElevenLabs check: [\(liveResult.text)]")
} else {
    print("○ Live ElevenLabs check skipped (set KANSO_LIVE_ELEVENLABS=1 + ELEVENLABS_API_KEY to run)")
}
// Code-review fix: factory passes trimmed key/model strings into configs.
@MainActor
func testTrimmedFactoryCredentials() async {
    let suite = "test.trimmed.factory.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(STTProviderMode.deepgram.rawValue, forKey: "stt_provider_mode")
    defaults.set("  dg-spaced-key  ", forKey: "deepgram_api_key")
    defaults.set("  nova-3  ", forKey: "deepgram_model")
    let built = DictationCoordinator.makeEngineFromPreferences(defaults: defaults) as! DeepgramSTTEngine
    assert(built.config.apiKey == "dg-spaced-key", "Factory must pass trimmed key, got [\(built.config.apiKey ?? "nil")]")
    assert(built.config.model == "nova-3", "Factory must pass trimmed model, got [\(built.config.model)]")
    defaults.removePersistentDomain(forName: suite)
}

await testTrimmedFactoryCredentials()
print("✔ DictationCoordinator trimmed credentials verified")
print("All KansoCore tests passed successfully! 🎉")
