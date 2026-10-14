import Foundation
import AVFoundation
import KansoCore

/// First-run permission onboarding: mic + Accessibility together.
/// macOS forbids programmatic Accessibility grant — we can only prompt;
/// mic we can request directly. Runs once, then relies on retry + Settings.
@MainActor
public enum PermissionOnboarding {
    private static let completedKey = "kanso_permission_onboarding_done"

    public static func requestIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        defaults.set(true, forKey: completedKey)

        // 1. Mic: system dialog, async grant.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // 2. Accessibility: opens the System Settings prompt (user must toggle manually).
        if !EventTapManager.isAccessibilityTrusted(prompt: true) {
            NSLog("KansoDictate: Requesting Accessibility permission on first run...")
        }
    }
}
