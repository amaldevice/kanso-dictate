import Foundation
import AVFoundation
import AppKit
import Combine

/// Explicit lifecycle state of TCC permission polling in Settings.
public enum PermissionPollingState: Sendable, Equatable {
    case idle
    case polling
}

/// Snapshot of required macOS TCC permissions for Kanso Dictate.
public struct PermissionStatus: Sendable, Equatable {
    public var isAccessibilityGranted: Bool
    public var isMicrophoneGranted: Bool
    public var isInputMonitoringGranted: Bool

    public var allGranted: Bool {
        isAccessibilityGranted && isInputMonitoringGranted && isMicrophoneGranted
    }

    public init(
        isAccessibilityGranted: Bool = false,
        isMicrophoneGranted: Bool = false,
        isInputMonitoringGranted: Bool = false
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.isMicrophoneGranted = isMicrophoneGranted
        self.isInputMonitoringGranted = isInputMonitoringGranted
    }

    /// Reads the live macOS TCC status without triggering permission prompts.
    public static func live() -> PermissionStatus {
        PermissionStatus(
            isAccessibilityGranted: EventTapManager.isAccessibilityTrusted(prompt: false),
            isMicrophoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            isInputMonitoringGranted: EventTapManager.isInputMonitoringAllowed()
        )
    }
}

/// Manages the explicit permission polling lifecycle, auto-stop, and window/focus observation.
@MainActor
public final class PermissionPollingCoordinator: ObservableObject {
    @Published public private(set) var state: PermissionPollingState = .idle
    @Published public private(set) var status: PermissionStatus

    public private(set) weak var hostingWindow: AnyObject?

    private let pollInterval: Duration
    private let notificationCenter: NotificationCenter
    private let permissionProvider: @MainActor () -> PermissionStatus
    private var isWindowOpen = false
    nonisolated(unsafe) private var pollingTask: Task<Void, Never>?
    private var appActivationCancellable: AnyCancellable?
    private var windowCancellables = Set<AnyCancellable>()

    public init(
        pollInterval: Duration = .seconds(1),
        notificationCenter: NotificationCenter = .default,
        permissionProvider: @escaping @MainActor () -> PermissionStatus = { PermissionStatus.live() }
    ) {
        self.pollInterval = pollInterval
        self.notificationCenter = notificationCenter
        self.permissionProvider = permissionProvider
        self.status = permissionProvider()

        self.appActivationCancellable = observeNotification(NSApplication.didBecomeActiveNotification) { coordinator in
            coordinator.handleAppDidBecomeActive()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    /// Attaches the hosting window so close and key-window reopen events drive polling automatically.
    public func attachWindow(_ window: AnyObject?) {
        if window === hostingWindow {
            if window == nil {
                isWindowOpen = false
                stopPolling()
            }
            return
        }

        windowCancellables.removeAll()
        hostingWindow = window

        guard let window else {
            isWindowOpen = false
            stopPolling()
            return
        }

        observeNotification(NSWindow.willCloseNotification, object: window) { coordinator in
            coordinator.handleWindowWillClose()
        }
        .store(in: &windowCancellables)

        observeNotification(NSWindow.didBecomeKeyNotification, object: window) { coordinator in
            coordinator.handleWindowDidBecomeKey()
        }
        .store(in: &windowCancellables)

        isWindowOpen = true
        startPolling()
    }

    /// Notifies the coordinator that the Settings view appeared.
    public func handleViewAppear() {
        isWindowOpen = true
        refreshAndPollIfNeeded()
    }

    /// Notifies the coordinator that the Settings view disappeared.
    public func handleViewDisappear() {
        isWindowOpen = false
        stopPolling()
    }

    /// Queries the permission provider and updates `status` only on change.
    public func refreshPermissions() {
        let latest = permissionProvider()
        if status != latest {
            status = latest
        }
        if status.allGranted {
            stopPolling()
        }
    }

    /// Idempotently starts polling if any required permission is missing.
    public func startPolling() {
        guard state == .idle else { return }
        refreshPermissions()
        guard !status.allGranted else { return }
        state = .polling
        let interval = pollInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self, self.state == .polling else { break }
                self.refreshPermissions()
            }
        }
    }

    /// Idempotently stops polling and returns to `.idle`.
    public func stopPolling() {
        guard state == .polling || pollingTask != nil else { return }
        pollingTask?.cancel()
        pollingTask = nil
        state = .idle
    }

    private func handleWindowWillClose() {
        isWindowOpen = false
        stopPolling()
    }

    private func handleWindowDidBecomeKey() {
        isWindowOpen = true
        refreshAndPollIfNeeded()
    }

    private func handleAppDidBecomeActive() {
        if isWindowOpen {
            refreshAndPollIfNeeded()
        } else if state == .polling {
            refreshPermissions()
        }
    }

    private func refreshAndPollIfNeeded() {
        if state == .idle {
            startPolling()
        } else {
            refreshPermissions()
        }
    }

    private func observeNotification(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        handler: @escaping @MainActor @Sendable (PermissionPollingCoordinator) -> Void
    ) -> AnyCancellable {
        notificationCenter.publisher(for: name, object: object).sink { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    handler(self)
                }
            }
        }
    }
}
