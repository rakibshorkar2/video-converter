import Foundation
import Observation

@MainActor
@Observable
final class ConversionQueueManager {

    private(set) var jobs: [ConversionJob] = []
    private(set) var isActive = false

    private let settings: AppSettings
    private let thermal: ThermalMonitor
    private let diagnostics: DiagnosticsLogger
    private let historyStore: HistoryStore
    private var tokens: [UUID: CancellationToken] = [:]
    private var pausedForBackground = false
    private var hasLoaded = false

    init(settings: AppSettings, thermal: ThermalMonitor, diagnostics: DiagnosticsLogger, historyStore: HistoryStore) {
        self.settings = settings
        self.thermal = thermal
        self.diagnostics = diagnostics
        self.historyStore = historyStore
    }

    func loadPersistedJobs() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let stored = JobStore.load()
        for item in stored {
            let job = ConversionJob(sourceURL: item.sourceURL, sourceName: item.sourceName)
            job.configuration = item.configuration
            job.destination = item.destination
            job.metadata = item.metadata
            job.outputURL = item.outputURL
            job.outputSize = item.outputSize
            job.engine = item.engine
            job.errorMessage = item.errorMessage
            job.technicalDetails = item.technicalDetails
            job.createdAt = item.createdAt
            job.completedAt = item.completedAt
            if item.status == .analyzing || item.status == .preparing || item.status == .converting ||
               item.status == .finalizing || item.status == .saving || item.status == .waitingForResources {
                job.status = .interrupted
                job.errorMessage = L10n.jobInterruptedOnLaunch
            } else {
                job.status = item.status
            }
            job.fraction = item.fraction
            jobs.append(job)
        }
    }

    func importURL(_ url: URL, fileName: String) async throws -> ConversionJob {
        let destination = FileStorageManager.uniqueURL(
            in: FileStorageManager.importsDirectory,
            fileName: fileName
        )
        do {
            try FileStorageManager.copyItem(from: url, to: destination)
        } catch {
            throw ConversionError.filesAccessFailed(error.localizedDescription)
        }
        let job = ConversionJob(sourceURL: destination, sourceName: fileName)
        job.configuration = ConversionConfiguration.preset(settings.defaultPreset, sourceCodec: .h264)
        settings.apply(to: &job.configuration)
        job.destination = settings.defaultDestination
        jobs.insert(job, at: 0)
        persist()
        return job
    }

    func addJob(_ job: ConversionJob) {
        jobs.insert(job, at: 0)
        persist()
    }

    func removeJob(_ job: ConversionJob) {
        tokens[job.id]?.cancel()
        jobs.removeAll { $0.id == job.id }
        TemporaryFileManager.cleanup(jobID: job.id)
        persist()
    }

    func clearFinishedJobs() {
        tokens.forEach { $0.value.cancel() }
        jobs.removeAll { $0.isTerminal }
        persist()
    }

    func start(_ job: ConversionJob) {
        guard job.canConfigure else { return }
        job.status = .queued
        job.errorMessage = nil
        job.technicalDetails = nil
        job.fraction = 0
        persist()
        pump()
    }

    func retry(_ job: ConversionJob) {
        guard job.canRetry else { return }
        job.status = .queued
        job.errorMessage = nil
        job.technicalDetails = nil
        job.fraction = 0
        job.stage = nil
        job.outputURL = nil
        job.outputSize = 0
        job.completedAt = nil
        persist()
        pump()
    }

    func cancel(_ job: ConversionJob) {
        tokens[job.id]?.cancel()
        if job.status == .queued || job.status == .waitingForResources {
            job.status = .cancelled
            persist()
        }
    }

    func pauseForBackground() {
        pausedForBackground = true
        for job in jobs where isActiveStatus(job.status) {
            tokens[job.id]?.cancel()
            job.status = .interrupted
            job.errorMessage = L10n.jobInterruptedBackground
            job.stage = nil
            TemporaryFileManager.cleanup(jobID: job.id)
        }
        persist()
    }

    func resumeFromForeground() {
        pausedForBackground = false
        pump()
    }

    var activeJobCount: Int {
        jobs.filter { isActiveStatus($0.status) }.count
    }

    // MARK: - Execution

    private func pump() {
        guard !pausedForBackground else { return }

        if thermal.isCritical {
            for job in jobs where job.status == .queued {
                job.status = .waitingForResources
                job.errorMessage = L10n.jobWaitingThermal
            }
            return
        }
        if thermal.thermalState == .serious {
            for job in jobs where job.status == .queued {
                job.status = .waitingForResources
                job.errorMessage = L10n.jobWaitingThermal
            }
        } else {
            for job in jobs where job.status == .waitingForResources {
                job.status = .queued
                job.errorMessage = nil
            }
        }

        let maxConcurrent = max(1, min(settings.concurrentJobs, 2))
        guard activeJobCount < maxConcurrent else { return }
        guard let next = jobs.first(where: { $0.status == .queued }) else {
            isActive = jobs.contains(where: { isActiveStatus($0.status) })
            return
        }
        execute(next)
    }

    private func execute(_ job: ConversionJob) {
        job.status = .analyzing
        persist()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(job)
            } catch {
                let cancellation = error as? ConversionError
                if case .cancelled? = cancellation {
                    self.finish(job, status: .cancelled, error: nil)
                } else if self.thermal.isCritical {
                    self.finish(job, status: .failed, error: ConversionError.thermalLimitReached)
                } else {
                    self.finish(job, status: .failed, error: error)
                }
            }
            self.pump()
        }
    }

    private func run(_ job: ConversionJob) async throws {
        guard let sourceURL = job.sourceURL else { throw ConversionError.unreadableSource }

        var metadata = job.metadata
        if metadata == nil {
            do {
                metadata = try await MediaAnalyzer.analyze(url: sourceURL)
            } catch {
                #if FFMPEG_ENABLED
                if let ffmpegAnalysis = await FFmpegEngine.analyze(url: sourceURL) {
                    metadata = ffmpegAnalysis.metadata
                } else {
                    throw ConversionError.unreadableSource
                }
                #else
                throw ConversionError.unreadableSource
                #endif
            }
            job.metadata = metadata
        }
        guard let metadata else { throw ConversionError.unreadableSource }
        guard metadata.hasVideo else { throw ConversionError.noVideoTrack }
        if !metadata.isPlayable {
            throw ConversionError.corruptedFile
        }

        if job.configuration.streamCopy && !FormatCapabilities.canStreamCopy(source: metadata, to: job.configuration.outputContainer) {
            throw ConversionError.unsupportedCombination(
                String(format: L10n.errorStreamCopyIncompatible, job.configuration.outputContainer.displayName)
            )
        }

        let estimate = SizeEstimator.estimatedOutputBytes(config: job.configuration, source: metadata)
        let needed = SizeEstimator.requiredStorage(bytes: estimate, sourceSize: metadata.fileSize)
        if !StorageMonitor.hasSufficientStorage(needed: needed) {
            throw ConversionError.insufficientStorage(needed: needed, available: StorageMonitor.availableBytes())
        }

        job.status = .preparing
        job.stage = .preparing

        let extensionName = FormatCapabilities.outputFileExtension(for: job.configuration.outputContainer)
        let tempOutput = TemporaryFileManager.outputURL(for: job.id, fileExtension: extensionName)
        if FileManager.default.fileExists(atPath: tempOutput.path) {
            try? FileManager.default.removeItem(at: tempOutput)
        }

        let token = CancellationToken()
        tokens[job.id] = token
        defer { tokens[job.id] = nil }

        let request = ConversionRequest(
            sourceURL: sourceURL,
            configuration: job.configuration,
            outputURL: tempOutput,
            sourceMetadata: metadata
        )
        let engine = await ConversionEngineRouter.selectEngine(for: request)
        job.engine = engine.identifier
        job.status = .converting

        diagnostics.log(L10n.diagnosticsEngineSelected, engine: engine.identifier, detail: "\(metadata.videoTrack?.codecName ?? "?") → \(job.configuration.videoCodec.displayName)")

        let progressClosure: @Sendable (ConversionProgress) -> Void = { [thermal] progress in
            Task { @MainActor in
                job.stage = progress.stage
                job.fraction = progress.fractionCompleted
                job.speed = progress.speed
                job.eta = progress.eta
                if thermal.isCritical {
                    token.cancel()
                }
            }
        }

        let result = try await engine.convert(request, progress: progressClosure, cancellation: token)
        guard !token.isCancelled else { throw ConversionError.cancelled }

        job.outputURL = result.outputURL
        job.outputSize = result.outputSize

        job.status = .finalizing
        job.stage = .finalizing
        do {
            try await OutputValidator.validate(url: tempOutput, source: metadata, configuration: job.configuration)
        } catch {
            try? FileManager.default.removeItem(at: tempOutput)
            throw error
        }

        job.status = .saving
        job.stage = .saving
        let finalURL = try await saveOutput(job: job, tempURL: tempOutput)
        job.outputURL = finalURL
        job.outputSize = FileStorageManager.fileSize(at: finalURL)

        let entry = HistoryEntry(
            id: UUID(),
            fileName: finalURL.lastPathComponent,
            createdAt: Date(),
            inputFormat: metadata.sourceFileExtension.uppercased(),
            outputFormat: job.configuration.outputContainer.displayName,
            inputSize: metadata.fileSize,
            outputSize: job.outputSize,
            duration: metadata.duration,
            status: .completed,
            outputURL: finalURL,
            engine: engine.identifier,
            streamCopy: result.usedStreamCopy
        )
        if settings.keepHistory {
            historyStore.add(entry)
        }

        job.status = .completed
        job.stage = .completed
        job.fraction = 1
        job.speed = nil
        job.eta = nil
        job.completedAt = Date()

        if !settings.keepImports, let sourceURL = job.sourceURL,
           sourceURL.path.hasPrefix(FileStorageManager.importsDirectory.path) {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        TemporaryFileManager.cleanup(jobID: job.id)
        diagnostics.log("\(L10n.diagnosticsCompleted) \(finalURL.lastPathComponent)", engine: engine.identifier, detail: ByteFormatter.string(from: job.outputSize))
        persist()
    }

    private func saveOutput(job: ConversionJob, tempURL: URL) async throws -> URL {
        let extensionName = tempURL.pathExtension
        switch job.destination {
        case .photos:
            _ = try await PhotoLibraryManager.saveVideo(toPhotos: tempURL)
            let destination = FileStorageManager.uniqueDestinationURL(
                in: FileStorageManager.convertedDirectory,
                baseName: job.sourceName,
                fileExtension: extensionName
            )
            try FileStorageManager.copyItem(from: tempURL, to: destination)
            return destination

        case .filesDocuments:
            let destination = FileStorageManager.uniqueDestinationURL(
                in: FileStorageManager.convertedDirectory,
                baseName: job.sourceName,
                fileExtension: extensionName
            )
            do {
                try FileStorageManager.moveItem(from: tempURL, to: destination)
            } catch {
                throw ConversionError.filesAccessFailed(error.localizedDescription)
            }
            return destination

        case .filesCustom:
            guard let bookmark = settings.customFolderBookmark,
                  let folder = FileDestinationStore.resolveBookmark(bookmark) else {
                throw ConversionError.filesAccessFailed(L10n.errorNoCustomFolder)
            }
            let access = FileDestinationStore.startAccess(to: folder)
            defer { if access { FileDestinationStore.stopAccess(to: folder) } }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ConversionError.filesAccessFailed(L10n.errorNoCustomFolder)
            }
            let destination = FileStorageManager.uniqueDestinationURL(
                in: folder,
                baseName: job.sourceName,
                fileExtension: extensionName
            )
            do {
                try FileStorageManager.copyItem(from: tempURL, to: destination)
            } catch {
                throw ConversionError.filesAccessFailed(error.localizedDescription)
            }
            return destination
        }
    }

    private func finish(_ job: ConversionJob, status: JobStatus, error: Error?) {
        job.status = status
        job.stage = nil
        job.speed = nil
        job.eta = nil
        job.completedAt = Date()
        if let error {
            let conversionError = error as? ConversionError
            job.errorMessage = conversionError?.errorDescription ?? error.localizedDescription
            job.technicalDetails = conversionError?.technicalDetail
            diagnostics.log("\(L10n.diagnosticsFailed) \(job.sourceName)", engine: job.engine, detail: job.errorMessage)
        }
        TemporaryFileManager.cleanup(jobID: job.id)
        persist()
    }

    private func isActiveStatus(_ status: JobStatus) -> Bool {
        switch status {
        case .analyzing, .preparing, .converting, .finalizing, .saving, .waitingForResources:
            return true
        default:
            return false
        }
    }

    private func persist() {
        JobStore.save(jobs)
    }
}