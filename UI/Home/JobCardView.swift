import SwiftUI

struct JobCardView: View {
    @Environment(AppContainer.self) private var container
    let job: ConversionJob
    let onEdit: () -> Void

    @State private var showingPreview = false
    @State private var showingDocuments = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(url: job.sourceURL)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.sourceName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(status: job.status)
                }

                if isActive {
                    ProgressView(value: job.fraction)
                        .progressViewStyle(.linear)
                    if job.fraction > 0 {
                        Text(progressLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let error = job.errorMessage, job.status == .failed || job.status == .cancelled || job.status == .interrupted {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }

                if let details = job.technicalDetails, job.status == .failed {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                actionButtons
            }
        }
        .padding(.vertical, 4)
        .fullScreenCover(isPresented: $showingPreview) {
            if let url = job.outputURL ?? job.sourceURL {
                ZStack {
                    Color.black.ignoresSafeArea()
                    PlayerView(url: url)
                        .ignoresSafeArea()
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                showingPreview = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding()
                        }
                        Spacer()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingDocuments) {
            if let url = job.outputURL {
                DocumentOptionsPresenter(url: url)
                    .ignoresSafeArea()
                    .background(Color.black.opacity(0.001))
            }
        }
    }

    private var isActive: Bool {
        switch job.status {
        case .analyzing, .preparing, .converting, .finalizing, .saving:
            return true
        default:
            return false
        }
    }

    private var progressLine: String {
        var parts: [String] = [job.stage?.displayName ?? ""]
        if job.fraction > 0 {
            parts.append("\(Int((job.fraction * 100).rounded()))%")
        }
        if let speed = job.speed, speed > 0 {
            parts.append(String(format: "%.1f×", speed))
        }
        if let eta = job.eta, eta > 0, eta.isFinite {
            parts.append("ETA \(job.etaText)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let metadata = job.metadata {
            parts.append(metadata.durationString)
            parts.append(metadata.resolutionString)
        }
        let containerName = job.configuration.outputContainer.displayName
        if job.configuration.streamCopy {
            parts.append("\(containerName) · \(L10n.engineStreamCopy)")
        } else {
            parts.append("\(containerName) · \(job.configuration.videoCodec.displayName)")
        }
        if let engine = job.engine, job.status == .completed {
            parts.append(engine.displayName)
        }
        if job.outputSize > 0 {
            parts.append(L10n.outputSizeLabel.replacingOccurrences(of: "%@", with: ByteFormatter.string(from: job.outputSize)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if job.canConfigure {
                Button {
                    onEdit()
                } label: {
                    Label(L10n.editButton, systemImage: "slider.horizontal.3")
                }
                .font(.caption)
            }

            if job.canCancel {
                Button(role: .destructive) {
                    container.queue.cancel(job)
                } label: {
                    Label(L10n.cancelButton, systemImage: "xmark")
                }
                .font(.caption)
            }

            if job.canRetry {
                Button {
                    container.queue.retry(job)
                } label: {
                    Label(L10n.retryButton, systemImage: "arrow.clockwise")
                }
                .font(.caption)
            }

            if job.status == .completed, let url = job.outputURL {
                Button {
                    showingPreview = true
                } label: {
                    Label(L10n.previewButton, systemImage: "play.circle")
                }
                .font(.caption)

                ShareLink(item: url) {
                    Label(L10n.shareButton, systemImage: "square.and.arrow.up")
                }
                .font(.caption)

                Button {
                    showingDocuments = true
                } label: {
                    Label(L10n.showInFiles, systemImage: "folder")
                }
                .font(.caption)
            }

            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
    }
}