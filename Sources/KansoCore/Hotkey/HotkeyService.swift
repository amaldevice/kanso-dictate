import Foundation
import Combine

/// Main-actor observable bridge between `EventTapManager` and `DictationCoordinator` / SwiftUI.
@MainActor
public final class HotkeyService: ObservableObject {
    public let manager: EventTapManager
    @Published public private(set) var tapState: EventTapLifecycleState
    @Published public private(set) var isTapRunning: Bool
    @Published public private(set) var trigger: PTTTriggerKey
    private weak var coordinator: DictationCoordinator?

    public init(
        manager: EventTapManager = EventTapManager(),
        trigger: PTTTriggerKey = PTTTriggerKey.load()
    ) {
        self.manager = manager
        self.trigger = trigger
        self.tapState = manager.lifecycleState
        self.isTapRunning = (manager.lifecycleState == .running)
        manager.trigger = trigger
        manager.onLifecycleStateChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncState()
            }
        }
    }

    public func attach(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        manager.onKeyDown = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.startDictation()
            }
        }
        manager.onKeyUp = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.stopDictation()
            }
        }
    }

    @discardableResult
    public func start() -> Bool {
        manager.trigger = trigger
        manager.resyncModifierState()
        let started = manager.start()
        syncState()
        return started
    }

    /// Stops and recreates the tap (use after granting permissions or ad-hoc re-sign).
    @discardableResult
    public func restart() -> Bool {
        manager.stop()
        syncState()
        return start()
    }

    public func resync() {
        manager.resyncModifierState()
    }

    /// Applies a new trigger (from Settings) and restarts the tap if active so the change takes effect immediately.
    public func setTrigger(_ newTrigger: PTTTriggerKey, defaults: UserDefaults = .standard) {
        trigger = newTrigger
        newTrigger.save(defaults: defaults)
        manager.trigger = newTrigger
        manager.resyncModifierState()
        if manager.lifecycleState == .running || manager.lifecycleState == .starting {
            restart()
        }
    }

    private func syncState() {
        let current = manager.lifecycleState
        if tapState != current {
            tapState = current
        }
        let running = (current == .running)
        if isTapRunning != running {
            isTapRunning = running
        }
    }
}
