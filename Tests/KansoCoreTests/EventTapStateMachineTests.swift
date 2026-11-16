import Foundation
import Combine
import KansoCore

@MainActor
func runEventTapStateMachineTests() async {
    testFlagsChangedIgnoredWhenNotRunning()
    testKeyPressStateTransitions()
    testModifierResyncAndStopReset()
    testLifecycleAndPermissionRetry()
    testStartStopRetryRaceInvariants()
    await testHotkeyServiceLiveStateSync()
}

private func makeRunningManager(
    trigger: PTTTriggerKey = .rightOption,
    currentModifierFlags: (@Sendable () -> UInt64)? = nil
) -> EventTapManager {
    let env = EventTapEnvironment(
        isInputMonitoringAllowed: { true },
        isAccessibilityTrusted: { true },
        currentModifierFlags: currentModifierFlags,
        createTap: { _, _ in MockTapSession() },
        scheduleWorker: { work in work() },
        scheduleRetry: { _ in {} }
    )
    let manager = EventTapManager(trigger: trigger, environment: env)
    assert(manager.start(), "Test manager must start")
    assert(manager.lifecycleState == .running, "Test manager must be .running")
    return manager
}

private func testFlagsChangedIgnoredWhenNotRunning() {
    let inputMonitoringGranted = LockedBox(false)
    let pendingWorkers = LockedBox<[@Sendable () -> Void]>([])
    let env = EventTapEnvironment(
        isInputMonitoringAllowed: { inputMonitoringGranted.value },
        isAccessibilityTrusted: { true },
        createTap: { _, _ in MockTapSession() },
        scheduleWorker: { work in pendingWorkers.withLock { $0.append(work) } },
        scheduleRetry: { _ in {} }
    )
    let manager = EventTapManager(trigger: .rightOption, environment: env)
    let keyDownCount = LockedBox(0)
    let keyUpCount = LockedBox(0)
    manager.onKeyDown = { keyDownCount.withLock { $0 += 1 } }
    manager.onKeyUp = { keyUpCount.withLock { $0 += 1 } }

    // 1. .stopped ignores processFlagsChanged
    assert(manager.lifecycleState == .stopped)
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .released, "processFlagsChanged must be ignored when .stopped")
    assert(keyDownCount.value == 0 && keyUpCount.value == 0)

    // 2. .waitingForPermission ignores processFlagsChanged
    assert(!manager.start())
    assert(manager.lifecycleState == .waitingForPermission)
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .released, "processFlagsChanged must be ignored when .waitingForPermission")
    assert(keyDownCount.value == 0 && keyUpCount.value == 0)

    // 3. .starting ignores processFlagsChanged until worker reaches .running
    inputMonitoringGranted.withLock { $0 = true }
    assert(manager.start())
    assert(manager.lifecycleState == .starting)
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .released, "processFlagsChanged must be ignored when .starting")
    assert(keyDownCount.value == 0 && keyUpCount.value == 0)

    // 4. .running accepts, and after stop() ignores stale callbacks
    pendingWorkers.value[0]()
    assert(manager.lifecycleState == .running)
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .pressed)
    assert(keyDownCount.value == 1)

    manager.stop()
    assert(manager.lifecycleState == .stopped)
    assert(manager.keyPressState == .released)
    assert(keyUpCount.value == 1)

    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .released, "Stale processFlagsChanged after stop() must not transition to .pressed")
    assert(keyDownCount.value == 1 && keyUpCount.value == 1)

    print("✔ EventTapManager processFlagsChanged gated on .running verified")
}

