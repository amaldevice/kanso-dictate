import Foundation
import CoreGraphics
import ApplicationServices

/// Manages global modifier hotkey detection for Push-To-Talk via CGEventTap.
public final class EventTapManager: @unchecked Sendable {
    public enum Constants {
        public static let rightOptionKeyCode: Int64 = 0x3D // 61 decimal
        public static let leftOptionKeyCode: Int64 = 0x3A  // 58 decimal
        public static let alternateMask: UInt64 = CGEventFlags.maskAlternate.rawValue // 0x0008_0000
        // Device-dependent masks from <IOKit/hidsystem/IOLLEvent.h> (NOT maskNumericPad 0x200000).
        public static let leftOptionMask: UInt64 = 0x0000_0020 // NX_DEVICELALTKEYMASK
        public static let rightOptionMask: UInt64 = 0x0000_0040 // NX_DEVICERALTKEYMASK
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workerThread: Thread?
    private var workerRunLoop: CFRunLoop?
    private var retryTimer: Timer?
    private let lock = NSLock()
    private var isKeyPressed = false

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }

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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.eventTap = tap
        self.runLoopSource = source
        self.workerRunLoop = nil

        // Dedicated worker thread: keeps tap alive during menu tracking,
        // window dragging, and SwiftUI/audio work on the main thread.
        let worker = Thread { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let currentTap = self.eventTap, let currentSource = self.runLoopSource else {
                self.lock.unlock()
                return
            }
            self.workerRunLoop = CFRunLoopGetCurrent()
            let loop = self.workerRunLoop
            self.lock.unlock()

            guard let loop else { return }
            CFRunLoopAddSource(loop, currentSource, .commonModes)
            CGEvent.tapEnable(tap: currentTap, enable: true)
            CFRunLoopRun()
        }
        worker.name = "dev.kanso-dictate.eventtap"
        worker.qualityOfService = .userInteractive
        self.workerThread = worker
        worker.start()

        NSLog("KansoDictate: Global hotkey event tap established successfully.")
        return true
    }

    /// Stops the active event tap and its worker thread.
    public func stop() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        let runLoop = workerRunLoop
        retryTimer?.invalidate()
        retryTimer = nil
        eventTap = nil
        runLoopSource = nil
        workerRunLoop = nil
        workerThread = nil
        isKeyPressed = false
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source, let runLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFRunLoopStop(runLoop)
            }
        }
    }

    /// Re-reads live modifier state; drops a stuck KeyDown when Option was released while tap was disabled.
    public func resyncModifierState() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let optionDown = (flags & Constants.alternateMask) != 0
            || (flags & Constants.leftOptionMask) != 0
            || (flags & Constants.rightOptionMask) != 0
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawFlags = event.flags.rawValue
        let leftDown = (rawFlags & Constants.leftOptionMask) != 0
        let rightDown = (rawFlags & Constants.rightOptionMask) != 0
        let alternateDown = (rawFlags & Constants.alternateMask) != 0

        let isLeftKey = (keyCode == Constants.leftOptionKeyCode)
        let isRightKey = (keyCode == Constants.rightOptionKeyCode)
        let isDown: Bool
        if isLeftKey {
            isDown = leftDown || alternateDown
        } else if isRightKey {
            isDown = rightDown || alternateDown
        } else {
            // Another modifier changed; only act if the Option state itself flipped
            // (clears a stuck KeyDown when Option was released while tap was off).
            isDown = alternateDown || leftDown || rightDown
            lock.lock()
            let current = isKeyPressed
            lock.unlock()
            if isDown == current {
                return Unmanaged.passUnretained(event)
            }
        }

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

        return Unmanaged.passUnretained(event)
    }
}
