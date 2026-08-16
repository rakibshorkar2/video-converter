import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class AVFoundationEngine: VideoConversionEngine {
    let identifier = EngineKind.avFoundation

    func canHandle(_ request: ConversionRequest) async -> Bool {
        let config = request.configuration
        guard !config.streamCopy else { return false }
        guard AVFileType(container: config.outputContainer) != nil else { return false }
        guard config.videoCodec == .h264 || config.videoCodec == .hevc else { return false }
        guard FormatCapabilities.audioCodecEncodable(config.audioCodec) else { return false }
        if config.audioCodec == .copy {
            for audio in request.sourceMetadata.audioTracks {
                guard FormatCapabilities.audioCopyable(to: config.outputContainer, codecType: audio.codecType) else { return false }
            }
        }
        return true
    }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        do {
            return try await convertCore(request: request, hardwareRequested: request.configuration.hardwareAcceleration, progress: progress, cancellation: cancellation)
        } catch {
            if request.configuration.hardwareAcceleration && !cancellation.isCancelled {
                return try await convertCore(request: request, hardwareRequested: false, progress: progress, cancellation: cancellation)
            }
            throw error
        }
    }

    private func convertCore(
        request: ConversionRequest,
        hardwareRequested: Bool,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        let config = request.configuration
        let source = request.sourceMetadata
        guard let fileType = AVFileType(container: config.outputContainer) else {
            throw ConversionError.unsupportedCombination("\(config.outputContainer.displayName) requires FFmpeg")
        }

        let asset = AVURLAsset(url: request.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw ConversionError.noVideoTrack }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let sourceVideo = source.videoTrack

        let targetSize = config.resolution.resolvedSize(for: naturalSize)
        let targetFPS = config.frameRate.resolvedValue(original: nominalFPS)
        let rotation = MediaAnalyzer.rotationDegrees(from: preferredTransform)
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let sizeChanged = abs(targetSize.width - displaySize.width) > 1 || abs(targetSize.height - displaySize.height) > 1
        let fpsChanged = targetFPS != nil && abs(targetFPS! - nominalFPS) > 0.5
        let needsComposition = sizeChanged || fpsChanged
        let preserveHDR = config.preserveHDR && sourceVideo?.isHDR == true && config.videoCodec == .hevc

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: fileType)
        let throttle = ProgressThrottler()

        let pixelFormat: OSType = preserveHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let readerVideoOutput: AVAssetReaderOutput
        if needsComposition {
            let composition = try await Self.makeVideoComposition(
                videoTrack: videoTrack,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                targetSize: targetSize,
                targetFPS: targetFPS ?? nominalFPS,
                duration: duration
            )
            let videoCompositionOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            )
            videoCompositionOutput.videoComposition = composition
            readerVideoOutput = videoCompositionOutput
        } else {
            readerVideoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            )
        }
        readerVideoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerVideoOutput) else {
            throw ConversionError.nativeEngineFailed(L10n.errorReaderOutput)
        }
        reader.add(readerVideoOutput)

        let codec = config.videoCodec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        let profile: String = config.videoCodec == .hevc
            ? (preserveHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
            : AVVideoProfileLevelH264HighAutoLevel
        let bitrate = SizeEstimator.suggestedVideoBitrate(config: config, source: source) ?? 8_000_000
        let effectiveFPS = targetFPS ?? max(nominalFPS, 1)

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: profile,
            AVVideoExpectedSourceFrameRateKey: effectiveFPS
        ]
        if let fps = targetFPS {
            compressionProperties[AVVideoMaxKeyFrameIntervalKey] = Int(fps * 2)
        }

        let outputWidth = needsComposition ? Int(targetSize.width.rounded()) : Int(displaySize.width.rounded())
        let outputHeight = needsComposition ? Int(targetSize.height.rounded()) : Int(displaySize.height.rounded())

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: max(outputWidth, 16),
            AVVideoHeightKey: max(outputHeight, 16),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        if preserveHDR, let sv = sourceVideo {
            videoSettings[AVVideoColorPropertiesKey] = Self.colorProperties(for: sv)
        }

        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        if !needsComposition {
            writerVideoInput.transform = preferredTransform
        }
        guard writer.canAdd(writerVideoInput) else {
            throw ConversionError.unsupportedCombination("\(config.videoCodec.displayName) + \(config.outputContainer.displayName)")
        }
        writer.add(writerVideoInput)

        let selectedAudioTracks = selectedAudioTracks(audioTracks, selection: config.audioTrackSelection, audioCodec: config.audioCodec)
        var audioPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        for track in selectedAudioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let readerOutput: AVAssetReaderOutput
            let writerInput: AVAssetWriterInput
            if config.audioCodec == .copy {
                readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            } else {
                let pcmSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: config.audioSampleRate,
                    AVNumberOfChannelsKey: config.audioChannels,
                    AVEncoderBitRateKey: config.audioBitrate
                ]
                writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            }
            readerOutput.alwaysCopiesSampleData = false
            writerInput.expectsMediaDataInRealTime = false
            if reader.canAdd(readerOutput) && writer.canAdd(writerInput) {
                reader.add(readerOutput)
                writer.add(writerInput)
                audioPairs.append((readerOutput, writerInput))
            }
        }

        if config.preserveMetadata {
            writer.metadata = (try? await asset.load(.commonMetadata)) ?? []
        }

        guard reader.startReading() else {
            throw ConversionError.nativeEngineFailed(reader.error?.localizedDescription ?? L10n.errorReaderStart)
        }
        writer.startWriting()
        guard writer.status == .writing else {
            reader.cancelReading()
            throw ConversionError.nativeEngineFailed(writer.error?.localizedDescription ?? L10n.errorWriterFailed)
        }
        guard writer.startSession(atSourceTime: .zero) else {
            writer.cancelWriting()
            reader.cancelReading()
            throw ConversionError.nativeEngineFailed(L10n.errorWriterFailed)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await MediaPump.run(
                        reader: reader,
                        writer: writer,
                        output: readerVideoOutput,
                        input: writerVideoInput,
                        duration: duration,
                        stage: .encoding,
                        mediaName: request.sourceURL.lastPathComponent,
                        progress: progress,
                        cancellation: cancellation,
                        throttle: throttle
                    )
                }
                for (output, input) in audioPairs {
                    group.addTask {
                        try await MediaPump.run(
                            reader: reader,
                            writer: writer,
                            output: output,
                            input: input,
                            duration: duration,
                            stage: .encoding,
                            mediaName: request.sourceURL.lastPathComponent,
                            progress: progress,
                            cancellation: cancellation,
                            throttle: throttle
                        )
                    }
                }
                try await group.waitForAll()
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
            engine: .avFoundation,
            usedStreamCopy: false,
            usedHardwareAcceleration: hardwareRequested,
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

    private static func makeVideoComposition(
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        targetSize: CGSize,
        targetFPS: Double,
        duration: CMTime
    ) async throws -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: Int32(targetFPS))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(Self.transformForComposition(naturalSize: naturalSize, targetSize: targetSize, preferredTransform: preferredTransform), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        return composition
    }

    private static func transformForComposition(naturalSize: CGSize, targetSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        let angle = atan2(preferredTransform.b, preferredTransform.a)
        let isRotated = abs(abs(angle) - .pi / 2) < 0.01
        let orientedWidth = isRotated ? naturalSize.height : naturalSize.width
        let orientedHeight = isRotated ? naturalSize.width : naturalSize.height
        let scale = min(targetSize.width / max(orientedWidth, 1), targetSize.height / max(orientedHeight, 1))
        var t = CGAffineTransform(translationX: targetSize.width / 2, y: targetSize.height / 2)
        t = t.rotated(by: angle)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -naturalSize.width / 2, y: -naturalSize.height / 2)
        return t
    }

    private static func colorProperties(for track: VideoTrackInfo) -> [String: String] {
        var props: [String: String] = [:]
        if let primaries = track.colorPrimaries, !primaries.isEmpty {
            props[AVVideoColorPrimariesKey] = primaries
        }
        if let transfer = track.transferFunction, !transfer.isEmpty {
            props[AVVideoTransferFunctionKey] = transfer
        }
        if let matrix = track.matrix, !matrix.isEmpty {
            props[AVVideoYCbCrMatrixKey] = matrix
        }
        return props
    }
}