private func testKeyPressStateTransitions() {
    // Slice 1: PTTKeyPressState transitions via processFlagsChanged(keyCode:flags:)
    let manager = makeRunningManager(trigger: .rightOption)
    let keyDownCount = LockedBox(0)
    let keyUpCount = LockedBox(0)
    manager.onKeyDown = { keyDownCount.withLock { $0 += 1 } }
    manager.onKeyUp = { keyUpCount.withLock { $0 += 1 } }

    assert(manager.keyPressState == PTTKeyPressState.released, "Initial keyPressState must be .released")

    // Pressing opposite (left) option must be ignored in .rightOption mode
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.leftOptionKeyCode,
        flags: EventTapManager.Constants.leftOptionMask | EventTapManager.Constants.alternateMask
    )
    assert(manager.keyPressState == .released, "Left Option must not press trigger in .rightOption mode")
    assert(keyDownCount.value == 0 && keyUpCount.value == 0, "No callbacks on non-trigger key while released")

    // Pressing right option transitions .released -> .pressed and fires onKeyDown once
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask | EventTapManager.Constants.alternateMask
    )
    assert(manager.keyPressState == .pressed, "Right Option down must transition to .pressed")
    assert(keyDownCount.value == 1, "onKeyDown must fire once on .released -> .pressed")

    // Duplicate down event while already .pressed must not re-fire onKeyDown
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask | EventTapManager.Constants.alternateMask
    )
    assert(manager.keyPressState == .pressed)
    assert(keyDownCount.value == 1, "Duplicate down must not fire onKeyDown again")

    // Releasing right option transitions .pressed -> .released and fires onKeyUp once
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: 0
    )
    assert(manager.keyPressState == .released, "Right Option up must transition to .released")
    assert(keyUpCount.value == 1, "onKeyUp must fire once on .pressed -> .released")

    // Duplicate up event while already .released must not re-fire onKeyUp
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: 0
    )
    assert(keyUpCount.value == 1, "Duplicate up must not fire onKeyUp again")

    // Non-trigger key event when trigger flags are cleared recovers stuck .pressed -> .released
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .pressed)
    manager.processFlagsChanged(keyCode: 0x38, flags: 0) // Shift change with right option flag cleared
    assert(manager.keyPressState == .released, "Non-trigger flagsChanged with trigger cleared must release stuck press")
    assert(keyUpCount.value == 2, "Recovery on non-trigger event must fire onKeyUp")

    // EitherOption mode accepts left or right option
    manager.trigger = .eitherOption
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.leftOptionKeyCode,
        flags: EventTapManager.Constants.leftOptionMask
    )
    assert(manager.keyPressState == .pressed, "EitherOption must accept left Option")
    assert(keyDownCount.value == 3)
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.leftOptionKeyCode,
        flags: 0
    )
    assert(manager.keyPressState == .released)
    assert(keyUpCount.value == 3)

    print("✔ EventTapManager PTTKeyPressState transitions verified")
}

private func testModifierResyncAndStopReset() {
    let liveFlags = LockedBox<UInt64>(0)
    let manager = makeRunningManager(trigger: .rightOption, currentModifierFlags: { liveFlags.value })

    let keyDownCount = LockedBox(0)
    let keyUpCount = LockedBox(0)
    manager.onKeyDown = { keyDownCount.withLock { $0 += 1 } }
    manager.onKeyUp = { keyUpCount.withLock { $0 += 1 } }

    // Resync while released even if option is physically held must not synthesize KeyDown
    liveFlags.withLock { $0 = EventTapManager.Constants.rightOptionMask }
    manager.resyncModifierState()
    assert(manager.keyPressState == .released, "Resync from .released must not synthesize .pressed")
    assert(keyDownCount.value == 0 && keyUpCount.value == 0)

    // Press trigger
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .pressed)
    assert(keyDownCount.value == 1)

    // Resync while trigger is still physically held keeps .pressed
    manager.resyncModifierState()
    assert(manager.keyPressState == .pressed, "Resync while trigger physically down must stay .pressed")
    assert(keyUpCount.value == 0)

    // Resync after trigger was physically released recovers stuck .pressed -> .released and fires onKeyUp
    liveFlags.withLock { $0 = 0 }
    manager.resyncModifierState()
    assert(manager.keyPressState == .released, "Resync when trigger physically up must recover to .released")
    assert(keyUpCount.value == 1, "Resync recovery must fire onKeyUp")

    // Pressing again and calling stop() transitions .pressed -> .released and fires onKeyUp
    manager.processFlagsChanged(
        keyCode: EventTapManager.Constants.rightOptionKeyCode,
        flags: EventTapManager.Constants.rightOptionMask
    )
    assert(manager.keyPressState == .pressed)
    manager.stop()
    assert(manager.keyPressState == .released, "stop() must reset keyPressState to .released")
    assert(keyUpCount.value == 2, "stop() while .pressed must fire onKeyUp")

    // Calling stop() again while already .released must not fire extra onKeyUp
    manager.stop()
    assert(keyUpCount.value == 2, "stop() while .released must not fire onKeyUp")

    print("✔ EventTapManager modifier resync recovery and stop reset verified")
}

