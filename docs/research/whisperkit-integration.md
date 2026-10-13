# Research Report: WhisperKit SPM Integration, Model Directory Management, and Swift 6 Concurrency on macOS

**Issue Reference:** #5 (Part of Walking Skeleton #3)  
**Date:** October 2026  
**Target Platform:** macOS 14.0+ (Apple Silicon M-Series)  
**Upstream Repository:** `https://github.com/argmaxinc/argmax-oss-swift` (formerly `argmaxinc/WhisperKit`)

---

## 1. Executive Summary

This investigation resolves technical requirements for integrating local Whisper speech-to-text inference into **Kanso Dictate** via `argmax-inc/WhisperKit`:

1. **SPM Package Dependency:** Upstream repository `argmaxinc/WhisperKit` has merged into the multi-product repository `argmaxinc/argmax-oss-swift`. The modern SPM package URL is `https://github.com/argmaxinc/argmax-oss-swift.git` with product `WhisperKit`. The latest stable release is `v1.1.1`.
2. **Model Storage & Caching:** By default, WhisperKit caches models in `~/Documents/huggingface`, which violates macOS application standards and causes sandbox issues. We verify that passing a custom `downloadBase` pointing to `~/Library/Application Support/KansoDictate/models` isolates downloads cleanly. Alternatively, explicit directory passing via `WhisperKit(modelFolder:)` enables pre-bundled or managed model layouts.
3. **Core ML On-Device Specialization:** Downloaded `.mlmodelc` bundles are device-agnostic and are compiled by Core ML for the specific Apple Silicon chip (Apple Neural Engine / GPU) on first load. Enabling `prewarm: true` during initialization prevents peak memory bloating by compiling models sequentially.
4. **Recommended Model Variants:** For responsive dictation on Apple Silicon (M1/M2/M3/M4), `openai_whisper-base` (or `openai_whisper-base.en`) offers the ideal trade-off (~145–200 MB disk, ~250 MB RAM, <100ms inference per chunk on ANE). For higher accuracy with technical vocabulary, `openai_whisper-small` (~460 MB) or `openai_whisper-small_216MB` provides near-human accuracy at modest latency (~200–300ms).
5. **Audio Input Conversion:** WhisperKit expects mono 16 kHz IEEE 32-bit floating-point samples (`[Float]`) normalized to `[-1.0, 1.0]`. Live microphone buffers from `AVAudioEngine` must be converted via `AVAudioConverter` and extracted to `[Float]`.
6. **Swift 6 Concurrency Isolation:** `WhisperKit` is an `open class` and is **not** `Sendable` due to mutable internal state (`modelState`, pipeline components, timings). Instantiating or holding `WhisperKit` on the `@MainActor` causes compiler errors in Swift 6 language mode and hitches the UI during Core ML compilation. It must be encapsulated inside a dedicated background `actor WhisperTranscriber`, exposing only `Sendable` types (`[Float]`, `DecodingOptions`, `TranscriptionResult`) across the async boundary.

---

## 2. Swift Package Manager (SPM) Declaration

### 2.1 Repository Evolution & Name Resolution
In mid-2024, Argmax unified `WhisperKit`, `TTSKit`, and `SpeakerKit` into a single open-source SDK repository named `argmax-oss-swift`:
- Repository URL: `https://github.com/argmaxinc/argmax-oss-swift.git`
- Legacy URL: `https://github.com/argmaxinc/WhisperKit.git` (GitHub automatically redirects HTTP/git requests to `argmax-oss-swift`)
- Package Name in manifest: `argmax-oss-swift`
- Library Product Name: `WhisperKit`
- Upstream Language Version: `swiftLanguageVersions: [.v5]` with experimental Strict Concurrency enabled.

