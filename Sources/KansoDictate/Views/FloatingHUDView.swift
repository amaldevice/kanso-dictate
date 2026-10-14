import SwiftUI
import KansoCore

/// A floating visual pill HUD displaying real-time dictation state and status.
public struct FloatingHUDView: View {
    @ObservedObject var coordinator: DictationCoordinator

    public init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 12) {
            statusIcon
            statusLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3, height: 8)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3, height: 16)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3, height: 12)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3, height: 6)
            }
            .frame(width: 22, height: 20)

        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 20)

        case .inserting:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 22, height: 20)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 22, height: 20)

        case .idle:
            Image(systemName: "mic.fill")
                .foregroundColor(.secondary)
                .frame(width: 22, height: 20)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.state {
        case .recording:
            Text(coordinator.isLockedRecording ? "Listening (Tap ⌥ to stop)" : "Listening...")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        case .transcribing:
            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.primary)

        case .inserting:
            Text("Pasting text...")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.primary)

        case .error(let msg):
            Text(msg.count > 25 ? "\(msg.prefix(25))..." : msg)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)

        case .idle:
            Text("Ready")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}
