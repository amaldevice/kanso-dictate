import SwiftUI
import KansoCore

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var providerMode: STTProviderMode
    @Published public var baseURL: String
    @Published public var apiKey: String
    @Published public var modelName: String
    @Published public var modelVariant: String
    @Published public var cacheDirectory: String
    @Published public var isAccessibilityGranted: Bool

    public var onSettingsChanged: (@MainActor () -> Void)?

    public init(onSettingsChanged: (@MainActor () -> Void)? = nil) {
        self.onSettingsChanged = onSettingsChanged
        let rawMode = UserDefaults.standard.string(forKey: "stt_provider_mode") ?? STTProviderMode.remote.rawValue
        self.providerMode = STTProviderMode(rawValue: rawMode) ?? .remote
        self.baseURL = UserDefaults.standard.string(forKey: "stt_base_url") ?? "https://api.groq.com/openai/v1"
        self.apiKey = UserDefaults.standard.string(forKey: "stt_api_key") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "stt_model") ?? "whisper-large-v3-turbo"
        self.modelVariant = UserDefaults.standard.string(forKey: "whisperkit_model_variant") ?? "openai_whisper-base"
        self.cacheDirectory = UserDefaults.standard.string(forKey: "whisperkit_cache_directory") ?? WhisperKitConfig.defaultDownloadBase.path
        self.isAccessibilityGranted = EventTapManager.isAccessibilityTrusted(prompt: false)
    }

    public func save() {
        UserDefaults.standard.set(providerMode.rawValue, forKey: "stt_provider_mode")
        UserDefaults.standard.set(baseURL, forKey: "stt_base_url")
        UserDefaults.standard.set(apiKey, forKey: "stt_api_key")
        UserDefaults.standard.set(modelName, forKey: "stt_model")
        UserDefaults.standard.set(modelVariant, forKey: "whisperkit_model_variant")
        UserDefaults.standard.set(cacheDirectory, forKey: "whisperkit_cache_directory")
        onSettingsChanged?()
    }

    public func refreshPermissions() {
        isAccessibilityGranted = EventTapManager.isAccessibilityTrusted(prompt: false)
    }

    public func requestPermissions() {
        _ = EventTapManager.isAccessibilityTrusted(prompt: true)
        refreshPermissions()
    }
}

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(
        viewModel: SettingsViewModel? = nil,
        coordinator: DictationCoordinator? = nil,
        onSettingsChanged: (@MainActor () -> Void)? = nil
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
        self.viewModel = vm
    }

    public var body: some View {
        Form {
            Section("Speech-to-Text Provider") {
                Picker("Provider Mode:", selection: $viewModel.providerMode) {
                    Text("Remote (OpenAI-Compatible)").tag(STTProviderMode.remote)
                    Text("Local (WhisperKit CoreML)").tag(STTProviderMode.local)
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.providerMode) { viewModel.save() }

                if viewModel.providerMode == .remote {
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

            Section("Push-To-Talk Hotkey") {
                HStack {
                    Text("Trigger Key:")
                    Spacer()
                    Text("Right Option (⌥)")
                        .bold()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                }
                Text("Hold the Right Option key to record, release to transcribe and paste.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Label(
                        "Accessibility Privileges",
                        systemImage: viewModel.isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(viewModel.isAccessibilityGranted ? .green : .orange)

                    Spacer()

                    if !viewModel.isAccessibilityGranted {
                        Button("Grant Access") {
                            viewModel.requestPermissions()
                        }
                    }
                }

                Text("Required for Push-To-Talk key interception and synthetic paste into active apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            viewModel.refreshPermissions()
        }
    }
}
