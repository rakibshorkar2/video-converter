import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoToolboxEngine: VideoConversionEngine {
    let identifier = EngineKind.videoToolbox

    private let pipelineQueue = DispatchQueue(label: "com.videoconverter.vt.pipeline", qos: .userInitiated)
    private let appendQueue = DispatchQueue(label: "com.videoconverter.vt.append", qos: .userInitiated)

    func canHandle(_ request: ConversionRequest) async -> Bool {
        let config = request.configuration
        guard !config.streamCopy else { return false }
        guard AVFileType(container: config.outputContainer) != nil else { return false }
        guard config.videoCodec == .h264 || config.videoCodec == .hevc else { return false }
        if let src = request.sourceMetadata.videoTrack {
            let sourceSize = CGSize(width: src.naturalWidth, height: src.naturalHeight)
            let target = config.resolution.resolvedSize(for: sourceSize)
            if abs(target.width - sourceSize.width) > 1 || abs(target.height - sourceSize.height) > 1 {
                return false
            }
            let sourceFPS = src.frameRate
            if let targetFPS = config.frameRate.resolvedValue(original: sourceFPS), sourceFPS > 0, abs(targetFPS - sourceFPS) > 0.5 {
                return false
            }
        }
        return true
    }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        let config = request.configuration
        guard let fileType = AVFileType(container: config.outputContainer) else {
            throw ConversionError.unsupportedCombination("\(config.outputContainer.displayName) requires FFmpeg")
        }

        let asset = AVURLAsset(url: request.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw ConversionError.noVideoTrack }

        let descriptions = try await videoTrack.load(.formatDescriptions)
        guard let sourceFormatDescription = descriptions.first as? CMFormatDescription else {
            throw ConversionError.unreadableSource
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let sourceVideo = request.sourceMetadata.videoTrack

        let reader = try AVAssetReader(asset: asset)
        guard let writer = AVAssetWriter(outputURL: request.outputURL, fileType: fileType) else {
            throw ConversionError.unsupportedCombination(config.outputContainer.displayName)
        }
        let throttle = ProgressThrottler()

        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        readerVideoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerVideoOutput) else { throw ConversionError.nativeEngineFailed(L10n.errorReaderOutput) }
        reader.add(readerVideoOutput)

        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        writerVideoInput.expectsMediaDataInRealTime = false
        writerVideoInput.transform = preferredTransform
        guard writer.canAdd(writerVideoInput) else { throw ConversionError.nativeEngineFailed(L10n.errorWriterInput) }
        writer.add(writerVideoInput)

        let selectedAudioTracks = selectedAudioTracks(audioTracks, selection: config.audioTrackSelection, audioCodec: config.audioCodec)
        var audioPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        for track in selectedAudioTracks {
            let trackDescriptions = try await track.load(.formatDescriptions)
            let readerOutput: AVAssetReaderOutput
            let writerInput: AVAssetWriterInput
            if config.audioCodec == .copy {
                readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: trackDescriptions.first as? CMFormatDescription)
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
            writer.metadata = (try? await asset.loadMetadata(for: .common)) ?? []
        }

        guard reader.startReading() else {
            throw ConversionError.nativeEngineFailed(reader.error?.localizedDescription ?? L10n.errorReaderStart)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let preserveHDR = config.preserveHDR && sourceVideo?.isHDR == true && config.videoCodec == .hevc
        let pixelFormat: OSType = preserveHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let outputCodec = config.videoCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        var decoder: VTDecompressionSession?
        var decoderSpec: [String: Any] = [:]
        if config.hardwareAcceleration {
            decoderSpec[kVTDecompressionPropertyKey_EnableHardwareAcceleratedVideoDecoder as String] = true
        }
        let imageBufferAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        let decodeStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: sourceFormatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: imageBufferAttrs as CFDictionary,
            outputCallback: nil,
            refcon: nil,
            decompressionSessionOut: &decoder
        )
        guard decodeStatus == noErr, let decoder else {
            writer.cancelWriting()
            reader.cancelReading()
            throw ConversionError.engineUnavailable(L10n.errorDecoderUnavailable)
        }
        defer { VTDecompressionSessionInvalidate(decoder) }

        var encoder: VTCompressionSession?
        var encoderSpec: [String: Any] = [:]
        if config.hardwareAcceleration {
            encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] = true
            encoderSpec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        let encodeStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(max(naturalSize.width, 16)),
            height: Int32(max(naturalSize.height, 16)),
            codecType: outputCodec,
            encoderSpecification: encoderSpec as CFDictionary,
            sourceImageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard encodeStatus == noErr, let encoder else {
            writer.cancelWriting()
            reader.cancelReading()
            throw ConversionError.hardwareEncoderUnavailable
        }
        defer { VTCompressionSessionInvalidate(encoder) }

        let profile = config.videoCodec == .hevc
            ? (preserveHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: profile as CFString)
        if let bitrate = SizeEstimator.suggestedVideoBitrate(config: config, source: request.sourceMetadata) {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        }
        if let fps = config.frameRate.resolvedValue(original: nominalFPS) {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int(fps * 2)))
        }
        if preserveHDR, let sv = sourceVideo {
            if let p = sv.colorPrimaries { VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ColorPrimaries, value: p as CFString) }
            if let t = sv.transferFunction { VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_TransferFunction, value: t as CFString) }
            if let m = sv.matrix { VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_YCbCrMatrix, value: m as CFString) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pipelineQueue.async {
                let appendGroup = DispatchGroup()
                var pipelineError: Error?

                func fail(_ error: Error) {
                    if pipelineError == nil { pipelineError = error }
                }

                VTCompressionSessionPrepareToEncodeFrames(encoder)

                while !cancellation.isCancelled {
                    guard let sampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                        break
                    }
                    let decodeResult = VTDecompressionSessionDecodeFrame(
                        decoder,
                        sampleBuffer,
                        flags: [],
                        infoFlagsOut: nil
                    ) { status, _, imageBuffer, pts, frameDuration in
                        guard status == noErr, let imageBuffer else {
                            fail(ConversionError.nativeEngineFailed(L10n.errorDecodeFailed))
                            return
                        }
                        appendGroup.enter()
                        let encodeStatus = VTCompressionSessionEncodeFrame(
                            encoder,
                            imageBuffer: imageBuffer,
                            presentationTimeStamp: pts,
                            duration: frameDuration,
                            frameProperties: nil,
                            infoFlagsOut: nil
                        ) { encStatus, _, encodedSampleBuffer in
                            self.appendQueue.async {
                                if encStatus == noErr, let encodedSampleBuffer {
                                    writerVideoInput.append(encodedSampleBuffer)
                                } else {
                                    fail(ConversionError.hardwareEncoderUnavailable)
                                }
                                appendGroup.leave()
                            }
                        }
                        if encodeStatus != noErr {
                            fail(ConversionError.hardwareEncoderUnavailable)
                            appendGroup.leave()
                        }
                        if pts.isNumeric, duration.isNumeric, duration.seconds > 0 {
                            throttle.report(processed: pts.seconds, duration: duration.seconds, stage: .encoding, progress: progress)
                        }
                    }
                    if decodeResult != noErr {
                        fail(ConversionError.nativeEngineFailed(L10n.errorDecodeFailed))
                        break
                    }
                }

                if pipelineError == nil && !cancellation.isCancelled {
                    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                    appendGroup.wait()
                }

                if cancellation.isCancelled {
                    cont.resume(throwing: ConversionError.cancelled)
                    return
                }
                if let pipelineError {
                    cont.resume(throwing: pipelineError)
                    return
                }
                writerVideoInput.markAsFinished()
                cont.resume(returning: ())
            }
        }

        do {
            for (output, input) in audioPairs {
                try await MediaPump.run(
                    output: output,
                    input: input,
                    duration: duration,
                    stage: .encoding,
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
            engine: .videoToolbox,
            usedStreamCopy: false,
            usedHardwareAcceleration: true,
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