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
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: DictationState) {
        guard let panel = panel else { return }

        switch state {
        case .recording, .transcribing, .inserting:
            repositionPanel()
            if !panel.isVisible {
                panel.alphaValue = 0.0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panel.animator().alphaValue = 1.0
                }
            }

        case .error:
            repositionPanel()
            panel.orderFrontRegardless()
            // Auto dismiss error after 3 seconds if not cleared
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if case .error = self?.coordinator.state {
                    self?.dismissPanel()
                }
            }

        case .idle:
            dismissPanel()
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

    private func dismissPanel() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            DispatchQueue.main.async {
                panel.orderOut(nil)
            }
        })
    }
}
