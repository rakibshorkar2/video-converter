import AVFoundation
import CoreMedia

enum MediaPump {

    static let pumpQueue = DispatchQueue(label: "com.videoconverter.pump", qos: .userInitiated)

    static func run(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        duration: CMTime,
        stage: ConversionStage,
        progress: (@Sendable (ConversionProgress) -> Void)?,
        cancellation: CancellationToken,
        throttle: ProgressThrottler
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            input.requestMediaDataWhenReady(on: pumpQueue) {
                while input.isReadyForMoreMediaData {
                    if cancellation.isCancelled {
                        input.markAsFinished()
                        finish(.failure(ConversionError.cancelled))
                        return
                    }
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if output.status == .failed {
                            finish(.failure(output.error ?? ConversionError.nativeEngineFailed(L10n.errorReadFailed)))
                        } else {
                            finish(.success(()))
                        }
                        return
                    }
                    input.append(sampleBuffer)
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    if pts.isNumeric, duration.isNumeric, duration.seconds > 0 {
                        throttle.report(processed: pts.seconds, duration: duration.seconds, stage: stage, progress: progress)
                    }
                }
            }
        }
    }
}