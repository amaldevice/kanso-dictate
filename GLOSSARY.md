# Glossary: Kanso Dictate

Canonical domain terms for the Kanso Dictate macOS dictation project.

## Core Concepts

### Kanso Dictate
The lightweight, native macOS dictation assistant application running in the menu bar.

### Walking Skeleton
The minimal end-to-end slice that connects audio recording, transcription (via local or remote engines), and active-window text insertion into a functioning native build.

### Push-To-Talk (PTT)
An interaction mode where audio recording activates when a designated hotkey is held down and stops immediately when released, initiating transcription and text insertion.

### Text Injector
The system subsystem responsible for pasting transcription results into the frontmost application using `NSPasteboard` and simulated `Cmd+V` keystroke synthesis via `CGEvent`.

### Speech-to-Text (STT) Engine
The polymorphic transcription abstraction interface that consumes 16kHz mono audio and returns raw text.

### Local STT Engine
A speech-to-text implementation running entirely on-device using CoreML and the Apple Silicon Neural Engine (ANE), specifically via `WhisperKit`.

### Remote STT Engine
A speech-to-text implementation sending audio over HTTP to an OpenAI-compatible `/v1/audio/transcriptions` endpoint (e.g. Groq, OpenAI, Ollama, self-hosted vLLM).

### History Store
The local database layer (implemented via `SwiftData`) recording past dictations, timestamps, durations, and target application identifiers.
