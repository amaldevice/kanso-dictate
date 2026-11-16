import Foundation
import CoreGraphics
import ApplicationServices

/// Explicit lifecycle state of the global CGEventTap and its permission-retry observer.
public enum EventTapLifecycleState: String, Sendable, Equatable {
    case stopped
    case waitingForPermission
    case starting
    case running
}

/// Explicit physical key-press state for the configured Push-To-Talk trigger.
public enum PTTKeyPressState: String, Sendable, Equatable {
    case released
    case pressed
}

/// Abstraction over a created event tap and its run-loop lifecycle.
public protocol EventTapSession: AnyObject, Sendable {
    /// Attaches the tap source to the current thread's run loop and enables the tap.
    /// Returns a closure that detaches and stops that run loop when invoked.
    func attachToCurrentRunLoop() -> @Sendable () -> Void
    /// Runs the tap's run loop until stopped.
    func run()
    /// Re-enables the tap after OS timeout/user-input disablement.
    func reenable()
    /// Disables and invalidates the tap during shutdown.
    func disable()
}

private struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class TapCallbackBox: @unchecked Sendable {
    let onDisabled: @Sendable () -> Void
    let onFlagsChanged: @Sendable (Int64, UInt64) -> Void
    weak var session: LiveEventTapSession?

    init(
        onDisabled: @escaping @Sendable () -> Void,
        onFlagsChanged: @escaping @Sendable (Int64, UInt64) -> Void
    ) {
        self.onDisabled = onDisabled
        self.onFlagsChanged = onFlagsChanged
    }
}

private final class LiveEventTapSession: EventTapSession, @unchecked Sendable {
    private let machPort: CFMachPort
    private let source: CFRunLoopSource
    private let callbackBox: TapCallbackBox

    init?(
        onDisabled: @escaping @Sendable () -> Void,
        onFlagsChanged: @escaping @Sendable (Int64, UInt64) -> Void
    ) {
        let box = TapCallbackBox(onDisabled: onDisabled, onFlagsChanged: onFlagsChanged)
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let callbackBox = Unmanaged<TapCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    callbackBox.onDisabled()
                    return Unmanaged.passUnretained(event)
                }
                if type == .flagsChanged {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let rawFlags = event.flags.rawValue
                    callbackBox.onFlagsChanged(keyCode, rawFlags)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }

        self.machPort = tap
        self.source = source
        self.callbackBox = box
        box.session = self
    }

    func attachToCurrentRunLoop() -> @Sendable () -> Void {
        let loopBox = SendableBox(value: CFRunLoopGetCurrent())
        let sourceBox = SendableBox(value: source)
        if let loop = loopBox.value {
            CFRunLoopAddSource(loop, sourceBox.value, .commonModes)
        }
        CGEvent.tapEnable(tap: machPort, enable: true)
        return {
            if let loop = loopBox.value {
                CFRunLoopRemoveSource(loop, sourceBox.value, .commonModes)
                CFRunLoopStop(loop)
            }
        }
    }

    func run() {
        CFRunLoopRun()
    }

    func reenable() {
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func disable() {
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFMachPortInvalidate(machPort)
    }
}

