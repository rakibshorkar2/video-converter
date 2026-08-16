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
        TemporaryFileManager.cleanupStaleFiles()
        TemporaryFileManager.cleanupImportsDirectory()
        queue.loadPersistedJobs()
    }

    func handleIncomingURL(_ url: URL) async {
        let fileName = url.lastPathComponent
        do {
            let job = try await queue.importURL(url, fileName: fileName)
            job.metadata = try? await MediaAnalyzer.analyze(url: job.sourceURL ?? url)
        } catch {
            #if DEBUG
            print("Incoming file import failed: \(error)")
            #endif
        }
    }
}