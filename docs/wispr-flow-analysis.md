# Wispr Flow Architecture & Reverse Engineering Analysis

- **Target Artifact**: `/Applications/Wispr Flow.app` (Installer: `Flow-v1.6.1102.dmg`)
- **App Version**: `1.6.1102` (commit `656b3fbfe214db4026fff75b3db650fc3edec8bb`)
- **Architecture**: Darwin `arm64` (Apple Silicon)
- **Swift Helper Hash (SHA-256)**: `21afb12c1c9edd28831358b8b03f8c8b43b716cf49858ec0be11d3a3f5859ca1`

---

## 1. High-Level System Architecture

Wispr Flow uses a **two-process hybrid architecture**:
1. **Host Process (Electron 42.x / Node / React)**:
   - Manages UI, settings, onboarding, audio recording via Web Audio, local database, and cloud communication.
   - Core bundle: `Contents/Resources/app.asar` (entry `.webpack/main/index.js`).
2. **Native Helper Process (Swift AppKit / Accessibility Daemon)**:
   - Standalone native binary: `Contents/Resources/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow` (5.8 MB).
   - Manages global shortcuts, low-level event taps (`CGEventTap`), macOS Accessibility inspection (`AXUIElement`), clipboard insertion (`NSPasteboard`), and synthetic keystrokes (`CGEvent`).
3. **Inter-Process Communication (IPC)**:
   - The Electron main process spawns the Swift helper as a child process.
   - Transport: **Standard Streams (`stdin` / `stdout`)**.
   - Protocol: **NDJSON (Newline-Delimited JSON)** with schemas generated via `quicktype` (`src/api/helper/schema.json` -> `Models.swift`).

```
                    ┌──────────────────────────────────────────────┐
                    │               Wispr Flow App                 │
                    └──────────────────────────────────────────────┘
                                           │
             ┌─────────────────────────────┴─────────────────────────────┐
             ▼                                                           ▼
┌─────────────────────────┐                                 ┌─────────────────────────┐
│   Swift Helper Daemon   │                                 │   Electron Host App     │
│ (swift-helper-app-dist) │ ◄──── NDJSON over Stdin/Stdout ────► │ (app.asar / React/Node) │
└─────────────────────────┘                                 └─────────────────────────┘
      │               │                                           │                 │
 (CGEventTap)   (AXUIElement &                               (Web Audio        (WebSocket
 Global Hotkey  NSPasteboard)                                 getUserMedia)      wss://)
      │               │                                           │                 │
      ▼               ▼                                           ▼                 ▼
 [macOS Window/Focus] [Paste & Verif]                       [Opus Encoder]    [Cloud ASR & LLM]
```

---

## 2. Speech & Audio Capture Mechanics

### A. Hotkey & Dictation Trigger
- The Swift helper sets up an event tap (`CGEventTap`) identified as `com.wispr-flow.input-event-capture.tap`.
- Special hardware keyboard inspection is present (`hasAppleFnKey`, Apple Magic Keyboard detection with Touch ID) to support the Fn/Globe key as a trigger.
- When dictation triggers:
  1. Helper notifies Electron via `DictationStart`.
  2. Electron plays start audio sound (`media:playDictationStartSound`).
  3. Swift helper attempts to pause active media or mute volume (`[Volume Manager] Pausing media for dictation`).

### B. Context Collection (Before Mic Opens)
Before recording starts, the helper executes `Beginning AX context collection`:
- Queries the system-wide focused element: `AXUIElementCopyAttributeValue(kAXFocusedUIElementAttribute)`.
- Captures PID (`kCGWindowOwnerPID`), application bundle ID (`frontmostBundleId`), window title, and active URL (in browsers like Safari and Chrome).
- Queries surrounding text:
  - `AXSelectedTextRange` / `AXSelectedTextRanges`
  - `AXStringForRange`
  - `AXNumberOfCharacters`
- Special app handlers exist:
  - `extractSlackTextyJSON` for Slack rich text editors.
  - CLI detection: `Detected focused coding CLI agent`.
- Sends context back to Electron as `CursorContextUpdatePayload`:
  - `textAreaContents`: text before and after the caret.
  - `fileNames`: open file context if applicable.
  - `screenReaderMode`: accessibility flag.

### C. Audio Acquisition & Encoding
- Audio is acquired in the Electron renderer using `navigator.mediaDevices.getUserMedia({ audio: ... })`.
- Handled by `AudioChunk` IPC events to the main process.
- Audio packets are processed through:
  - `incrementalOpusEncoder.worker.js` / `opusEncoder.worker.js`.
  - WebAssembly binary `opusscript_native_wasm.wasm`.
  - Format: **24.000 Hz, 1 channel (mono), PCM16 or Opus compressed frames**.

---

## 3. Cloud Transcription & AI Processing Protocol

Wispr Flow does **not** execute ASR or LLM inference locally. All processing routes to the cloud.

### A. Endpoints
- Production WebSocket: `wss://api.wisprflow.ai/`
- Regional Fallback: `wss://api-east.wisprflow.ai/`
- Production REST: `https://api.wisprflow.ai`
- Database / Auth: Supabase (`https://dodjkfqhwrzqjwkfnthl.supabase.co`)