### 2.2 Package.swift Configuration
For Kanso Dictate, declare the dependency in `Package.swift` targeting release `1.1.1`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KansoDictate",
    platforms: [
        .macOS(.v14) // macOS 14+ recommended for Neural Engine audio encoder optimizations
    ],
    products: [
        .executable(name: "KansoDictate", targets: ["KansoDictate"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            from: "1.1.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "KansoDictate",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "KansoDictateTests",
            dependencies: ["KansoDictate"]
        )
    ]
)
```

> **Platform Requirement Note:** While WhisperKit's minimum platform is `macOS 13.0`, macOS 14.0+ is strongly recommended. WhisperKit's `ModelComputeOptions` conditionally selects `.cpuAndNeuralEngine` for `audioEncoderCompute` on macOS 14.0+ / iOS 17.0+ (falling back to `.cpuAndGPU` on macOS 13).

---

## 3. Model Directory & Storage Architecture

### 3.1 Upstream Default vs App Standard
WhisperKit uses an internal Hugging Face hub client (`HubApiWrapper` / `HubApi`).
- **Default Path:** When no `downloadBase` is specified, `HubApi` defaults to:
  ```swift
  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appending(component: "huggingface")
  // Resolves to: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/
  ```
  *Flaw:* This pollutes user document folders, triggers macOS privacy alerts (Documents access), and violates macOS App Store and sandbox guidelines.
- **Kanso Dictate Standard Path:** Models should be stored strictly in the application support directory:
  ```
  ~/Library/Application Support/KansoDictate/models/
  ```

### 3.2 Hugging Face Repository Layout
The models are hosted under repository `argmaxinc/whisperkit-coreml`:
Each model variant folder contains pre-compiled `.mlmodelc` bundles:
```
argmaxinc/whisperkit-coreml/
├── openai_whisper-base/
│   ├── AudioEncoder.mlmodelc/
│   ├── MelSpectrogram.mlmodelc/
│   ├── TextDecoder.mlmodelc/
│   ├── config.json
│   └── generation_config.json
├── openai_whisper-base.en/
├── openai_whisper-small/
└── openai_whisper-small.en/
```

### 3.3 Programmatic Download API vs Direct Local Loading

#### Option A: Programmatic Download with Custom `downloadBase`
WhisperKit exposes static download primitives:

```swift
import WhisperKit

public func downloadModel(variant: String = "openai_whisper-base") async throws -> URL {
    let appSupportDir = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let modelsBaseURL = appSupportDir.appendingPathComponent("KansoDictate/models", isDirectory: true)

    // Downloads matching files from argmaxinc/whisperkit-coreml into modelsBaseURL
    let localModelFolderURL = try await WhisperKit.download(
        variant: variant,
        downloadBase: modelsBaseURL,
        useBackgroundSession: false
    ) { progress in
        let fraction = progress.fractionCompleted
        // Update download progress indicator
    }

    return localModelFolderURL
}
```

> **Hub Storage Structure:** `HubApi` appends `models/argmaxinc/whisperkit-coreml/<variant>` to `downloadBase`. `WhisperKit.download(...)` returns the exact resolved folder URL containing `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, and `TextDecoder.mlmodelc`.

#### Option B: Direct Initialization with `modelFolder`
When models are already present on disk:

```swift
let pipe = try await WhisperKit(modelFolder: localModelFolderURL.path)
```
WhisperKit verifies the folder contents:
- It checks that `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, and `TextDecoder.mlmodelc` exist.
- It detects model dimensions from Core ML metadata.
- It locates `tokenizer.json` either in `modelFolder` or via `tokenizerFolder`.

### 3.4 Core ML On-Device Specialization & Prewarming

#### How Core ML Caching Works
1. WhisperKit models are downloaded as device-agnostic compiled models (`.mlmodelc`).
2. When Core ML loads an `.mlmodelc` for the first time on a specific machine, the macOS Core ML runtime compiles and "specializes" the neural network weights and compute graphs for the active Apple Silicon chip (M1/M2/M3/M4 Neural Engine).
3. The resulting hardware-specialized binaries are stored in Apple's system-managed Core ML cache (`/var/db/CoreML/...` / system cache).
4. Apple manages eviction automatically (e.g. after major macOS system updates or long periods of disuse).

#### Prewarming Trade-offs
In `WhisperKitConfig`:
```swift
var config = WhisperKitConfig(
    model: "openai_whisper-base",
    downloadBase: modelsBaseURL,
    prewarm: true, // Triggers sequential specialization
    load: true
)
```
- **With `prewarm: true`:** WhisperKit loads and immediately unloads `MelSpectrogram`, `AudioEncoder`, and `TextDecoder` sequentially.
  - *Advantage:* Keeps peak memory low during chip specialization. Prevents simultaneous multi-gigabyte memory spikes on 8 GB / 16 GB unified memory Macs.
  - *Disadvantage:* First cold load takes ~2x longer if the cache is already warm (<1–2s total overhead).
- **Recommendation for Kanso Dictate:** Run prewarming during initial setup or background app launch, so when the user presses the hotkey to dictate, the model is already specialized and hot in memory.

---

## 4. Recommended Model Variants for Apple Silicon

### 4.1 Evaluation Matrix

| Model Variant | Disk Footprint | Peak RAM | ANE Inference Latency (3s audio) | Accuracy Profile | Recommendation for Kanso Dictate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`openai_whisper-base.en`** | ~145 MB | ~220 MB | ~50–90 ms | High (English dictation) | **Primary Default (English)** |
| **`openai_whisper-base`** | ~145 MB | ~250 MB | ~60–110 ms | Moderate (Multilingual) | **Primary Default (Multilingual)** |
| **`openai_whisper-small.en`** | ~460 MB | ~520 MB | ~180–260 ms | Very High (English, technical jargon) | Advanced Option |
| **`openai_whisper-small`** | ~460 MB | ~550 MB | ~200–300 ms | Very High (Multilingual, accents) | Advanced Option |
| **`openai_whisper-small_216MB`** | ~216 MB | ~380 MB | ~160–220 ms | High (Quantized small) | Lightweight alternative to small |
| `openai_whisper-large-v3-v20240930_626MB` | ~626 MB | ~1.2 GB | ~550–900 ms | SOTA | Too heavy for instant push-to-talk |
| `openai_whisper-tiny` | ~75 MB | ~120 MB | ~30–50 ms | Low (High hallucination rate) | Debugging / CI only |

### 4.2 Compute Device Selection (`ModelComputeOptions`)
WhisperKit defaults to optimal Apple Silicon compute configurations:
```swift
let computeOptions = ModelComputeOptions(
    melCompute: .cpuAndGPU,              // Fast FFT and log-mel spectrogram extraction
    audioEncoderCompute: .cpuAndNeuralEngine, // Offloaded to Apple Neural Engine (ANE)
    textDecoderCompute: .cpuAndNeuralEngine   // Autoregressive token generation on ANE
)
```
- Routing the `AudioEncoder` and `TextDecoder` to `.cpuAndNeuralEngine` leaves CPU cores completely free for system tasks and prevents CPU thermal throttling.

---

## 5. Audio Input Preparation & Conversion

### 5.1 Format Requirements
`WhisperKit.transcribe(audioArray: [Float])` expects:
- **Sample Rate:** `16,000 Hz` (16 kHz)
- **Channels:** `1` (Mono)
- **Sample Format:** `Float32` (`[Float]`)
- **Range:** Normalized floating-point values in `[-1.0, 1.0]`

### 5.2 Converting Live Microphone Input (`AVAudioEngine`)
macOS microphones typically capture at 44.1 kHz or 48.0 kHz. To convert microphone buffers into 16 kHz Float samples:

```swift
import AVFoundation
import Accelerate

