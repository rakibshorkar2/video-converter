import SwiftUI

struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var name: String {
        switch status {
        case .queued: return L10n.statusQueued
        case .analyzing: return L10n.statusAnalyzing
        case .preparing: return L10n.statusPreparing
        case .converting: return L10n.statusConverting
        case .finalizing: return L10n.statusFinalizing
        case .saving: return L10n.statusSaving
        case .completed: return L10n.statusCompleted
        case .failed: return L10n.statusFailed
        case .cancelled: return L10n.statusCancelled
        case .interrupted: return L10n.statusInterrupted
        case .waitingForResources: return L10n.statusWaiting
        }
    }

    private var color: Color {
        switch status {
        case .queued: return .secondary
        case .analyzing, .preparing: return .blue
        case .converting, .finalizing, .saving: return .indigo
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .interrupted, .waitingForResources: return .orange
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ThumbnailView: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            guard let url else { return }
            image = await ThumbnailGenerator.thumbnail(for: url, maxSize: 240)
        }
    }
}

struct PickerRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var disabled: Bool = false
    var help: String? = nil

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedLabel)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(disabled)
        }
    }

    private var selectedLabel: String {
        options.first { $0.1 == selection }?.0 ?? ""
    }
}