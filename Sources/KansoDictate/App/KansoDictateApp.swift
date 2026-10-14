import SwiftUI
import AppKit
import KansoCore

@MainActor
public final class WindowManager: ObservableObject {
    public var historyWindow: NSWindow?
    public var settingsWindow: NSWindow?
    public weak var coordinator: DictationCoordinator?

    public init(coordinator: DictationCoordinator? = nil) {
        self.coordinator = coordinator
    }
    public func openHistory(coordinator: DictationCoordinator) {
        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Kanso Dictate - History"
        window.contentView = NSHostingView(rootView: HistoryView(coordinator: coordinator))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }

    public func openSettings(coordinator: DictationCoordinator? = nil) {
        let activeCoordinator = coordinator ?? self.coordinator
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 460, height: 420)
        window.title = "Kanso Dictate - Settings"
        window.contentView = NSHostingView(rootView: SettingsView(coordinator: activeCoordinator))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }
}

@MainActor
public final class HotkeyStatus: ObservableObject {
    @Published public var isActive = EventTapManager.isAccessibilityTrusted(prompt: false)
    public init() {}
    public func refresh() { isActive = EventTapManager.isAccessibilityTrusted(prompt: false) }
}

public struct KansoDictateApp: App {
    @StateObject private var coordinator: DictationCoordinator
    @StateObject private var windowManager = WindowManager()
    @StateObject private var hudController: FloatingHUDController
    @StateObject private var hotkeyStatus = HotkeyStatus()
    private let eventTapManager = EventTapManager()

    public init() {
        let coordinatorInstance = DictationCoordinator()
        let windowManagerInstance = WindowManager(coordinator: coordinatorInstance)
        let hudInstance = FloatingHUDController(coordinator: coordinatorInstance)
        _coordinator = StateObject(wrappedValue: coordinatorInstance)
        _windowManager = StateObject(wrappedValue: windowManagerInstance)
        _hudController = StateObject(wrappedValue: hudInstance)
        coordinatorInstance.onErrorNotification = { message in
            NSLog("KansoDictate Error: %@", message)
        }

        // First-run: request mic + Accessibility together so Option hotkey works immediately after grant.
        PermissionOnboarding.requestIfNeeded()

        // Setup Option Push-To-Talk
        eventTapManager.onKeyDown = { [weak coordinatorInstance] in
            Task { @MainActor in
                coordinatorInstance?.startDictation()
            }
        }

        eventTapManager.onKeyUp = { [weak coordinatorInstance] in
            Task { @MainActor in
                coordinatorInstance?.stopDictation()
            }
        }

        eventTapManager.start()
    }
    private var menuBarTitle: String {
        switch coordinator.state {
        case .idle:
            return "Kanso Dictate"
        case .recording:
            return "Kanso Dictate (Recording)"
        case .transcribing:
            return "Kanso Dictate (Transcribing)"
        case .inserting:
            return "Kanso Dictate (Inserting)"
        case .error(let msg):
            return "Kanso Dictate - Error: \(msg)"
        }
    }

    private var menuBarIcon: String {
        switch coordinator.state {
        case .idle:
            return "mic"
        case .recording:
            return "record.circle.fill"
        case .transcribing:
            return "hourglass"
        case .inserting:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }

    private var statusMessage: String {
        switch coordinator.state {
        case .idle:
            return "Ready: Hold Right Option"
        case .recording:
            return "Recording audio..."
        case .transcribing:
            return "Transcribing..."
        case .inserting:
            return "Pasting text..."
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    public var body: some Scene {
        MenuBarExtra(menuBarTitle, systemImage: menuBarIcon) {
            Text(statusMessage)
                .font(.headline)
                .help(statusMessage)
                .onAppear { hotkeyStatus.refresh() }

            Text("Engine: \(coordinator.activeEngine.displayName)")
                .font(.caption)
                .foregroundColor(.secondary)
            if !hotkeyStatus.isActive {
                Text("⚠️ Option hotkey OFF — grant Accessibility in Settings")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()
            if coordinator.state == .recording {
                Button("Stop Dictation & Transcribe") {
                    coordinator.stopDictation(forceCommit: true)
                }
            } else {
                Button("Start Dictation (or Hold ⌥)") {
                    eventTapManager.resyncModifierState()
                    coordinator.startDictation()
                }
            }


            Button("History...") {
                windowManager.openHistory(coordinator: coordinator)
            }
            .keyboardShortcut("h")

            Button("Settings...") {
                windowManager.openSettings(coordinator: coordinator)
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Kanso Dictate") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onChange(of: coordinator.state) { _ in
            if coordinator.state == .idle {
                eventTapManager.resyncModifierState()
                hotkeyStatus.refresh()
            }
        }
    }
}
