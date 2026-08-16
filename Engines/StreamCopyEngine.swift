import AVFoundation
import CoreMedia

final class StreamCopyEngine: VideoConversionEngine {
    let identifier = EngineKind.streamCopy

    func canHandle(_ request: ConversionRequest) async -> Bool {
        guard request.configuration.streamCopy else { return false }
        guard AVFileType(container: request.configuration.outputContainer) != nil else { return false }
        return FormatCapabilities.canStreamCopy(source: request.sourceMetadata, to: request.configuration.outputContainer)
    }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        let config = request.configuration
        let asset = AVURLAsset(url: request.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard let fileType = AVFileType(container: config.outputContainer) else {
            throw ConversionError.unsupportedCombination("\(config.outputContainer.displayName) requires FFmpeg")
        }
        guard FormatCapabilities.canStreamCopy(source: request.sourceMetadata, to: config.outputContainer) else {
            throw ConversionError.unsupportedCombination(
                String(format: L10n.errorStreamCopyIncompatible, config.outputContainer.displayName)
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: fileType)
        let throttle = ProgressThrottler()

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var videoPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        for track in videoTracks.prefix(1) {
            let descriptions = try await track.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ConversionError.nativeEngineFailed(L10n.errorReaderOutput) }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ConversionError.unsupportedCombination(
                    String(format: L10n.errorStreamCopyIncompatible, config.outputContainer.displayName)
                )
            }
            writer.add(input)
            videoPairs.append((output, input))
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let selectedAudio = selectedAudioTracks(audioTracks, selection: config.audioTrackSelection, audioCodec: config.audioCodec)
        var audioPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        for track in selectedAudio {
            let descriptions = try await track.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            audioPairs.append((output, input))
        }

        if config.preserveMetadata {
            writer.metadata = (try? await asset.load(.commonMetadata)) ?? []
        }

        guard reader.startReading() else {
            throw ConversionError.nativeEngineFailed(reader.error?.localizedDescription ?? L10n.errorReaderStart)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        do {
            for (output, input) in videoPairs {
                try await MediaPump.run(
                    output: output,
                    input: input,
                    duration: duration,
                    stage: .muxing,
                    progress: progress,
                    cancellation: cancellation,
                    throttle: throttle
                )
            }
            for (output, input) in audioPairs {
                try await MediaPump.run(
                    output: output,
                    input: input,
                    duration: duration,
                    stage: .muxing,
                    progress: progress,
                    cancellation: cancellation,
                    throttle: throttle
                )
            }
            guard !cancellation.isCancelled else { throw ConversionError.cancelled }
            try await writer.finishWriting()
        } catch {
            writer.cancelWriting()
            reader.cancelReading()
            throw error
        }

        guard writer.status == .completed else {
            reader.cancelReading()
            throw ConversionError.nativeEngineFailed(writer.error?.localizedDescription ?? L10n.errorWriterFailed)
        }

        return ConversionResult(
            outputURL: request.outputURL,
            engine: .streamCopy,
            usedStreamCopy: true,
            usedHardwareAcceleration: false,
            duration: duration.seconds,
            outputSize: FileStorageManager.fileSize(at: request.outputURL)
        )
    }

    private func selectedAudioTracks(_ tracks: [AVAssetTrack], selection: AudioTrackSelection, audioCodec: AudioCodecOption) -> [AVAssetTrack] {
        guard audioCodec != .none else { return [] }
        switch selection {
        case .all: return tracks
        case .first: return Array(tracks.prefix(1))
        case .none: return []
        }
    }
}