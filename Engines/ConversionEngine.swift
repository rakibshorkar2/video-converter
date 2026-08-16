import Foundation

struct ConversionProgress: Sendable {
    var stage: ConversionStage
    var fractionCompleted: Double
    var speed: Double
    var eta: TimeInterval
    var processedDuration: TimeInterval
}

struct ConversionRequest: Sendable {
    let sourceURL: URL
    let configuration: ConversionConfiguration
    let outputURL: URL
    let sourceMetadata: MediaMetadata
}

struct ConversionResult: Sendable {
    let outputURL: URL
    let engine: EngineKind
    let usedStreamCopy: Bool
    let usedHardwareAcceleration: Bool
    let duration: TimeInterval
    let outputSize: Int64
}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
}

final class ProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit = Date.distantPast
    private let start = Date()

    func report(processed: Double, duration: Double, stage: ConversionStage, progress: (@Sendable (ConversionProgress) -> Void)?) {
        guard let progress else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        let shouldEmit: Bool
        lock.lock()
        if now.timeIntervalSince(lastEmit) >= 0.25 || processed >= duration {
            lastEmit = now
            shouldEmit = true
        } else {
            shouldEmit = false
        }
        lock.unlock()
        guard shouldEmit else { return }
        let speed = elapsed > 0 ? processed / elapsed : 0
        let eta = speed > 0.0001 ? (duration - processed) / speed : 0
        let fraction = duration > 0 ? min(max(processed / duration, 0), 1) : 0
        progress(ConversionProgress(
            stage: stage,
            fractionCompleted: fraction,
            speed: speed,
            eta: max(eta, 0),
            processedDuration: processed
        ))
    }
}

protocol VideoConversionEngine: Sendable {
    var identifier: EngineKind { get }
    func canHandle(_ request: ConversionRequest) async -> Bool
    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult
}