/// Injectable OS dependencies for `EventTapManager`.
public struct EventTapEnvironment: Sendable {
    public var isInputMonitoringAllowed: @Sendable () -> Bool
    public var isAccessibilityTrusted: @Sendable () -> Bool
    public var currentModifierFlags: @Sendable () -> UInt64
    public var createTap: @Sendable (
        @escaping @Sendable () -> Void,
        @escaping @Sendable (Int64, UInt64) -> Void
    ) -> (any EventTapSession)?
    public var scheduleWorker: @Sendable (@escaping @Sendable () -> Void) -> Void
    public var scheduleRetry: @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    public init(
        isInputMonitoringAllowed: (@Sendable () -> Bool)? = nil,
        isAccessibilityTrusted: (@Sendable () -> Bool)? = nil,
        currentModifierFlags: (@Sendable () -> UInt64)? = nil,
        createTap: (@Sendable (
            @escaping @Sendable () -> Void,
            @escaping @Sendable (Int64, UInt64) -> Void
        ) -> (any EventTapSession)?)? = nil,
        scheduleWorker: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
        scheduleRetry: (@Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void))? = nil
    ) {
        self.isInputMonitoringAllowed = isInputMonitoringAllowed ?? {
            CGPreflightListenEventAccess()
        }
        self.isAccessibilityTrusted = isAccessibilityTrusted ?? {
            EventTapManager.isAccessibilityTrusted(prompt: false)
        }
        self.currentModifierFlags = currentModifierFlags ?? {
            CGEventSource.flagsState(.combinedSessionState).rawValue
        }
        self.createTap = createTap ?? { onDisabled, onFlagsChanged in
            LiveEventTapSession(onDisabled: onDisabled, onFlagsChanged: onFlagsChanged)
        }
        self.scheduleWorker = scheduleWorker ?? { work in
            let worker = Thread {
                work()
            }
            worker.name = "dev.kanso-dictate.eventtap"
            worker.qualityOfService = .userInteractive
            worker.start()
        }
        self.scheduleRetry = scheduleRetry ?? { tick in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
            timer.setEventHandler(handler: tick)
            timer.resume()
            return {
                timer.cancel()
            }
        }
    }

    public static let live = EventTapEnvironment()
}

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

    private let lock = NSLock()
    private let environment: EventTapEnvironment
    private var _lifecycleState: EventTapLifecycleState = .stopped
    private var _keyPressState: PTTKeyPressState = .released
    private var _trigger: PTTTriggerKey = PTTTriggerKey.load()
    private var generation: UInt64 = 0
    private var activeSession: (any EventTapSession)?
    private var stopRunLoop: (@Sendable () -> Void)?
    private var cancelRetry: (@Sendable () -> Void)?
    private var _onKeyDown: (@Sendable () -> Void)?
    private var _onKeyUp: (@Sendable () -> Void)?
    private var _onLifecycleStateChange: (@Sendable (EventTapLifecycleState) -> Void)?

    public var lifecycleState: EventTapLifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return _lifecycleState
    }

    public var isRunning: Bool {
        lifecycleState == .running
    }

    public var keyPressState: PTTKeyPressState {
        lock.lock()
        defer { lock.unlock() }
        return _keyPressState
    }

    public var onKeyDown: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onKeyDown
        }
        set {
            lock.lock()
            _onKeyDown = newValue
            lock.unlock()
        }
    }

    public var onKeyUp: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onKeyUp
        }
        set {
            lock.lock()
            _onKeyUp = newValue
            lock.unlock()
        }
    }

    public var onLifecycleStateChange: (@Sendable (EventTapLifecycleState) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onLifecycleStateChange
        }
        set {
            lock.lock()
            _onLifecycleStateChange = newValue
            lock.unlock()
        }
    }

    /// Which physical Option key triggers Push-To-Talk. Single-side modes use the
    /// device-dependent mask only, so the other side is fully ignored.
    public var trigger: PTTTriggerKey {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _trigger
        }
        set {
            lock.lock()
            _trigger = newValue
            lock.unlock()
        }
    }

    public init(
        trigger: PTTTriggerKey? = nil,
        environment: EventTapEnvironment = .live
    ) {
        self.environment = environment
        if let trigger { self._trigger = trigger }
    }

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
    /// If permission is not yet granted, transitions to `.waitingForPermission` and schedules a retry observer.
    @discardableResult
    public func start() -> Bool {
        startInternal(expectedWaitingGeneration: nil)
    }

    /// Stops the active event tap, cancels any permission retry observer, and resets key state.
    public func stop() {
        lock.lock()
        generation &+= 1
        let cancel = cancelRetry
        cancelRetry = nil
        let session = activeSession
        activeSession = nil
        let stopLoop = stopRunLoop
        stopRunLoop = nil
        let wasPressed = (_keyPressState == .pressed)
        _keyPressState = .released
        let stateChanged = (_lifecycleState != .stopped)
        _lifecycleState = .stopped
        let observer = _onLifecycleStateChange
        let keyUpCallback = wasPressed ? _onKeyUp : nil
        lock.unlock()

        cancel?()
        session?.disable()
        stopLoop?()
        keyUpCallback?()
        if stateChanged {
            observer?(.stopped)
        }
    }

    /// Re-reads live modifier state; drops a stuck KeyDown when the trigger was released while tap was disabled.
    public func resyncModifierState() {
        let optionDown = isTriggerDown(flags: environment.currentModifierFlags(), trigger: trigger)
        lock.lock()
        let wasDown = (_keyPressState == .pressed)
        if wasDown, !optionDown {
            _keyPressState = .released
        }
        let keyUpCallback = (wasDown && !optionDown) ? _onKeyUp : nil
        lock.unlock()
        keyUpCallback?()
    }

    /// Re-enables the active tap if it was disabled by OS timeout or user input.
    public func processTapDisabled() {
        lock.lock()
        let session = (_lifecycleState == .running) ? activeSession : nil
        lock.unlock()
        session?.reenable()
    }

    /// Processes a modifier flags-changed event and transitions `keyPressState` accordingly.
    public func processFlagsChanged(keyCode: Int64, flags rawFlags: UInt64) {
        let activeTrigger = trigger
        let isLeftKey = (keyCode == Constants.leftOptionKeyCode)
        let isRightKey = (keyCode == Constants.rightOptionKeyCode)
        let isTriggerKey: Bool
        switch activeTrigger {
        case .rightOption:
            isTriggerKey = isRightKey
        case .leftOption:
            isTriggerKey = isLeftKey
        case .eitherOption:
            isTriggerKey = isLeftKey || isRightKey
        }
        guard isTriggerKey else {
            // Another key changed (incl. the non-trigger Option side): only clear
            // a stuck KeyDown if the trigger itself is physically up.
            let triggerDown = isTriggerDown(flags: rawFlags, trigger: activeTrigger)
            lock.lock()
            let wasPressed = (_keyPressState == .pressed)
            if wasPressed, !triggerDown { _keyPressState = .released }
            let keyUpCallback = (wasPressed && !triggerDown) ? _onKeyUp : nil
            lock.unlock()
            if keyUpCallback != nil {
                NSLog("KansoDictate: trigger released while tap was off (keyCode: %lld)", keyCode)
            }
            keyUpCallback?()
            return
        }

        let isDown = isTriggerDown(flags: rawFlags, trigger: activeTrigger)
        let nextState: PTTKeyPressState = isDown ? .pressed : .released

        lock.lock()
        let previousState = _keyPressState
        _keyPressState = nextState
        let keyDownCallback = (nextState == .pressed && previousState == .released) ? _onKeyDown : nil
        let keyUpCallback = (nextState == .released && previousState == .pressed) ? _onKeyUp : nil
        lock.unlock()

        if let keyDownCallback {
            NSLog("KansoDictate: PTT KeyDown detected (%@, keyCode: %lld)", activeTrigger.rawValue, keyCode)
            keyDownCallback()
        } else if let keyUpCallback {
            NSLog("KansoDictate: PTT KeyUp detected (%@, keyCode: %lld)", activeTrigger.rawValue, keyCode)
            keyUpCallback()
        }
    }

    private func startInternal(expectedWaitingGeneration: UInt64?) -> Bool {
        lock.lock()
        if let expectedWaitingGeneration {
            guard _lifecycleState == .waitingForPermission, generation == expectedWaitingGeneration else {
                lock.unlock()
                return false
            }
        } else if _lifecycleState == .running || _lifecycleState == .starting {
            lock.unlock()
            return true
        }

        guard environment.isInputMonitoringAllowed() else {
            NSLog("KansoDictate: Input Monitoring permission not granted; waiting for approval.")
            let (changed, observer) = enterWaitingForPermissionLocked()
            lock.unlock()
            if changed {
                observer?(.waitingForPermission)
            }
            return false
        }

        guard let session = environment.createTap(
            { [weak self] in self?.processTapDisabled() },
            { [weak self] keyCode, flags in self?.processFlagsChanged(keyCode: keyCode, flags: flags) }
        ) else {
            NSLog("KansoDictate: CGEvent.tapCreate returned nil; retrying permission check.")
            let (changed, observer) = enterWaitingForPermissionLocked()
            lock.unlock()
            if changed {
                observer?(.waitingForPermission)
            }
            return false
        }

        let cancel = cancelRetry
        cancelRetry = nil
        generation &+= 1
        let workerGeneration = generation
        activeSession = session
        stopRunLoop = nil
        let changed = (_lifecycleState != .starting)
        _lifecycleState = .starting
        let observer = _onLifecycleStateChange
        lock.unlock()

        cancel?()
        if changed {
            observer?(.starting)
        }

        environment.scheduleWorker { [weak self] in
            self?.runWorker(session: session, generation: workerGeneration)
        }

        NSLog("KansoDictate: Global hotkey event tap established successfully.")
        return true
    }

    private func enterWaitingForPermissionLocked() -> (Bool, (@Sendable (EventTapLifecycleState) -> Void)?) {
        let changed = (_lifecycleState != .waitingForPermission)
        _lifecycleState = .waitingForPermission
        if cancelRetry == nil {
            let waitingGeneration = generation
            cancelRetry = environment.scheduleRetry { [weak self] in
                self?.retryPermissionCheck(expectedGeneration: waitingGeneration)
            }
        }
        return (changed, _onLifecycleStateChange)
    }

    private func retryPermissionCheck(expectedGeneration: UInt64) {
        lock.lock()
        let stillWaiting = (_lifecycleState == .waitingForPermission && generation == expectedGeneration)
        lock.unlock()
        guard stillWaiting else { return }

        guard environment.isInputMonitoringAllowed() && environment.isAccessibilityTrusted() else {
            return
        }
        _ = startInternal(expectedWaitingGeneration: expectedGeneration)
    }

    private func runWorker(session: any EventTapSession, generation expectedGeneration: UInt64) {
        lock.lock()
        guard _lifecycleState == .starting,
              generation == expectedGeneration,
              activeSession === session else {
            lock.unlock()
            session.disable()
            return
        }

        let stopLoop = session.attachToCurrentRunLoop()
        stopRunLoop = stopLoop
        let changed = (_lifecycleState != .running)
        _lifecycleState = .running
        let observer = _onLifecycleStateChange
        lock.unlock()

        if changed {
            observer?(.running)
        }
        session.run()
    }

    /// Physical state of the configured trigger. Single-side modes read ONLY the
    /// device mask (0x40 right / 0x20 left) so the opposite Option never triggers.
    /// Either-mode accepts either device mask (plus maskAlternate as fallback).
    private func isTriggerDown(flags: UInt64, trigger: PTTTriggerKey) -> Bool {
        let leftDown = (flags & Constants.leftOptionMask) != 0
        let rightDown = (flags & Constants.rightOptionMask) != 0
        switch trigger {
        case .rightOption:
            return rightDown
        case .leftOption:
            return leftDown
        case .eitherOption:
            return leftDown || rightDown || (flags & Constants.alternateMask) != 0
        }
    }
}
