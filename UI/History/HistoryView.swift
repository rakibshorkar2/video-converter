import SwiftUI

struct HistoryView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            Group {
                if container.history.entries.isEmpty {
                    EmptyStateView(title: L10n.historyTitle, message: L10n.historyEmpty, systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(container.history.entries) { entry in
                            HistoryRowView(entry: entry)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                container.history.remove(container.history.entries[index])
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.historyTitle)
            .toolbar {
                if !container.history.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.clearHistory, role: .destructive) {
                            container.history.clear()
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.status == .completed ? .green : .red)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(entry.inputFormat) → \(entry.outputFormat)\(entry.streamCopy ? " · \(L10n.engineStreamCopy)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(entry.durationString) · \(entry.inputSizeString) → \(entry.outputSizeString)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if entry.status == .completed, let url = entry.outputURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}