private final class MockTapSession: EventTapSession, @unchecked Sendable {
    let lock = NSLock()
    var attachCount = 0
    var runCount = 0
    var reenableCount = 0
    var disableCount = 0
    var stopLoopCount = 0
    var onDisabled: (@Sendable () -> Void)?
    var onFlagsChanged: (@Sendable (Int64, UInt64) -> Void)?

    func attachToCurrentRunLoop() -> @Sendable () -> Void {
        lock.lock()
        attachCount += 1
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.stopLoopCount += 1
            self.lock.unlock()
        }
    }

    func run() {
        lock.lock()
        runCount += 1
        lock.unlock()
    }

    func reenable() {
        lock.lock()
        reenableCount += 1
        lock.unlock()
    }

    func disable() {
        lock.lock()
        disableCount += 1
        lock.unlock()
    }
}

private func testLifecycleAndPermissionRetry() {
    let inputMonitoringGranted = LockedBox(false)
    let accessibilityGranted = LockedBox(false)
    let retryScheduleCount = LockedBox(0)
    let retryCancelCount = LockedBox(0)
    let retryTick = LockedBox<(@Sendable () -> Void)?>(nil)
    let pendingWorkers = LockedBox<[@Sendable () -> Void]>([])
    let createdSessions = LockedBox<[MockTapSession]>([])

    let env = EventTapEnvironment(
        isInputMonitoringAllowed: { inputMonitoringGranted.value },
        isAccessibilityTrusted: { accessibilityGranted.value },
        createTap: { onDisabled, onFlagsChanged in
            let session = MockTapSession()
            session.onDisabled = onDisabled
            session.onFlagsChanged = onFlagsChanged
            createdSessions.withLock { $0.append(session) }
            return session
        },
        scheduleWorker: { work in
            pendingWorkers.withLock { $0.append(work) }
        },
        scheduleRetry: { tick in
            retryScheduleCount.withLock { $0 += 1 }
            retryTick.withLock { $0 = tick }
            return {
                retryCancelCount.withLock { $0 += 1 }
            }
        }
    )

    let manager = EventTapManager(trigger: .rightOption, environment: env)
    let transitions = LockedBox<[EventTapLifecycleState]>([])
    manager.onLifecycleStateChange = { state in
        transitions.withLock { $0.append(state) }
    }

    assert(manager.lifecycleState == .stopped, "Initial lifecycleState must be .stopped")
    assert(!manager.isRunning, "Initial isRunning must be false")

    // Missing permission enters .waitingForPermission and schedules one retry observer
    assert(!manager.start(), "start() must return false when permission is missing")
    assert(manager.lifecycleState == .waitingForPermission)
    assert(!manager.isRunning)
    assert(retryScheduleCount.value == 1, "Retry observer must be scheduled once")
    assert(transitions.value == [.waitingForPermission])

    // Repeated start() while waiting must not schedule duplicate retry observers
    assert(!manager.start())
    assert(manager.lifecycleState == .waitingForPermission)
    assert(retryScheduleCount.value == 1, "Repeated start() while waiting must not duplicate retry observer")
    assert(transitions.value == [.waitingForPermission])

    // Retry tick while permissions still denied keeps waiting
    retryTick.value?()
    assert(manager.lifecycleState == .waitingForPermission)
    assert(createdSessions.value.isEmpty)

    // Grant Input Monitoring + Accessibility and trigger retry tick
    inputMonitoringGranted.withLock { $0 = true }
    accessibilityGranted.withLock { $0 = true }
    retryTick.value?()

    assert(manager.lifecycleState == .starting, "Successful retry must enter .starting before worker executes")
    assert(!manager.isRunning, "isRunning must be false while .starting")
    assert(retryCancelCount.value == 1, "Successful tap creation must cancel retry observer")
    assert(createdSessions.value.count == 1)
    assert(pendingWorkers.value.count == 1)
    assert(transitions.value == [.waitingForPermission, .starting])

    // Worker executes -> transitions .starting -> .running
    pendingWorkers.value[0]()
    assert(manager.lifecycleState == .running)
    assert(manager.isRunning)
    assert(createdSessions.value[0].attachCount == 1)
    assert(createdSessions.value[0].runCount == 1)
    assert(transitions.value == [.waitingForPermission, .starting, .running])

    // stop() -> transitions .running -> .stopped and stops run loop
    manager.stop()
    assert(manager.lifecycleState == .stopped)
    assert(!manager.isRunning)
    assert(createdSessions.value[0].disableCount == 1)
    assert(createdSessions.value[0].stopLoopCount == 1)
    assert(transitions.value == [.waitingForPermission, .starting, .running, .stopped])

    print("✔ EventTapManager lifecycle and permission retry transitions verified")
}

