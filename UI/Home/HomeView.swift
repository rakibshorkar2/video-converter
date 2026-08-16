import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

private struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileName = received.file.lastPathComponent
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + fileName)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var photosItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var settingsJob: ConversionJob?
    @State private var errorMessage: String?

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
                            showingFileImporter = true
                        } label: {
                            Label(L10n.addFromFiles, systemImage: "folder")
                        }
                    } label: {
                        Label(L10n.addVideo, systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .dropDestination(for: URL.self) { urls, _ in
                handleDroppedURLs(urls)
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
        }
    }

    private func importPhotosItems(_ items: [PhotosPickerItem]) async {
        var lastJob: ConversionJob?
        for item in items {
            let movie: Movie?
            do {
                movie = try await item.loadTransferable(type: Movie.self)
            } catch {
                errorMessage = error.localizedDescription
                continue
            }
            guard let movie else { continue }
            do {
                let job = try await container.queue.importURL(movie.url, fileName: movie.url.lastPathComponent)
                lastJob = job
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if let lastJob {
            settingsJob = lastJob
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            handleDroppedURLs(urls)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        Task {
            var lastJob: ConversionJob?
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let job = try await container.queue.importURL(url, fileName: url.lastPathComponent)
                    lastJob = job
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            if let lastJob {
                settingsJob = lastJob
            }
        }
    }
}