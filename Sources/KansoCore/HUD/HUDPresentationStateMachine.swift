import Foundation

/// Explicit presentation lifecycle states for the floating dictation HUD.
public enum HUDPresentationState: Sendable, Equatable {
    case hidden
    case showing
    case errorCountdown
    case dismissing
}

/// Inputs processed by `HUDPresentationStateMachine`.
public enum HUDPresentationEvent: Sendable, Equatable {
    case dictationStateChanged(DictationState)
    case errorTimeoutFired(generation: UInt64)
    case fadeOutCompleted(generation: UInt64)
}

/// Side-effect commands emitted by `HUDPresentationStateMachine`.
public enum HUDPresentationAction: Sendable, Equatable {
    case cancelErrorDismiss
    case showPanel(fadeIn: Bool)
    case scheduleErrorDismiss(generation: UInt64)
    case beginFadeOut(generation: UInt64)
    case hidePanel
}

/// Pure, deterministic state machine governing floating HUD visibility,
/// fade-out transitions, and error auto-dismiss cancellation.
public struct HUDPresentationStateMachine: Sendable {
    public private(set) var state: HUDPresentationState = .hidden
    private var generation: UInt64 = 0

    public init() {}

    /// Advances the state machine for `event` and returns ordered side-effect actions.
    public mutating func handle(_ event: HUDPresentationEvent) -> [HUDPresentationAction] {
        switch event {
        case .dictationStateChanged(let dictationState):
            return handleDictationState(dictationState)

        case .errorTimeoutFired(let token):
            guard state == .errorCountdown, token == generation else {
                return []
            }
            generation &+= 1
            state = .dismissing
            return [.beginFadeOut(generation: generation)]

        case .fadeOutCompleted(let token):
            guard state == .dismissing, token == generation else {
                return []
            }
            state = .hidden
            return [.hidePanel]
        }
    }

    private mutating func handleDictationState(_ dictationState: DictationState) -> [HUDPresentationAction] {
        switch dictationState {
        case .recording, .transcribing, .inserting:
            switch state {
            case .hidden:
                generation &+= 1
                state = .showing
                return [.showPanel(fadeIn: true)]
            case .showing:
                return [.showPanel(fadeIn: false)]
            case .dismissing:
                generation &+= 1
                state = .showing
                return [.showPanel(fadeIn: false)]
            case .errorCountdown:
                generation &+= 1
                state = .showing
                return [.cancelErrorDismiss, .showPanel(fadeIn: false)]
            }

        case .idle:
            switch state {
            case .hidden, .dismissing:
                return []
            case .showing:
                generation &+= 1
                state = .dismissing
                return [.beginFadeOut(generation: generation)]
            case .errorCountdown:
                generation &+= 1
                state = .dismissing
                return [.cancelErrorDismiss, .beginFadeOut(generation: generation)]
            }

        case .error:
            let wasCountdown = (state == .errorCountdown)
            let fadeIn = (state == .hidden)
            generation &+= 1
            state = .errorCountdown
            var actions: [HUDPresentationAction] = []
            if wasCountdown {
                actions.append(.cancelErrorDismiss)
            }
            actions.append(.showPanel(fadeIn: fadeIn))
            actions.append(.scheduleErrorDismiss(generation: generation))
            return actions
        }
    }
}