private func testStartStopRetryRaceInvariants() {
    let inputMonitoringGranted = LockedBox(true)
    let accessibilityGranted = LockedBox(true)
    let retryTick = LockedBox<(@Sendable () -> Void)?>(nil)
    let retryCancelCount = LockedBox(0)
    let pendingWorkers = LockedBox<[@Sendable () -> Void]>([])
    let createdSessions = LockedBox<[MockTapSession]>([])
    let tapCreateShouldFail = LockedBox(false)

    let env = EventTapEnvironment(
        isInputMonitoringAllowed: { inputMonitoringGranted.value },
        isAccessibilityTrusted: { accessibilityGranted.value },
        createTap: { onDisabled, onFlagsChanged in
            if tapCreateShouldFail.value { return nil }
            let session = MockTapSession()
            session.onDisabled = onDisabled
            session.onFlagsChanged = onFlagsChanged
            createdSessions.withLock { $0.append(session) }
            return session
        },
        scheduleWorker: { work in
            pendingWorkers.withLock { $0.append(work) }
        },
        scheduleRetry: { tick in
            retryTick.withLock { $0 = tick }
            return {
                retryCancelCount.withLock { $0 += 1 }
            }
        }
    )

    let manager = EventTapManager(trigger: .rightOption, environment: env)

    // 1. Calling start() while .starting or .running is idempotent
    assert(manager.start())
    assert(manager.lifecycleState == .starting)
    assert(manager.start(), "start() while .starting must return true idempotently")
    assert(createdSessions.value.count == 1, "start() while .starting must not create a second session")
    assert(pendingWorkers.value.count == 1)

    // 2. Calling stop() while .starting prevents stale worker from transitioning to .running
    manager.stop()
    assert(manager.lifecycleState == .stopped)
    assert(createdSessions.value[0].disableCount == 1)
    pendingWorkers.value[0]() // Stale worker runs late
    assert(manager.lifecycleState == .stopped, "Stale worker must not transition stopped manager to .running")
    assert(createdSessions.value[0].attachCount == 0, "Stale worker must not attach run loop source")
    assert(createdSessions.value[0].runCount == 0, "Stale worker must not enter CFRunLoopRun")

    // 3. start() -> stop() -> start() before first worker runs: stale worker 1 ignored, worker 2 runs
    assert(manager.start()) // session 1, worker 1
    manager.stop()
    assert(manager.start()) // session 2, worker 2
    assert(createdSessions.value.count == 3)
    assert(pendingWorkers.value.count == 3)

    pendingWorkers.value[1]() // Stale worker 1
    assert(manager.lifecycleState == .starting, "Worker from prior generation must not advance new .starting session")
    assert(createdSessions.value[1].attachCount == 0)

    pendingWorkers.value[2]() // Current worker 2
    assert(manager.lifecycleState == .running)
    assert(createdSessions.value[2].attachCount == 1)

    // Idempotent start() while .running
    assert(manager.start())
    assert(createdSessions.value.count == 3, "start() while .running must be a no-op")

    // 4. tapDisabledByTimeout reenables only while .running
    createdSessions.value[2].onDisabled?()
    assert(createdSessions.value[2].reenableCount == 1, "tapDisabled while .running must reenable active session")

    manager.stop()
    createdSessions.value[2].onDisabled?()
    assert(createdSessions.value[2].reenableCount == 1, "tapDisabled after .stop must not reenable")

    // 5. stop() while .waitingForPermission cancels retry and invalidates captured retry tick
    tapCreateShouldFail.withLock { $0 = true }
    assert(!manager.start())
    assert(manager.lifecycleState == .waitingForPermission)
    manager.stop()
    assert(manager.lifecycleState == .stopped)
    assert(retryCancelCount.value == 1, "stop() while waiting must cancel retry observer")

    // Even if a queued timer tick executes after stop(), it must not restart
    tapCreateShouldFail.withLock { $0 = false }
    retryTick.value?()
    assert(manager.lifecycleState == .stopped, "Stale retry tick after stop() must not restart manager")
    assert(createdSessions.value.count == 3)

    print("✔ EventTapManager concurrent start/stop/retry race invariants verified")
}

