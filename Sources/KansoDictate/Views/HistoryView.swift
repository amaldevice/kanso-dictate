import SwiftUI
import AppKit
import KansoCore

public struct HistoryView: View {
    @ObservedObject var coordinator: DictationCoordinator

    public init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    private var records: [HistoryRecord] {
        coordinator.historyStore.records
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dictation History")
                    .font(.headline)
                Spacer()
                if !records.isEmpty {
                    Button("Clear All") {
                        coordinator.historyStore.clear()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No dictations yet")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("Hold Right Option to dictate into any text box.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.engineIdentifier)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                            Spacer()
                            Text(record.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", record.durationSeconds))s")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(record.text)
                            .font(.body)
                            .lineLimit(4)
                            .textSelection(.enabled)

                        HStack {
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.text, forType: .string)
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 450)
    }
}
