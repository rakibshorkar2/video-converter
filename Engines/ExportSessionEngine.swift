import AVFoundation
import CoreMedia

final class ExportSessionEngine: VideoConversionEngine {
    let identifier = EngineKind.exportSession

    func canHandle(_ request: ConversionRequest) async -> Bool {
        guard let preset = ConversionPlanner.exportPreset(for: request) else { return false }
        let asset = AVURLAsset(url: request.sourceURL)
        let compatible = await AVAssetExportSession.exportPresets(compatibleWith: asset)
        return compatible.contains(preset)
    }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        let config = request.configuration
        guard let preset = ConversionPlanner.exportPreset(for: request) else {
            throw ConversionError.unsupportedCombination("\(config.outputContainer.displayName) is not available as an Apple export preset")
        }

        let asset = AVURLAsset(url: request.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.exportSessionFailed("preset unavailable: \(preset)")
        }
        if FileManager.default.fileExists(atPath: request.outputURL.path) {
            try? FileManager.default.removeItem(at: request.outputURL)
        }
        session.outputURL = request.outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if config.preserveMetadata {
            session.metadata = (try? await asset.load(.commonMetadata)) ?? []
        }

        let watcher = ExportWatcher(
            session: session,
            duration: duration,
            progress: progress,
            cancellation: cancellation
        )

        do {
            if #available(iOS 18.0, *) {
                try await session.export(to: request.outputURL, as: .mp4)
            } else {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: ConversionError.cancelled)
                        case .failed:
                            continuation.resume(throwing: ConversionError.exportSessionFailed(
                                session.error?.localizedDescription ?? "export failed"
                            ))
                        default:
                            continuation.resume(throwing: ConversionError.exportSessionFailed(
                                "unexpected status \(session.status.rawValue)"
                            ))
                        }
                    }
                }
            }
            watcher.stop()
        } catch {
            watcher.stop()
            session.cancelExport()
            if watcher.stallDetected {
                throw ConversionError.engineStalled("AVAssetExportSession stalled (\(preset))")
            }
            if cancellation.isCancelled {
                throw ConversionError.cancelled
            }
            throw ConversionError.exportSessionFailed(error.localizedDescription)
        }

        guard session.status == .completed else {
            throw ConversionError.exportSessionFailed("export did not complete")
        }
        guard FileManager.default.fileExists(atPath: request.outputURL.path),
              FileStorageManager.fileSize(at: request.outputURL) > 0 else {
            throw ConversionError.exportSessionFailed("no output file produced")
        }

        return ConversionResult(
            outputURL: request.outputURL,
            engine: .exportSession,
            usedStreamCopy: false,
            usedHardwareAcceleration: HardwareAcceleration.encoderAvailable(codec: config.videoCodec),
            duration: duration.seconds,
            outputSize: FileStorageManager.fileSize(at: request.outputURL)
        )
    }
}

private final class ExportWatcher: @unchecked Sendable {

    private static let stallInterval: TimeInterval = 20

    private let session: AVAssetExportSession
    private let duration: CMTime
    private let progress: @Sendable (ConversionProgress) -> Void
    private let cancellation: CancellationToken
    private let timer: DispatchSourceTimer

    private let lock = NSLock()
    private var startedAt = Date()
    private var lastFraction: Double = 0
    private var lastChangeDate = Date()
    private var stallDetectedFlag = false

    init(
        session: AVAssetExportSession,
        duration: CMTime,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) {
        self.session = session
        self.duration = duration
        self.progress = progress
        self.cancellation = cancellation
        let timer = DispatchSource.makeTimerSource(queue: MediaPump.pumpQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
    }

    var stallDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stallDetectedFlag
    }

    func stop() {
        timer.cancel()
    }

    private func tick() {
        if cancellation.isCancelled {
            session.cancelExport()
            return
        }

        let fraction = min(max(Double(session.progress), 0), 1)
        let now = Date()

        lock.lock()
        let previous = lastFraction
        let changed = fraction - previous
        if changed >= 0.001 || fraction >= 1 {
            lastFraction = fraction
            lastChangeDate = now
        }
        let stalled = fraction < 1 && now.timeIntervalSince(lastChangeDate) >= Self.stallInterval
        if stalled {
            stallDetectedFlag = true
        }
        let elapsed = now.timeIntervalSince(startedAt)
        lock.unlock()

        if stalled {
            session.cancelExport()
            return
        }

        let speed = elapsed > 0 ? (fraction - previous) / elapsed : 0
        let eta = speed > 0.05 ? (1 - fraction) / speed : 0
        let seconds = duration.isNumeric ? duration.seconds : 0
        progress(ConversionProgress(
            stage: .encoding,
            fractionCompleted: fraction,
            speed: speed,
            eta: eta,
            processedDuration: fraction * max(seconds, 0)
        ))
    }
}