### B. Streaming Protocol Frames
The streaming protocol over WebSocket mirrors the OpenAI Realtime / gRPC bidirectional streaming specification:

| Frame Type | Origin | Payload / Description |
|---|---|---|
| `session.start` | Client -> Server | Session UUID, model ID, instructions, context (`textAreaContents`, app bundle ID, custom vocabulary dictionary). |
| `session.update` | Client -> Server | Dynamic context updates while speaking. |
| `audio.append` | Client -> Server | Base64 audio payload (`encoding: "pcm16"`, `sample_rate: 24000`, `channels: 1`). |
| `audio.commit` | Client -> Server | Sent when the user releases the push-to-talk key. |
| `transcript.delta` | Server -> Client | Incremental raw speech-to-text transcription. |
| `transcript.final` | Server -> Client | Completed raw ASR text. |
| `text.delta` | Server -> Client | Incremental polished / edited text generated by the post-processing LLM. |
| `text.final` | Server -> Client | Final polished text ready for insertion into the target application. |
| `tool.call` | Server -> Client | Voice action tool invocations (if voice command was detected). |
| `done` | Server -> Client | Dictation stream completed. |

---

## 4. Text Insertion & Verification Mechanics

Insertion does not rely solely on `AXUIElementSetAttributeValue` because many modern apps (Electron, web browsers, canvas editors, games, terminal emulators) reject direct Accessibility value mutations. Wispr Flow uses a resilient **synthetic paste pipeline**:

```
[text.final ready]
       │
       ▼
1. Backup Clipboard ──► clipboard.readText() (Preserve user clipboard)
       │
       ▼
2. Re-focus Target   ──► NSRunningApplication.activate() + AXUIElementSetAttributeValue
       │
       ▼
3. Set Pasteboard    ──► NSPasteboard.general (NSPasteboardTypeString + NSPasteboardTypeHTML)
       │
       ▼
4. Synthesize Cmd+V  ──► CGEventCreateKeyboardEvent(kVK_ANSI_V, down/up) + CGEventFlags.maskCommand
       │
       ▼
5. Verify Insertion  ──► AXUIElement polling -> DictatedTextVerification (verdict, timeElapsedMs)
       │
       ▼
6. Restore Clipboard ──► DelayedClipboardProvider restores original clipboard after delay
```

### Detailed Sequence:
1. **Clipboard Snapshot**: Electron reads current pasteboard text via `clipboard.readText()`.
2. **Dispatch to Helper**: Electron dispatches `PasteText` IPC payload to the Swift helper:
   ```json
   {
     "pasteId": "uuid-v4",
     "text": "Polished dictated text",
     "htmlText": "<p>Optional rich text</p>",
     "captureKeystrokeTrace": true
   }
   ```
3. **Target Element Focus**: Swift Helper executes `Attempting to focus stored app and element`. If element focus fails, it activates the target PID via `NSRunningApplication.activate(options:)`.
4. **Pasteboard Population**: Writes string and HTML representations into `NSPasteboard.general`.
5. **Keystroke Simulation**: Emits virtual keycode `0x09` (ANSI 'V') with modifier flag `kCGEventFlagMaskCommand` via `CGEventPost`.
6. **Insertion Verification**:
   - Helper listens for `AXUIElement` changes or polls the text container contents (`focusedElementContents`).
   - Dispatches `DictatedTextVerification` back to Electron:
     - `verdict`: Success / Failure / Partial.
     - `timeToVerificationMs`: Measured latency.
7. **Clipboard Restoration**: Handled by `DelayedClipboardProvider` so the user's previous clipboard content is not permanently lost.

---

## 5. Local Storage & Database Schema

Local history and configurations are stored in an SQLite database (`~/Library/Application Support/Wispr Flow/flow.sqlite`) managed with Sequelize migrations:

### Core Tables & Fields:
- **`History` Table**:
  - `transcriptEntityId` (UUID PK)
  - `asrText` (Raw transcript from speech engine)
  - `formattedText` (Polished text output from LLM)
  - `editedText` (Post-paste edits made by user in the text box)
  - `audio` (BLOB of recorded speech audio)
  - `screenshot` (BLOB of screen capture if visual context enabled)
  - `additionalContext` (JSON containing surrounding text, caret position)
  - `status` (Completed, Dismissed, Failed)
  - `app` (Target app bundle name, e.g., `Slack`, `Cursor`)
  - `url` (Browser tab URL if inside a browser)
  - `e2e_latency` (Round-trip time from audio stop to text insertion)
- **`Polish` Table**:
  - `modelVersion` (LLM prompt/model version tracking)
  - `diffCount` (Levenshtein distance between raw `asrText` and `formattedText`)
- **`Dictionary` Table**: Custom vocabulary, acronyms, and replacements synced across devices.

---

## 6. Proven vs. Hidden Matrix

