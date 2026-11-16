import Foundation
import AppKit
import Combine
import KansoCore

@MainActor
private final class MockPermissionSource {
    var status: PermissionStatus
    var pollCount = 0

    init(status: PermissionStatus) {
        self.status = status
    }

    func check() -> PermissionStatus {
        pollCount += 1
        return status
    }
}

@MainActor
public func runPermissionPollingTests() async {
    // Slice 1: Explicit state (idle / polling) & start/stop idempotency
    do {
        let source = MockPermissionSource(status: PermissionStatus(
            isAccessibilityGranted: false,
            isMicrophoneGranted: true,
            isInputMonitoringGranted: false
        ))
        let coordinator = PermissionPollingCoordinator(
            pollInterval: .milliseconds(20),
            notificationCenter: NotificationCenter(),
            permissionProvider: { source.check() }
        )

        assert(coordinator.state == .idle, "Initial state must be .idle")
        assert(coordinator.status == source.status, "Initial status must match provider")
        let initialPolls = source.pollCount

        // Starting with missing permissions transitions idle -> polling
        coordinator.startPolling()
        assert(coordinator.state == .polling, "startPolling with missing permissions must enter .polling")
        let pollsAfterFirstStart = source.pollCount

        // Idempotent startPolling while already .polling does nothing extra
        coordinator.startPolling()
        assert(coordinator.state == .polling, "Repeated startPolling must remain .polling")
        assert(source.pollCount == pollsAfterFirstStart, "Idempotent startPolling must not re-query provider")

        // Stopping transitions polling -> idle
        coordinator.stopPolling()
        assert(coordinator.state == .idle, "stopPolling must transition to .idle")

        // Idempotent stopPolling while already .idle
        coordinator.stopPolling()
        assert(coordinator.state == .idle, "Repeated stopPolling must remain .idle")

        // Starting when all permissions are already granted stays .idle
        source.status = PermissionStatus(
            isAccessibilityGranted: true,
            isMicrophoneGranted: true,
            isInputMonitoringGranted: true
        )
        coordinator.startPolling()
        assert(coordinator.state == .idle, "startPolling with all permissions granted must remain .idle")
        assert(coordinator.status.allGranted, "Status must reflect refreshed granted permissions")
        assert(initialPolls == 1, "Init should query provider once")
        print("✔ PermissionPollingCoordinator explicit state and start/stop idempotency verified")
    }

    // Slice 2: Periodic polling, publish-only-on-change, and auto-stop on all permissions granted
    do {
        let source = MockPermissionSource(status: PermissionStatus(
            isAccessibilityGranted: false,
            isMicrophoneGranted: true,
            isInputMonitoringGranted: false
        ))
        let coordinator = PermissionPollingCoordinator(
            pollInterval: .milliseconds(15),
            notificationCenter: NotificationCenter(),
            permissionProvider: { source.check() }
        )

        var statusEmissions = 0
        let cancellable = coordinator.$status.dropFirst().sink { _ in
            statusEmissions += 1
        }
        defer { cancellable.cancel() }

        coordinator.startPolling()
        assert(coordinator.state == .polling, "Should be polling when permissions are missing")

        // Let a couple of unchanged ticks run; status must NOT republish
        let pollsBeforeWait = source.pollCount
        for _ in 0..<40 where source.pollCount < pollsBeforeWait + 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(source.pollCount >= pollsBeforeWait + 2, "Polling timer must invoke provider periodically")
        assert(statusEmissions == 0, "Unchanged status must not republish on $status")
        assert(coordinator.state == .polling, "Must stay .polling while permissions are missing")

        // Grant one missing permission -> should publish once and remain .polling
        source.status.isAccessibilityGranted = true
        for _ in 0..<50 where !coordinator.status.isAccessibilityGranted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(coordinator.status.isAccessibilityGranted, "Poll should pick up Accessibility grant")
        assert(statusEmissions == 1, "Status change should emit once on $status")
        assert(coordinator.state == .polling, "Must remain .polling while Input Monitoring is still missing")

        // Grant final permission -> poll should pick it up and auto-stop to .idle
        source.status.isInputMonitoringGranted = true
        for _ in 0..<50 where coordinator.state == .polling {
            try? await Task.sleep(for: .milliseconds(10))
        }
        assert(coordinator.state == .idle, "Polling must auto-stop to .idle when all permissions are granted")
        assert(coordinator.status.allGranted, "Status must reflect all permissions granted")
        assert(statusEmissions == 2, "Final grant should emit once more on $status")

        let pollsAtStop = source.pollCount
        try? await Task.sleep(for: .milliseconds(80))
        assert(source.pollCount == pollsAtStop, "No further polling may occur after auto-stop")
        print("✔ PermissionPollingCoordinator periodic ticks and all-granted auto-stop verified")
    }

    // Slice 3: Window-close teardown, unrelated-window isolation, focus refresh, and cached window reopen
    do {
        final class DummyWindow: NSObject {}

        let center = NotificationCenter()
        let source = MockPermissionSource(status: PermissionStatus(
            isAccessibilityGranted: false,
            isMicrophoneGranted: true,
            isInputMonitoringGranted: false
        ))
        let coordinator = PermissionPollingCoordinator(
            pollInterval: .milliseconds(20),
            notificationCenter: center,
            permissionProvider: { source.check() }
        )

        let settingsWindow = DummyWindow()
        let historyWindow = DummyWindow()

        coordinator.attachWindow(settingsWindow)
        coordinator.handleViewAppear()
        assert(coordinator.hostingWindow === settingsWindow, "hostingWindow must track attached window")
        assert(coordinator.state == .polling, "Opening Settings with missing permissions must start polling")

        // Closing an unrelated window must not affect Settings polling
        center.post(name: NSWindow.willCloseNotification, object: historyWindow)
        assert(coordinator.state == .polling, "Closing unrelated window must not stop Settings polling")

        // App activation while window is open refreshes permissions immediately
        source.status.isAccessibilityGranted = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        assert(coordinator.status.isAccessibilityGranted, "App activation must refresh permissions immediately")
        assert(coordinator.state == .polling, "Must stay .polling while Input Monitoring is still missing")

        // Closing the hosting window tears down polling cleanly
        center.post(name: NSWindow.willCloseNotification, object: settingsWindow)
        assert(coordinator.state == .idle, "Closing hosting window must stop polling")

        let pollsWhileClosed = source.pollCount
        try? await Task.sleep(for: .milliseconds(70))
        assert(source.pollCount == pollsWhileClosed, "Closed window must not continue polling")

        // App activation while cached window is closed must NOT restart polling
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        assert(coordinator.state == .idle, "App activation while Settings window is closed must stay .idle")

        // Reopening the cached window with missing permissions restarts polling cleanly
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        assert(coordinator.state == .polling, "Reopening cached window with missing permissions must restart polling")

        // Close again, grant remaining permission, then reopen -> must refresh and stay .idle
        center.post(name: NSWindow.willCloseNotification, object: settingsWindow)
        assert(coordinator.state == .idle, "Closing hosting window again must stop polling")
        source.status.isInputMonitoringGranted = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        assert(coordinator.status.allGranted, "Reopening cached window must refresh permissions")
        assert(coordinator.state == .idle, "Reopening cached window with all permissions granted must stay .idle")

        // Replacing hosting window drops old window observer; detaching nil stops polling
        source.status.isInputMonitoringGranted = false
        let secondWindow = DummyWindow()
        coordinator.attachWindow(secondWindow)
        assert(coordinator.state == .polling, "Attaching open window with missing permissions must start polling")

        center.post(name: NSWindow.willCloseNotification, object: settingsWindow)
        assert(coordinator.state == .polling, "Closing previously detached window must not stop polling for new window")

        coordinator.attachWindow(nil)
        assert(coordinator.state == .idle, "Detaching window (nil) must stop polling")

        // View appear / disappear fallback lifecycle
        coordinator.handleViewAppear()
        assert(coordinator.state == .polling, "handleViewAppear with missing permissions must start polling")
        coordinator.handleViewDisappear()
        assert(coordinator.state == .idle, "handleViewDisappear must stop polling")

        print("✔ PermissionPollingCoordinator window-close teardown, focus refresh, and cached reopen verified")
    }
}
