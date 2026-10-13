import SwiftUI
import KansoCore

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var baseURL: String
    @Published public var apiKey: String
    @Published public var modelName: String
    @Published public var isAccessibilityGranted: Bool

    public init() {
        self.baseURL = UserDefaults.standard.string(forKey: "stt_base_url") ?? "https://api.groq.com/openai/v1"
        self.apiKey = UserDefaults.standard.string(forKey: "stt_api_key") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "stt_model") ?? "whisper-large-v3-turbo"
        self.isAccessibilityGranted = EventTapManager.isAccessibilityTrusted(prompt: false)
    }

    public func save() {
        UserDefaults.standard.set(baseURL, forKey: "stt_base_url")
        UserDefaults.standard.set(apiKey, forKey: "stt_api_key")
        UserDefaults.standard.set(modelName, forKey: "stt_model")
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

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("STT Provider (Remote OpenAI-Compatible)") {
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
        .frame(minWidth: 420, minHeight: 380)
        .onAppear {
            viewModel.refreshPermissions()
        }
    }
}
