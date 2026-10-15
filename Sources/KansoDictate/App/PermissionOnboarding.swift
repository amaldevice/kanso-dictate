import Foundation
import AVFoundation
import KansoCore

/// First-run permission onboarding for microphone, Accessibility, and Input Monitoring.
/// macOS requires explicit user approval for all three permissions.
@MainActor
public enum PermissionOnboarding {
    private static let completedKey = "kanso_permission_onboarding_done"

    public static func requestIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        defaults.set(true, forKey: completedKey)

        // 1. Mic: system dialog, async grant.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // 2. Accessibility: user grants control in System Settings.
        if !EventTapManager.isAccessibilityTrusted(prompt: true) {
            NSLog("KansoDictate: Requesting Accessibility permission on first run...")
        }

        // 3. Input Monitoring: separately authorizes listening for global keyboard events.
        if !EventTapManager.isInputMonitoringAllowed() {
            _ = EventTapManager.requestInputMonitoring()
            NSLog("KansoDictate: Requesting Input Monitoring permission on first run...")
        }
    }
}
