import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var photosItems: [PhotosPickerItem] = []
    @State private var showingDocumentPicker = false
    @State private var settingsJob: ConversionJob?
    @State private var errorMessage: String?
    @State private var importingCurrent = 0
    @State private var importingTotal = 0

    private var isImporting: Bool { importingTotal > 0 }

    var body: some View {
        NavigationStack {
            Group {
                if container.queue.jobs.isEmpty {
                    EmptyStateView(title: L10n.emptyTitle, message: L10n.emptyMessage, systemImage: "film.stack")
                } else {
                    List {
                        Section {
                            ForEach(container.queue.jobs) { job in
                                JobCardView(job: job) {
                                    settingsJob = job
                                }
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    container.queue.removeJob(container.queue.jobs[index])
                                }
                            }
                        } header: {
                            Text(L10n.queueTitle)
                        } footer: {
                            Text(L10n.privacyNote)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.appName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PhotosPicker(
                            selection: $photosItems,
                            maxSelectionCount: 20,
                            matching: .videos
                        ) {
                            Label(L10n.addFromPhotos, systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label(L10n.addFromFiles, systemImage: "folder")
                        }
                    } label: {
                        Label(L10n.addVideo, systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(
                    contentTypes: DocumentPicker.videoContentTypes,
                    allowsMultipleSelection: true,
                    onPicked: { urls in
                        showingDocumentPicker = false
                        Task { await importURLs(urls, source: .files) }
                    },
                    onCancel: {
                        showingDocumentPicker = false
                    }
                )
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await importURLs(urls, source: .dragAndDrop) }
                return true
            }
            .sheet(item: $settingsJob) { job in
                ConversionSettingsView(job: job)
            }
            .alert("Import Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: photosItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    await importPhotosItems(newItems)
                    photosItems = []
                }
            }
            .onChange(of: container.incomingImportError) { _, newValue in
                guard let newValue else { return }
                errorMessage = newValue
                container.clearIncomingImportError()
            }
            .overlay(alignment: .top) {
                if isImporting {
                    importBanner
                }
            }
        }
    }

    private var importBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(importingTotal > 1
                 ? String(format: L10n.importingProgress, importingCurrent, importingTotal)
                 : L10n.importingVideo)
                .font(.footnote)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 6)
        .transition(.opacity)
    }

    private func importPhotosItems(_ items: [PhotosPickerItem]) async {
        importingTotal = items.count
        var lastJob: ConversionJob?
        for (index, item) in items.enumerated() {
            importingCurrent = index + 1
            do {
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) })
                    ?? item.supportedContentTypes.first(where: { $0.conforms(to: .audiovisualContent) })
                    ?? UTType.movie
                let (tempURL, tempFilename) = try await item.loadFileRepresentation(forTypeIdentifier: type.identifier)
                let job = try await container.importMedia(from: tempURL, fileName: tempFilename, source: .photos)
                lastJob = job
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        importingTotal = 0
        importingCurrent = 0
        if let lastJob {
            settingsJob = lastJob
        }
    }

    private func importURLs(_ urls: [URL], source: MediaImportSource) async {
        importingTotal = urls.count
        var lastJob: ConversionJob?
        for (index, url) in urls.enumerated() {
            importingCurrent = index + 1
            do {
                let job = try await container.importMedia(from: url, fileName: url.lastPathComponent, source: source)
                lastJob = job
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        importingTotal = 0
        importingCurrent = 0
        if let lastJob {
            settingsJob = lastJob
        }
    }
}