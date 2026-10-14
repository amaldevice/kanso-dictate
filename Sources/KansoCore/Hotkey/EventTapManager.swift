import Foundation
import CoreGraphics
import ApplicationServices

/// Manages global modifier hotkey detection for Push-To-Talk via CGEventTap.
public final class EventTapManager: @unchecked Sendable {
    public enum Constants {
        public static let rightOptionKeyCode: Int64 = 0x3D // 61 decimal
        public static let leftOptionKeyCode: Int64 = 0x3A  // 58 decimal
        public static let alternateMask: UInt64 = CGEventFlags.maskAlternate.rawValue // 0x0008_0000
        public static let rightOptionMask: UInt64 = 0x0020_0000 // NX_DEVICERALTKEYMASK
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private let lock = NSLock()
    private var isKeyPressed = false

    public var onKeyDown: (@Sendable () -> Void)?
    public var onKeyUp: (@Sendable () -> Void)?

    public init() {}

    deinit {
        stop()
    }

    /// Verifies whether the application has granted macOS Accessibility privileges.
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Checks permission to observe system-wide keyboard events (Input Monitoring).
    public static func isInputMonitoringAllowed() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Requests Input Monitoring permission; the user must approve it in System Settings.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
    /// Starts listening for Option modifier transitions.
    /// If accessibility is not yet granted, starts a lightweight retry observer on the main run loop.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard eventTap == nil else { return true }

        guard Self.isInputMonitoringAllowed() else {
            NSLog("KansoDictate: Input Monitoring permission not granted; waiting for approval.")
            schedulePermissionRetry()
            return false
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let observerPointer = Unmanaged.passUnretained(self).toOpaque()

        // Use .cgSessionEventTap for GUI user-session interception
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observerPointer
        ) else {
            NSLog("KansoDictate: CGEvent.tapCreate returned nil; retrying permission check.")
            schedulePermissionRetry()
            return false
        }

        retryTimer?.invalidate()
        retryTimer = nil

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("KansoDictate: Global hotkey event tap established successfully.")
        return true
    }

    /// Stops the active event tap and removes it from the run loop.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        retryTimer?.invalidate()
        retryTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
        }
        isKeyPressed = false
    }

    /// Re-reads live modifier state; drops a stuck KeyDown when Option was released while tap was disabled.
    public func resyncModifierState() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let optionDown = (flags & Constants.alternateMask) != 0
        lock.lock()
        let wasDown = isKeyPressed
        if wasDown, !optionDown {
            isKeyPressed = false
        }
        lock.unlock()
        if wasDown, !optionDown {
            onKeyUp?()
        }
    }

    private func schedulePermissionRetry() {
        guard retryTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if Self.isInputMonitoringAllowed() && Self.isAccessibilityTrusted(prompt: false) {
                    _ = self.start()
                }
            }
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isOptionKey = (keyCode == Constants.rightOptionKeyCode || keyCode == Constants.leftOptionKeyCode || keyCode == 61 || keyCode == 58)
        let flags = event.flags.rawValue
        let isAlternateDown = (flags & Constants.alternateMask) != 0

        // Handle Option key transitions (Right or Left Option)
        if isOptionKey || isAlternateDown != isKeyPressed {
            let isDown = isAlternateDown

            lock.lock()
            let previousState = isKeyPressed
            isKeyPressed = isDown
            lock.unlock()

            if isDown && !previousState {
                NSLog("KansoDictate: Option KeyDown detected (keyCode: %lld)", keyCode)
                onKeyDown?()
            } else if !isDown && previousState {
                NSLog("KansoDictate: Option KeyUp detected (keyCode: %lld)", keyCode)
                onKeyUp?()
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
