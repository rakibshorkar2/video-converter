import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    let settings: AppSettings
    let thermal: ThermalMonitor
    let capabilities: DeviceCapabilityManager
    let diagnostics: DiagnosticsLogger
    let history: HistoryStore
    let queue: ConversionQueueManager
    let importService: MediaImportService

    private(set) var incomingImportError: String?

    init() {
        let settings = AppSettings()
        let thermal = ThermalMonitor()
        let capabilities = DeviceCapabilityManager()
        let diagnostics = DiagnosticsLogger()
        let history = HistoryStore()
        self.settings = settings
        self.thermal = thermal
        self.capabilities = capabilities
        self.diagnostics = diagnostics
        self.history = history
        self.queue = ConversionQueueManager(
            settings: settings,
            thermal: thermal,
            diagnostics: diagnostics,
            historyStore: history
        )
        let importService = MediaImportService(logSink: { message in
            Task { @MainActor in
                diagnostics.log("[IMPORT] \(message)")
            }
        })
        self.importService = importService
        TemporaryFileManager.cleanupStaleFiles()
        TemporaryFileManager.cleanupImportsDirectory()
        queue.loadPersistedJobs()
    }

    func importMedia(from url: URL, fileName: String?, source: MediaImportSource) async throws -> ConversionJob {
        let media = try await importService.importFile(from: url, fileName: fileName, source: source)
        return queue.addImportedMedia(media)
    }

    func clearIncomingImportError() {
        incomingImportError = nil
    }

    func handleIncomingURL(_ url: URL) async {
        do {
            let job = try await importMedia(from: url, fileName: url.lastPathComponent, source: .shareSheet)
            job.metadata = try? await MediaAnalyzer.analyze(url: job.sourceURL ?? url)
        } catch {
            incomingImportError = error.localizedDescription
            #if DEBUG
            print("Incoming file import failed: \(error)")
            #endif
        }
    }
}