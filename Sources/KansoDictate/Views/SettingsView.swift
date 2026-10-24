import SwiftUI
import KansoCore
import AVFoundation
import AppKit

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var providerMode: STTProviderMode
    @Published public var baseURL: String
    @Published public var apiKey: String
    @Published public var modelName: String
    @Published public var modelVariant: String
    @Published public var cacheDirectory: String
    @Published public var geminiApiKey: String
    @Published public var geminiModel: String
    @Published public var deepgramApiKey: String
    @Published public var deepgramModel: String
    @Published public var cloudflareAccountID: String
    @Published public var cloudflareApiToken: String
    @Published public var assemblyaiApiKey: String
    @Published public var assemblyaiModel: String
    @Published public var speechmaticsApiKey: String
    @Published public var speechmaticsModel: String
    @Published public var revaiApiKey: String
    @Published public var revaiModel: String
    @Published public var elevenlabsApiKey: String
    @Published public var elevenlabsModel: String
    @Published public var isAccessibilityGranted: Bool
    @Published public var isMicrophoneGranted: Bool
    @Published public var isInputMonitoringGranted: Bool
    @Published public var pttTrigger: PTTTriggerKey
    public var onSettingsChanged: (@MainActor () -> Void)?
    public var onHotkeyChanged: (@MainActor (PTTTriggerKey) -> Void)?
    public init(onSettingsChanged: (@MainActor () -> Void)? = nil) {
        self.onSettingsChanged = onSettingsChanged
        self.pttTrigger = PTTTriggerKey.load()
        let rawMode = UserDefaults.standard.string(forKey: "stt_provider_mode") ?? STTProviderMode.remote.rawValue
        self.providerMode = STTProviderMode(rawValue: rawMode) ?? .remote
        self.baseURL = UserDefaults.standard.string(forKey: "stt_base_url") ?? "https://api.groq.com/openai/v1"
        self.apiKey = UserDefaults.standard.string(forKey: "stt_api_key") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "stt_model") ?? "whisper-large-v3-turbo"
        self.modelVariant = UserDefaults.standard.string(forKey: "whisperkit_model_variant") ?? "openai_whisper-base"
        self.cacheDirectory = UserDefaults.standard.string(forKey: "whisperkit_cache_directory") ?? WhisperKitConfig.defaultDownloadBase.path
        self.geminiApiKey = UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
        self.geminiModel = UserDefaults.standard.string(forKey: "gemini_model") ?? GeminiSTTConfig.defaultModel
        self.deepgramApiKey = UserDefaults.standard.string(forKey: "deepgram_api_key") ?? ""
        self.deepgramModel = UserDefaults.standard.string(forKey: "deepgram_model") ?? DeepgramSTTConfig.defaultModel
        self.cloudflareAccountID = UserDefaults.standard.string(forKey: "cloudflare_account_id") ?? ""
        self.cloudflareApiToken = UserDefaults.standard.string(forKey: "cloudflare_api_token") ?? ""
        self.assemblyaiApiKey = UserDefaults.standard.string(forKey: "assemblyai_api_key") ?? ""
        self.assemblyaiModel = UserDefaults.standard.string(forKey: "assemblyai_model") ?? AssemblyAISTTConfig.defaultModel
        self.speechmaticsApiKey = UserDefaults.standard.string(forKey: "speechmatics_api_key") ?? ""
        self.speechmaticsModel = UserDefaults.standard.string(forKey: "speechmatics_model") ?? SpeechmaticsSTTConfig.defaultModel
        self.revaiApiKey = UserDefaults.standard.string(forKey: "revai_api_key") ?? ""
        self.revaiModel = UserDefaults.standard.string(forKey: "revai_model") ?? RevAISTTConfig.defaultModel
        self.elevenlabsApiKey = UserDefaults.standard.string(forKey: "elevenlabs_api_key") ?? ""
        self.elevenlabsModel = UserDefaults.standard.string(forKey: "elevenlabs_model") ?? ElevenLabsSTTConfig.defaultModel
        self.isAccessibilityGranted = EventTapManager.isAccessibilityTrusted(prompt: false)
        self.isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        self.isInputMonitoringGranted = EventTapManager.isInputMonitoringAllowed()
    }

    public func save() {
        UserDefaults.standard.set(providerMode.rawValue, forKey: "stt_provider_mode")
        UserDefaults.standard.set(baseURL, forKey: "stt_base_url")
        UserDefaults.standard.set(apiKey, forKey: "stt_api_key")
        UserDefaults.standard.set(modelName, forKey: "stt_model")
        UserDefaults.standard.set(modelVariant, forKey: "whisperkit_model_variant")
        UserDefaults.standard.set(cacheDirectory, forKey: "whisperkit_cache_directory")
        UserDefaults.standard.set(geminiApiKey, forKey: "gemini_api_key")
        UserDefaults.standard.set(geminiModel, forKey: "gemini_model")
        UserDefaults.standard.set(deepgramApiKey, forKey: "deepgram_api_key")
        UserDefaults.standard.set(deepgramModel, forKey: "deepgram_model")
        UserDefaults.standard.set(cloudflareAccountID, forKey: "cloudflare_account_id")
        UserDefaults.standard.set(cloudflareApiToken, forKey: "cloudflare_api_token")
        UserDefaults.standard.set(assemblyaiApiKey, forKey: "assemblyai_api_key")
        UserDefaults.standard.set(assemblyaiModel, forKey: "assemblyai_model")
        UserDefaults.standard.set(speechmaticsApiKey, forKey: "speechmatics_api_key")
        UserDefaults.standard.set(speechmaticsModel, forKey: "speechmatics_model")
        UserDefaults.standard.set(revaiApiKey, forKey: "revai_api_key")
        UserDefaults.standard.set(revaiModel, forKey: "revai_model")
        UserDefaults.standard.set(elevenlabsApiKey, forKey: "elevenlabs_api_key")
        UserDefaults.standard.set(elevenlabsModel, forKey: "elevenlabs_model")
        pttTrigger.save()
        onSettingsChanged?()
    }

    public func applyPreset(_ preset: STTRemotePreset) {
        baseURL = preset.baseURL.absoluteString
        modelName = preset.model
        save()
    }

    public func refreshPermissions() {
        isAccessibilityGranted = EventTapManager.isAccessibilityTrusted(prompt: false)
        isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isInputMonitoringGranted = EventTapManager.isInputMonitoringAllowed()
    }


    public func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

}

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(
        viewModel: SettingsViewModel? = nil,
        coordinator: DictationCoordinator? = nil,
        onSettingsChanged: (@MainActor () -> Void)? = nil,
        onHotkeyChanged: (@MainActor (PTTTriggerKey) -> Void)? = nil
    ) {
        let vm = viewModel ?? SettingsViewModel()
        if let coordinator = coordinator {
            vm.onSettingsChanged = {
                onSettingsChanged?()
                coordinator.configureEngineFromPreferences()
            }
        } else if let onSettingsChanged = onSettingsChanged {
            vm.onSettingsChanged = onSettingsChanged
        }
        if let onHotkeyChanged {
            vm.onHotkeyChanged = onHotkeyChanged
        }
        self.viewModel = vm
    }

    public var body: some View {
        ScrollView {
            Form {
                Section("Speech-to-Text Provider") {
                    Picker("Provider:", selection: $viewModel.providerMode) {
                        Text("Remote (OpenAI-Compatible)").tag(STTProviderMode.remote)
                        Text("Local (WhisperKit CoreML)").tag(STTProviderMode.local)
                        Divider()
                        Text("Gemini (Free Tier)").tag(STTProviderMode.gemini)
                        Text("Deepgram (Free Tier)").tag(STTProviderMode.deepgram)
                        Text("Cloudflare (Free Tier)").tag(STTProviderMode.cloudflare)
                        Text("AssemblyAI ($50 Credit)").tag(STTProviderMode.assemblyai)
                        Text("Speechmatics ($100 Grant)").tag(STTProviderMode.speechmatics)
                        Text("Rev.ai (5h Trial)").tag(STTProviderMode.revai)
                        Text("ElevenLabs").tag(STTProviderMode.elevenlabs)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.providerMode) { viewModel.save() }
                if viewModel.providerMode == .remote {
                    Picker("Preset:", selection: Binding(
                        get: { "custom" },
                        set: { tag in
                            if let preset = STTRemotePreset(rawValue: tag) {
                                viewModel.applyPreset(preset)
                            }
                        }
                    )) {
                        Text("Custom").tag("custom")
                        ForEach(STTRemotePreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }

                    TextField("Base URL:", text: $viewModel.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.baseURL) { viewModel.save() }

                    SecureField("API Key (Groq / OpenAI):", text: $viewModel.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.apiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.modelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.modelName) { viewModel.save() }

                    Text("Supports Groq, OpenAI, Ollama, and self-hosted vLLM endpoints.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .gemini {
                    SecureField("API Key (Gemini AI Studio):", text: $viewModel.geminiApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.geminiApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.geminiModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.geminiModel) { viewModel.save() }

                    Text("Cloud transcription via Gemini Developer API free tier (rate-limited daily requests). Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .deepgram {
                    SecureField("API Key (Deepgram Console):", text: $viewModel.deepgramApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.deepgramApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.deepgramModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.deepgramModel) { viewModel.save() }

                    Text("Cloud transcription via Deepgram $200 credit (no card). Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .cloudflare {
                    TextField("Account ID:", text: $viewModel.cloudflareAccountID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.cloudflareAccountID) { viewModel.save() }

                    SecureField("API Token:", text: $viewModel.cloudflareApiToken)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.cloudflareApiToken) { viewModel.save() }

                    Text("Cloud transcription via Cloudflare Workers AI (~$0.0005/min + daily free Neurons). Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .assemblyai {
                    SecureField("API Key (AssemblyAI):", text: $viewModel.assemblyaiApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.assemblyaiApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.assemblyaiModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.assemblyaiModel) { viewModel.save() }

                    Text("Cloud transcription via AssemblyAI $50 credit (no card). Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .speechmatics {
                    SecureField("API Key (Speechmatics):", text: $viewModel.speechmaticsApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.speechmaticsApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.speechmaticsModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.speechmaticsModel) { viewModel.save() }

                    Text("Cloud transcription via Speechmatics $100 grant. Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .revai {
                    SecureField("Access Token (Rev.ai):", text: $viewModel.revaiApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.revaiApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.revaiModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.revaiModel) { viewModel.save() }

                    Text("Cloud transcription via Rev.ai 5 free hours. Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.providerMode == .elevenlabs {
                    SecureField("API Key (ElevenLabs):", text: $viewModel.elevenlabsApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.elevenlabsApiKey) { viewModel.save() }

                    TextField("Model Name:", text: $viewModel.elevenlabsModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.elevenlabsModel) { viewModel.save() }

                    Text("Cloud transcription via ElevenLabs Scribe (~12 min/mo free). Audio leaves the device, unlike Local mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextField("Model Variant:", text: $viewModel.modelVariant)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.modelVariant) { viewModel.save() }

                    TextField("Model Cache Directory:", text: $viewModel.cacheDirectory)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.cacheDirectory) { viewModel.save() }

                    Text("Runs 100% locally on-device using WhisperKit and Apple Neural Engine.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if viewModel.providerMode == .remote {
                Section("Quick Presets") {
                    HStack {
                        Text("Popular Endpoints:")
                        Spacer()
                        Menu("Select Preset...") {
                            ForEach(STTRemotePreset.allCases, id: \.self) { preset in
                                Button(preset.displayName) { viewModel.applyPreset(preset) }
                            }
                        }
                    }
                    Text("Auto-fills Base URL and Model for Voxtral, Fireworks, Together, Groq, etc.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Push-To-Talk Hotkey") {
                Picker("Trigger Key:", selection: $viewModel.pttTrigger) {
                    ForEach(PTTTriggerKey.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.pttTrigger) {
                    viewModel.save()
                    viewModel.onHotkeyChanged?(viewModel.pttTrigger)
                }
                Text("Hold the \(viewModel.pttTrigger.displayName) key to record, release to transcribe and paste.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Label(
                        "Accessibility — \(viewModel.isAccessibilityGranted ? "Granted" : "Not Granted")",
                        systemImage: viewModel.isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(viewModel.isAccessibilityGranted ? .green : .orange)

                    Spacer()

                    Button("Refresh Status") {
                        viewModel.refreshPermissions()
                    }
                    if !viewModel.isAccessibilityGranted {
                        Button("Grant Access") {
                            _ = EventTapManager.isAccessibilityTrusted(prompt: true)
                            viewModel.refreshPermissions()
                        }
                    }
                    Button("Open System Settings") {
                        viewModel.openSystemSettings()
                    }
                }

                Text("Required for controlling apps and synthetic paste. Global hotkey also requires Input Monitoring.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Label(
                        "Input Monitoring — \(viewModel.isInputMonitoringGranted ? "Granted" : "Not Granted")",
                        systemImage: viewModel.isInputMonitoringGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(viewModel.isInputMonitoringGranted ? .green : .orange)

                    Spacer()

                    Button("Refresh Status") {
                        viewModel.refreshPermissions()
                    }
                    if !viewModel.isInputMonitoringGranted {
                        Button("Request Access") {
                            _ = EventTapManager.requestInputMonitoring()
                            viewModel.refreshPermissions()
                        }
                    }
                    Button("Open System Settings") {
                        viewModel.openInputMonitoringSettings()
                    }
                }

                Text(viewModel.isInputMonitoringGranted ? "Granted — global Option key monitoring is authorized." : "Required to detect Option globally. Enable Kanso Dictate under System Settings → Privacy & Security → Input Monitoring.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Label(
                        "Microphone — \(viewModel.isMicrophoneGranted ? "Granted" : "Not Granted")",
                        systemImage: viewModel.isMicrophoneGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(viewModel.isMicrophoneGranted ? .green : .orange)

                    Spacer()

                    if !viewModel.isMicrophoneGranted {
                        Button("Grant Access") {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in
                                Task { @MainActor in viewModel.refreshPermissions() }
                            }
                        }
                    }
                }

                Text(viewModel.isMicrophoneGranted ? "Granted — audio capture ready." : "Required for audio capture. macOS prompts once; if denied, enable in System Settings → Privacy → Microphone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            viewModel.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may have flipped a TCC toggle in System Settings; re-check on return.
            viewModel.refreshPermissions()
        }
    }
}
