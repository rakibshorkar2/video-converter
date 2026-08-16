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

    func addImportedMedia(_ media: ImportedMedia) -> ConversionJob {
        let job = ConversionJob(sourceURL: media.url, sourceName: media.fileName)
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
                if self.pausedForBackground || job.status == .interrupted {
                    self.finish(job, status: .interrupted, error: nil)
                } else if let conversionError = error as? ConversionError {
                    if case .cancelled = conversionError {
                        self.finish(job, status: .cancelled, error: nil)
                    } else if self.thermal.isCritical {
                        self.finish(job, status: .interrupted, error: ConversionError.thermalLimitReached)
                    } else {
                        self.finish(job, status: .failed, error: error)
                    }
                } else if self.thermal.isCritical {
                    self.finish(job, status: .interrupted, error: ConversionError.thermalLimitReached)
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
        let plan = await ConversionPlanner.plan(for: request)
        guard plan.engine != nil else {
            throw ConversionError.unsupportedCombination(plan.unsupportedReason ?? "unsupported configuration")
        }

        let watchdog = JobWatchdog(jobID: job.id, token: token)
        defer { watchdog.stop() }

        var engine = await ConversionEngineRouter.selectEngine(for: request)
        job.engine = engine.identifier
        job.status = .converting

        diagnostics.log(L10n.diagnosticsEngineSelected, engine: engine.identifier, detail: "\(metadata.videoTrack?.codecName ?? "?") → \(job.configuration.videoCodec.displayName)")

        let progressClosure: @Sendable (ConversionProgress) -> Void = { [thermal] progress in
            watchdog.poke()
            Task { @MainActor in
                job.stage = progress.stage
                if progress.fractionCompleted >= job.fraction || progress.fractionCompleted >= 1 {
                    job.fraction = min(progress.fractionCompleted, 0.99)
                }
                job.speed = progress.speed
                if progress.speed > 0.05 {
                    job.eta = progress.eta
                } else {
                    job.eta = nil
                }
                if thermal.isCritical {
                    token.cancel()
                }
            }
        }

        var result: ConversionResult
        while true {
            do {
                result = try await runEngine(
                    engine,
                    request: request,
                    token: token,
                    progressClosure: progressClosure,
                    watchdog: watchdog
                )
                break
            } catch {
                guard !watchdog.hasFired else {
                    throw ConversionError.engineStalled(watchdog.fireDetail)
                }
                guard !token.isCancelled else {
                    throw ConversionError.cancelled
                }
                guard let next = await ConversionEngineRouter.fallbackEngine(after: engine.identifier, for: request) else {
                    throw error
                }
                engine = next
                job.engine = next.identifier
            }
        }
        guard !token.isCancelled else { throw ConversionError.cancelled }

        job.outputURL = result.outputURL
        job.outputSize = result.outputSize

        job.status = .finalizing
        job.stage = .finalizing
        do {
            try await OutputValidator.validate(url: tempOutput, source: metadata, configuration: job.configuration, plan: plan)
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

    private func runEngine(
        _ engine: VideoConversionEngine,
        request: ConversionRequest,
        token: CancellationToken,
        progressClosure: @escaping @Sendable (ConversionProgress) -> Void,
        watchdog: JobWatchdog
    ) async throws -> ConversionResult {
        try await withThrowingTaskGroup(of: ConversionResult.self) { group in
            group.addTask {
                try await engine.convert(request, progress: progressClosure, cancellation: token)
            }
            group.addTask {
                try await withTaskCancellationHandler {
                    try await watchdog.awaitFire()
                } onCancel: {
                    watchdog.cancelWait()
                }
            }
            guard let first = try await group.next() else {
                throw ConversionError.engineStalled(watchdog.fireDetail)
            }
            group.cancelAll()
            while let _ = try? await group.next() {}
            return first
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

private final class JobWatchdog: @unchecked Sendable {

    private static let stallInterval: TimeInterval = 20
    private static let graceInterval: TimeInterval = 6

    private let lock = NSLock()
    private let token: CancellationToken
    private let jobID: UUID
    private let timer: DispatchSourceTimer
    private var lastPoke = Date()
    private var stalledAt: Date?
    private var firedFlag = false
    private var detailText = ""
    private var fireContinuation: CheckedContinuation<Void, Error>?

    init(jobID: UUID, token: CancellationToken) {
        self.jobID = jobID
        self.token = token
        let timer = DispatchSource.makeTimerSource(queue: MediaPump.pumpQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firedFlag
    }

    var fireDetail: String {
        lock.lock()
        defer { lock.unlock() }
        return detailText
    }

    func poke() {
        lock.lock()
        lastPoke = Date()
        stalledAt = nil
        lock.unlock()
    }

    func stop() {
        timer.cancel()
    }

    func awaitFire() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if firedFlag {
                let detail = detailText
                lock.unlock()
                continuation.resume(throwing: ConversionError.engineStalled(detail))
                return
            }
            fireContinuation = continuation
            lock.unlock()
        }
    }

    func cancelWait() {
        lock.lock()
        let continuation = fireContinuation
        fireContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func tick() {
        lock.lock()
        guard !firedFlag else {
            lock.unlock()
            return
        }
        let silence = Date().timeIntervalSince(lastPoke)
        if silence >= Self.stallInterval {
            if stalledAt == nil {
                stalledAt = Date()
                detailText = "no progress for \(Int(silence))s (job \(jobID.uuidString.prefix(8)))"
            } else if Date().timeIntervalSince(stalledAt!) >= Self.graceInterval {
                firedFlag = true
                let detail = detailText
                let continuation = fireContinuation
                fireContinuation = nil
                lock.unlock()
                token.cancel()
                continuation?.resume(throwing: ConversionError.engineStalled(detail))
                return
            }
        } else {
            stalledAt = nil
        }
        lock.unlock()
    }
}