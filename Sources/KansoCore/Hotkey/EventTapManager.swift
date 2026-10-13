import Foundation
import CoreGraphics
import ApplicationServices

/// Manages global modifier hotkey detection for Push-To-Talk via CGEventTap.
public final class EventTapManager: @unchecked Sendable {
    public enum Constants {
        public static let rightOptionKeyCode: Int64 = 0x3D // 61 decimal
        public static let rightOptionMask: UInt64 = 0x0020_0000 // NX_DEVICERALTKEYMASK
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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

    /// Starts listening for Right Option modifier transitions.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let observerPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
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
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Stops the active event tap and removes it from the run loop.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

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

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout, let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == Constants.rightOptionKeyCode {
            let flags = event.flags.rawValue
            let isDown = (flags & Constants.rightOptionMask) != 0

            lock.lock()
            let previousState = isKeyPressed
            isKeyPressed = isDown
            lock.unlock()

            if isDown && !previousState {
                onKeyDown?()
            } else if !isDown && previousState {
                onKeyUp?()
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
