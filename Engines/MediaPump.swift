import AVFoundation
import CoreMedia

enum MediaPump {

    static let pumpQueue = DispatchQueue(label: "com.videoconverter.pump", qos: .userInitiated)

    static func run(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        duration: CMTime,
        stage: ConversionStage,
        mediaName: String,
        progress: (@Sendable (ConversionProgress) -> Void)?,
        cancellation: CancellationToken,
        throttle: ProgressThrottler,
        watchdogInterval: TimeInterval = 10
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PumpDriver(
                reader: reader,
                writer: writer,
                output: output,
                input: input,
                duration: duration,
                stage: stage,
                mediaName: mediaName,
                progress: progress,
                cancellation: cancellation,
                throttle: throttle,
                watchdogInterval: watchdogInterval,
                continuation: continuation
            ).start()
        }
    }
}

final class PumpDriver: @unchecked Sendable {

    private static let watchdogQueue = DispatchQueue(label: "com.videoconverter.pump.watchdog", qos: .userInitiated)

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let duration: CMTime
    private let stage: ConversionStage
    private let mediaName: String
    private let progress: (@Sendable (ConversionProgress) -> Void)?
    private let cancellation: CancellationToken
    private let throttle: ProgressThrottler
    private let watchdogInterval: TimeInterval
    private let continuation: CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var finished = false
    private var appendedSamples = 0
    private var lastAppendDate = Date()
    private var stallTimer: DispatchSourceTimer?

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        duration: CMTime,
        stage: ConversionStage,
        mediaName: String,
        progress: (@Sendable (ConversionProgress) -> Void)?,
        cancellation: CancellationToken,
        throttle: ProgressThrottler,
        watchdogInterval: TimeInterval,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.reader = reader
        self.writer = writer
        self.output = output
        self.input = input
        self.duration = duration
        self.stage = stage
        self.mediaName = mediaName
        self.progress = progress
        self.cancellation = cancellation
        self.throttle = throttle
        self.watchdogInterval = watchdogInterval
        self.continuation = continuation
    }

    func start() {
        if writer.status == .failed {
            finish(.failure(pipelineFailure(writerErrorDetail())))
            return
        }
        if cancellation.isCancelled {
            finish(.failure(ConversionError.cancelled))
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: Self.watchdogQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        lock.lock()
        stallTimer = timer
        lock.unlock()
        timer.resume()

        input.requestMediaDataWhenReady(on: MediaPump.pumpQueue) { [weak self] in
            guard let self else { return }
            self.drain()
        }
    }

    private func drain() {
        while !isFinished {
            if cancellation.isCancelled {
                input.markAsFinished()
                finish(.failure(ConversionError.cancelled))
                return
            }
            guard input.isReadyForMoreMediaData else { return }
            if writer.status == .failed {
                finish(.failure(pipelineFailure(writerErrorDetail())))
                return
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                handleOutputExhausted()
                return
            }
            guard input.append(sampleBuffer) else {
                finish(.failure(pipelineFailure(appendErrorDetail())))
                return
            }
            lock.lock()
            appendedSamples += 1
            lastAppendDate = Date()
            lock.unlock()
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isNumeric, duration.isNumeric, duration.seconds > 0 {
                throttle.report(processed: pts.seconds, duration: duration.seconds, stage: stage, progress: progress)
            }
        }
    }

    private func handleOutputExhausted() {
        var attempts = 0
        while !isFinished {
            switch reader.status {
            case .completed:
                input.markAsFinished()
                finish(.success(()))
                return
            case .failed:
                finish(.failure(pipelineFailure(readerErrorDetail())))
                return
            case .cancelled:
                finish(.failure(ConversionError.cancelled))
                return
            case .unknown, .reading:
                attempts += 1
                if attempts > 100 {
                    finish(.failure(pipelineFailure(readerDidNotCompleteDetail())))
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func watchdogTick() {
        guard !isFinished else { return }
        let silence: TimeInterval
        lock.lock()
        silence = Date().timeIntervalSince(lastAppendDate)
        lock.unlock()
        guard silence > watchdogInterval else { return }
        finish(.failure(ConversionError.engineStalled(stallDetail(silence: silence))))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let timer = stallTimer
        stallTimer = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(with: result)
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    // MARK: - Error detail

    private func pipelineFailure(_ detail: String) -> ConversionError {
        .pipelineFailure("\(mediaName): \(detail)")
    }

    private func writerErrorDetail() -> String {
        let error = writer.error?.localizedDescription ?? "unknown"
        return "writer failed (\(writer.status.rawValue)): \(error)"
    }

    private func appendErrorDetail() -> String {
        var detail = "append rejected after \(appendedSamples) samples; writer status \(writer.status.rawValue), input ready \(input.isReadyForMoreMediaData)"
        if let writerError = writer.error {
            detail += "; writer error: \(writerError.localizedDescription)"
        }
        return detail
    }

    private func readerErrorDetail() -> String {
        let error = reader.error?.localizedDescription ?? "unknown"
        return "reader failed: \(error)"
    }

    private func readerDidNotCompleteDetail() -> String {
        "reader did not complete after the last sample (status \(reader.status.rawValue))"
    }

    private func stallDetail(silence: TimeInterval) -> String {
        var detail = "no samples appended for \(Int(silence))s after \(appendedSamples) samples (\(mediaName))"
        detail += "; reader status \(reader.status.rawValue)"
        detail += ", writer status \(writer.status.rawValue)"
        detail += ", writer error \(writer.error?.localizedDescription ?? "none")"
        detail += ", input ready \(input.isReadyForMoreMediaData)"
        return detail
    }
}