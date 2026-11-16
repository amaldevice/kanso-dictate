import AppKit
import SwiftUI
import Combine
import KansoCore

/// Controls the lifecycle and positioning of the floating dictation pill HUD.
@MainActor
public final class FloatingHUDController: ObservableObject {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private let coordinator: DictationCoordinator
    private var stateMachine = HUDPresentationStateMachine()
    private var errorDismissTask: Task<Void, Never>?
    private let errorDismissDuration: Duration = .seconds(3)

    public init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        setupPanel()
        bindCoordinator()
    }

    private func setupPanel() {
        let hudView = FloatingHUDView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: hudView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    private func bindCoordinator() {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleEvent(.dictationStateChanged(state))
            }
            .store(in: &cancellables)
    }

    private func handleEvent(_ event: HUDPresentationEvent) {
        for action in stateMachine.handle(event) {
            execute(action)
        }
    }

    private func execute(_ action: HUDPresentationAction) {
        guard let panel = panel else { return }

        switch action {
        case .cancelErrorDismiss:
            errorDismissTask?.cancel()
            errorDismissTask = nil

        case .showPanel(let fadeIn):
            repositionPanel()
            let startAlpha: CGFloat = fadeIn ? 0.0 : panel.alphaValue
            // Cancel any in-flight fade-out animation before ordering front and fading in.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.animator().alphaValue = startAlpha
            }
            panel.alphaValue = startAlpha
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1.0
            }

        case .scheduleErrorDismiss(let generation):
            errorDismissTask?.cancel()
            let delay = errorDismissDuration
            errorDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.handleEvent(.errorTimeoutFired(generation: generation))
            }

        case .beginFadeOut(let generation):
            guard panel.isVisible else {
                handleEvent(.fadeOutCompleted(generation: generation))
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleEvent(.fadeOutCompleted(generation: generation))
                }
            })

        case .hidePanel:
            panel.orderOut(nil)
        }
    }

    private func repositionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let panelWidth: CGFloat = 200
        let panelHeight: CGFloat = 46

        let x = screenRect.origin.x + (screenRect.width - panelWidth) / 2.0
        let y = screenRect.origin.y + 80 // Position 80pt above dock/bottom

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}