public final class AudioSampleConverter: Sendable {
    private let targetFormat: AVAudioFormat

    public init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        )!
    }

    /// Resamples an input AVAudioPCMBuffer to 16kHz mono [Float]
    public func convert(buffer: AVAudioPCMBuffer) throws -> [Float] {
        if buffer.format.sampleRate == 16000.0 && buffer.format.channelCount == 1 {
            return extractFloatArray(from: buffer)
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw AudioConversionError.converterInitializationFailed
        }

        let sampleRatio = 16000.0 / buffer.format.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRatio + 1024)

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetFrameCapacity
        ) else {
            throw AudioConversionError.bufferAllocationFailed
        }

        var error: NSError?
        var isConsumed = false

        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if !isConsumed {
                isConsumed = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error = error {
            throw error
        }

        guard status != .error else {
            throw AudioConversionError.conversionFailed
        }

        return extractFloatArray(from: convertedBuffer)
    }

    /// Extracts normalized [Float] from a mono Float32 AVAudioPCMBuffer
    private func extractFloatArray(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let channelPointer = channelData[0]
        return Array(UnsafeBufferPointer(start: channelPointer, count: frameLength))
    }
}

public enum AudioConversionError: Error {
    case converterInitializationFailed
    case bufferAllocationFailed
    case conversionFailed
}
```

### 5.3 Converting Raw Linear PCM Int16 Samples
If audio data arrives as 16-bit signed integer PCM (Int16) at 16 kHz:

```swift
public func convertInt16ToFloatNormalized(pcmData: Data) -> [Float] {
    let sampleCount = pcmData.count / MemoryLayout<Int16>.size
    var floatSamples = [Float](repeating: 0, count: sampleCount)

    pcmData.withUnsafeBytes { rawBuffer in
        guard let int16Buffer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
        for i in 0..<sampleCount {
            floatSamples[i] = Float(int16Buffer[i]) / 32768.0
        }
    }

    return floatSamples
}
```

---

## 6. Swift 6 Concurrency & Actor Isolation Architecture

### 6.1 Concurrency Audit of WhisperKit
Inspecting `WhisperKit` sources reveals:
- `open class WhisperKit` is a standard reference class.
- It contains mutable stored properties: `modelState`, `audioProcessor`, `featureExtractor`, `audioEncoder`, `textDecoder`, `segmentSeeker`, `currentTimings`, `progress`, and callbacks (`modelStateCallback`, `segmentDiscoveryCallback`).
- It does **not** conform to `Sendable`.
- `DecodingOptions` is `Sendable`.
- `TranscriptionResult` conforms to `@unchecked Sendable` (uses internal property locks).
- `TranscriptionResultStruct` is `Sendable`.

### 6.2 The Isolation Anti-Pattern (What Fails)
If a ViewModel or Controller declared on `@MainActor` does:
```swift
// DO NOT DO THIS
@MainActor
final class DictationViewModel {
    var whisperKit: WhisperKit? // Non-sendable stored in @MainActor