| Dimension | Status | Evidence / Details |
|---|---|---|
| **Local Models** | **Proven: None (0)** | No GGUF, ONNX, CoreML, or weight files exist in bundle. 100% cloud-dependent. |
| **Process Model** | **Proven** | Electron 42.x host + Swift helper daemon (`Contents/Resources/swift-helper-app-dist`). |
| **IPC Protocol** | **Proven** | Stdin/stdout NDJSON pipe with generated schemas. |
| **Audio Pipeline** | **Proven** | 24 kHz mono PCM16/Opus encoded via WebAssembly Opus worker. |
| **Text Insertion** | **Proven** | `NSPasteboard` + `CGEvent` Cmd+V with AX fallback and verification. |
| **Cloud ASR Model** | **Hidden** | Server-side proprietary backend (likely fine-tuned Whisper-large-v3, Conformer, or Deepgram). |
| **Cloud LLM Formatter** | **Hidden** | Server-side prompt and model (e.g., Claude 3.5 Haiku, GPT-4o-mini, or fine-tuned LLaMA). |
| **Voice Actions Engine**| **Hidden** | Server-side intent classifier returning `tool.call` frames. |

---

## 7. Clone Architecture Plan for `kanso-dictate`

### Recommendation: Native Swift vs Rust + Tauri

| Criteria | 100% Native Swift (Recommended) | Rust + Tauri |
|---|---|---|
| **macOS Accessibility (`AXUIElement`)** | First-class native C/Swift APIs | Requires complex `objc2`/`core-graphics` FFI bindings |
| **Keystroke Simulation (`CGEvent`)** | Native CoreGraphics calls | Unsafe FFI wrappers |
| **Local Neural Engine (ANE) Inference** | Direct CoreML / Metal acceleration via `WhisperKit` | Requires C-bridge to `whisper.cpp` |
| **Memory Footprint** | **35 – 65 MB RAM** | **150 – 250 MB RAM** (WKWebView overhead) |
| **Startup / Latency** | Instant cold boot (< 100ms) | WebView initialization delay |
| **Permission Handling (TCC)** | Direct OS integration for Mic & Accessibility | Multi-layer permission boundary |

**Decision**: Build `kanso-dictate` as a **100% Native Swift macOS application** (`SwiftUI` MenuBarExtra + `AVAudioEngine` + `CoreGraphics` + `CoreML`).

---

### Proposed Modular Architecture for `kanso-dictate`

```
kanso-dictate/
├── Sources/
│   ├── App/
│   │   ├── KansoDictateApp.swift      # MenuBarExtra & status item UI
│   │   └── SettingsView.swift         # Provider selection & shortcut configs
│   ├── Core/
│   │   ├── AudioRecorder.swift        # AVAudioEngine ring-buffer (16kHz mono)
│   │   ├── EventTapManager.swift      # CGEventTap global hotkey & PTT listener
│   │   ├── AccessibilityContext.swift # AXUIElement inspection (app, window, caret text)
│   │   └── TextInjector.swift         # NSPasteboard + CGEvent Cmd+V synthesizer
│   ├── Engine/
│   │   ├── SpeechToTextProtocol.swift # Unified STT engine interface
│   │   ├── Local/
│   │   │   ├── WhisperKitEngine.swift # Argmax WhisperKit (CoreML / Apple Neural Engine)
│   │   │   └── WhisperCppEngine.swift # Local whisper.cpp Metal fallback
│   │   └── Remote/
│   │       ├── GroqWhisperEngine.swift# Groq API (~150ms transcription latency)
│   │       ├── OpenAIWhisperEngine.swift
│   │       └── CustomAPI将被Engine.swift # Any OpenAI-compatible STT endpoint
│   ├── Polish/
│   │   ├── TextPolisherProtocol.swift
│   │   ├── LocalMLXEngine.swift       # Local Qwen2.5-3B / Llama-3.2-3B via MLX Swift
│   │   └── RemoteLLMEngine.swift      # OpenRouter / Groq / Ollama cleanup API
│   └── Storage/
│       └── HistoryStore.swift         # SwiftData or SQLite for local history
```

### Essential Features to Adapt:
1. **Push-To-Talk (PTT)**: Hold hotkey to record, release to transcribe and paste immediately.
2. **Hybrid Engine Switch**:
   - **Local Mode**: WhisperKit (CoreML `base.en` or `small`) for offline/private use.
   - **Cloud Turbo Mode**: Groq `whisper-large-v3-turbo` for near-instant (150–250ms) transcribing.
3. **Lightweight LLM Cleanup**:
   - System prompt: *"You are an inline speech formatting assistant. Remove filler words (um, uh, like), fix capitalization and punctuation, preserve natural intent. Never answer or converse. Return only the cleaned text."*
4. **Target App Context Prompting**:
   - If target app is Terminal / Cursor / Xcode -> instruct LLM to format as code/commands.
   - If target app is Slack / Messages -> instruct LLM to format as natural conversation.
5. **Safe Clipboard Preservation**:
   - Read and store `NSPasteboard.general` before paste.
   - Inject text and simulate `Cmd+V`.
   - Restore previous clipboard data after a 100ms delay.