@MainActor
private func testHotkeyServiceLiveStateSync() async {
    let inputMonitoringGranted = LockedBox(false)
    let accessibilityGranted = LockedBox(true)
    let retryTick = LockedBox<(@Sendable () -> Void)?>(nil)

    let env = EventTapEnvironment(
        isInputMonitoringAllowed: { inputMonitoringGranted.value },
        isAccessibilityTrusted: { accessibilityGranted.value },
        createTap: { _, _ in MockTapSession() },
        scheduleWorker: { work in
            // Execute worker asynchronously off the main actor like production Thread
            DispatchQueue.global(qos: .userInteractive).async {
                work()
            }
        },
        scheduleRetry: { tick in
            retryTick.withLock { $0 = tick }
            return {}
        }
    )

    let manager = EventTapManager(trigger: .rightOption, environment: env)
    let service = HotkeyService(manager: manager, trigger: .rightOption)

    var observedIsTapRunning: [Bool] = []
    var cancellables = Set<AnyCancellable>()
    service.$isTapRunning
        .sink { observedIsTapRunning.append($0) }
        .store(in: &cancellables)

    assert(service.tapState == .stopped)
    assert(!service.isTapRunning)

    // Initial start fails permission -> waitingForPermission, isTapRunning stays false
    assert(!service.start())
    assert(service.tapState == .waitingForPermission)
    assert(!service.isTapRunning)

    // Grant Input Monitoring and fire retry observer -> HotkeyService updates live to running
    inputMonitoringGranted.withLock { $0 = true }
    retryTick.value?()

    var waitCount = 0
    while waitCount < 50 && !service.isTapRunning {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waitCount += 1
    }

    assert(service.tapState == .running, "HotkeyService tapState must reflect asynchronous retry start")
    assert(service.isTapRunning, "HotkeyService isTapRunning must update to true when retry timer starts tap")
    assert(observedIsTapRunning.last == true, "Published isTapRunning must emit true for MenuBarExtra")

    // setTrigger while running restarts tap and keeps it running
    let suite = "test.hotkey.service.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    service.setTrigger(.leftOption, defaults: defaults)
    waitCount = 0
    while waitCount < 50 && !service.isTapRunning {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waitCount += 1
    }
    assert(service.trigger == .leftOption)
    assert(manager.trigger == .leftOption)
    assert(service.tapState == .running)
    assert(service.isTapRunning)
    defaults.removePersistentDomain(forName: suite)

    manager.stop()
    waitCount = 0
    while waitCount < 50 && service.isTapRunning {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waitCount += 1
    }
    assert(service.tapState == .stopped)
    assert(!service.isTapRunning)

    print("✔ HotkeyService live tap-running state synchronization verified")
}