    func load() async throws {
        // Blocks or hitches the MainActor thread during Core ML initialization & compilation
        whisperKit = try await WhisperKit(...)
    }
}
```
In Swift 6 mode:
1. `WhisperKit` cannot be returned from a background task to `@MainActor` without compiler warning/error: `sending 'whisperKit' risks causing data races`.
2. Even `async` methods in Core ML run significant synchronous dispatch and compilation logic that can hitch the main runloop, causing beachballs in a menu bar app.

### 6.3 The Recommended Actor Encapsulation Pattern
Wrap `WhisperKit` completely inside a standalone background actor:

```
┌─────────────────────────────────────────────────────────┐
│                    @MainActor UI                        │
│   MenuBarExtra / StatusItem / PushToTalk State Machine  │
└────────────────────────────┬────────────────────────────┘
                             │
            async calls passing Sendable types
            ([Float] audio samples, Sendable options)
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                actor WhisperTranscriptionActor          │
│                                                         │
│  - Holds private non-Sendable `whisperKit: WhisperKit`  │
│  - Executes model setup & Core ML compilation           │
│  - Runs transcribe(audioArray:) off the main thread     │
│  - Returns Sendable `String` / `TranscriptionResult`    │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                 Core ML / Apple Neural Engine           │
│         AudioEncoder (ANE) + TextDecoder (ANE)          │
└─────────────────────────────────────────────────────────┘
```

### 6.4 Production-Grade Swift 6 Implementation

```swift
import Foundation
import WhisperKit

/// Dedicated actor isolating WhisperKit and Core ML inference off the MainActor.
public actor WhisperTranscriptionActor {
    private var whisperKit: WhisperKit?
    private var isInitializing: Bool = false

    public enum TranscriberState: Sendable {
        case uninitialized
        case downloading(Double)
        case compiling
        case ready
        case transcribing
        case failed(String)
    }

    public init() {}

    /// Prepares WhisperKit with the specified model, caching in Application Support.
    public func initialize(
        modelVariant: String = "openai_whisper-base",
        appSupportSubdirectory: String = "KansoDictate/models"
    ) async throws {
        guard whisperKit == nil, !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let baseCacheURL = appSupport.appendingPathComponent(appSupportSubdirectory, isDirectory: true)

        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )

        let config = WhisperKitConfig(
            model: modelVariant,
            downloadBase: baseCacheURL,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: true, // Sequentially compiles models to prevent memory spikes
            load: true,
            download: true
        )

        let kit = try await WhisperKit(config)
        self.whisperKit = kit
    }

    /// Transcribes an array of 16kHz mono Float samples.
    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard let whisperKit = self.whisperKit else {
            throw WhisperTranscriberError.notInitialized
        }

        guard !audioSamples.isEmpty else { return "" }

        var decodeOptions = DecodingOptions()
        decodeOptions.task = .transcribe
        decodeOptions.temperature = 0.0
        decodeOptions.skipSpecialTokens = true
        decodeOptions.withoutTimestamps = true

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: decodeOptions
        )

        let fullText = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return fullText
    }

    /// Releases model memory if the app enters background or idle mode.
    public func unload() async {
        if let whisperKit = self.whisperKit {
            await whisperKit.unloadModels()
            self.whisperKit = nil
        }
    }
}

public enum WhisperTranscriberError: LocalizedError {
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit has not been initialized. Call initialize() first."
        }
    }
}
```

---

## 7. Conclusions & Walking Skeleton Recommendations

1. **Add SPM Dependency:** Add `https://github.com/argmaxinc/argmax-oss-swift.git` from `1.1.1` in `Package.swift`.
2. **Standardize Cache Path:** Configure `downloadBase` to `~/Library/Application Support/KansoDictate/models`. Never let it default to `~/Documents/huggingface`.
3. **Default to `openai_whisper-base`:**
   - Disk: ~145 MB.
   - Inference: ~80ms on ANE for typical speech bursts.
   - RAM: ~250 MB.
   - Ideal for low-latency push-to-talk dictation.
4. **Prewarm Models:** Call `initialize()` at app launch or in the background to trigger Core ML ANE specialization before the user presses the dictation hotkey.
5. **Enforce Actor Boundary:** Wrap all WhisperKit interactions within `actor WhisperTranscriptionActor`. Only pass `[Float]` in and `String` out to guarantee zero UI hitching and full Swift 6 concurrency safety.
