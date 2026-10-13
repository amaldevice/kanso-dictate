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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Kanso Dictate - Settings"
        window.contentView = NSHostingView(rootView: SettingsView(coordinator: activeCoordinator))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }
}

public struct KansoDictateApp: App {
    @StateObject private var coordinator: DictationCoordinator
    @StateObject private var windowManager = WindowManager()
    private let eventTapManager = EventTapManager()

    public init() {
        let coordinatorInstance = DictationCoordinator()
        let windowManagerInstance = WindowManager(coordinator: coordinatorInstance)
        _coordinator = StateObject(wrappedValue: coordinatorInstance)
        _windowManager = StateObject(wrappedValue: windowManagerInstance)
        coordinatorInstance.onErrorNotification = { message in
            let alert = NSAlert()
            alert.messageText = "Dictation Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        // Setup Right Option Push-To-Talk
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
        MenuBarExtra("Kanso Dictate", systemImage: menuBarIcon) {
            Text(statusMessage)
                .font(.headline)

            Text("Engine: \(coordinator.activeEngine.displayName)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

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
    }
}
