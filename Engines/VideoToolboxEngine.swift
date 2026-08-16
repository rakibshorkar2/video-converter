import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class VideoToolboxEngine: VideoConversionEngine {
    let identifier = EngineKind.videoToolbox

    func canHandle(_ request: ConversionRequest) async -> Bool {
        let config = request.configuration
        guard config.enginePreference == .videoToolbox else { return false }
        guard !config.streamCopy else { return false }
        guard AVFileType(container: config.outputContainer) != nil else { return false }
        guard config.videoCodec == .h264 || config.videoCodec == .hevc else { return false }
        guard FormatCapabilities.audioCodecEncodable(config.audioCodec) else { return false }
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
        guard let sourceFormatDescription = descriptions.first else {
            throw ConversionError.unreadableSource
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let sourceVideo = request.sourceMetadata.videoTrack

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: fileType)
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
                writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: trackDescriptions.first)
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
        writer.startSession(atSourceTime: .zero)
        guard writer.status == .writing else {
            writer.cancelWriting()
            reader.cancelReading()
            throw ConversionError.nativeEngineFailed(writer.error?.localizedDescription ?? L10n.errorWriterFailed)
        }

        let preserveHDR = config.preserveHDR && sourceVideo?.isHDR == true && config.videoCodec == .hevc
        let pixelFormat: OSType = preserveHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let outputCodec = config.videoCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        let decoder = try makeDecoder(
            sourceFormatDescription: sourceFormatDescription,
            pixelFormat: pixelFormat,
            hardwareRequested: config.hardwareAcceleration
        )
        let encoder = try makeEncoder(
            width: Int32(max(naturalSize.width, 16)),
            height: Int32(max(naturalSize.height, 16)),
            codecType: outputCodec,
            hardwareRequested: config.hardwareAcceleration
        )
        defer { VTDecompressionSessionInvalidate(decoder) }
        defer { VTCompressionSessionInvalidate(encoder) }
        let encoderUsesHardware = HardwareAcceleration.encoderUsesHardware(encoder)

        configureEncoder(encoder, config: config, source: request.sourceMetadata, nominalFPS: nominalFPS, preserveHDR: preserveHDR, sourceVideo: sourceVideo)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await VTPipelineDriver.run(
                        reader: reader,
                        writer: writer,
                        readerOutput: readerVideoOutput,
                        writerInput: writerVideoInput,
                        decoder: decoder,
                        encoder: encoder,
                        duration: duration,
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
            engine: .videoToolbox,
            usedStreamCopy: false,
            usedHardwareAcceleration: encoderUsesHardware,
            duration: duration.seconds,
            outputSize: FileStorageManager.fileSize(at: request.outputURL)
        )
    }

    private func makeDecoder(
        sourceFormatDescription: CMFormatDescription,
        pixelFormat: OSType,
        hardwareRequested: Bool
    ) throws -> VTDecompressionSession {
        let imageBufferAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        if hardwareRequested {
            var decoderSpec: [String: Any] = [:]
            if #available(iOS 17.4, *) {
                decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = true
            } else {
                decoderSpec["EnableHardwareAcceleratedVideoDecoder"] = true
            }
            var decoder: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil,
                formatDescription: sourceFormatDescription,
                decoderSpecification: decoderSpec as CFDictionary,
                imageBufferAttributes: imageBufferAttrs as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &decoder
            )
            if status == noErr, let decoder {
                return decoder
            }
        }
        var decoder: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: sourceFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decoder
        )
        guard status == noErr, let decoder else {
            throw ConversionError.engineUnavailable(L10n.errorDecoderUnavailable)
        }
        return decoder
    }

    private func makeEncoder(
        width: Int32,
        height: Int32,
        codecType: CMVideoCodecType,
        hardwareRequested: Bool
    ) throws -> VTCompressionSession {
        if hardwareRequested {
            var encoderSpec: [String: Any] = [:]
            if #available(iOS 17.4, *) {
                encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] = true
            } else {
                encoderSpec["EnableHardwareAcceleratedVideoEncoder"] = true
            }
            var encoder: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: width,
                height: height,
                codecType: codecType,
                encoderSpecification: encoderSpec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &encoder
            )
            if status == noErr, let encoder {
                return encoder
            }
        }
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard status == noErr, let encoder else {
            throw ConversionError.hardwareEncoderUnavailable
        }
        return encoder
    }

    private func configureEncoder(
        _ encoder: VTCompressionSession,
        config: ConversionConfiguration,
        source: MediaMetadata,
        nominalFPS: Double,
        preserveHDR: Bool,
        sourceVideo: VideoTrackInfo?
    ) {
        let profile = config.videoCodec == .hevc
            ? (preserveHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: profile as CFString)
        if let bitrate = SizeEstimator.suggestedVideoBitrate(config: config, source: source) {
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

private final class VTPipelineDriver: @unchecked Sendable {

    private static let maxBufferedSamples = 12
    private static let stallInterval: TimeInterval = 20

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let readerOutput: AVAssetReaderOutput
    private let writerInput: AVAssetWriterInput
    private let decoder: VTDecompressionSession
    private let encoder: VTCompressionSession
    private let duration: CMTime
    private let mediaName: String
    private let progress: (@Sendable (ConversionProgress) -> Void)?
    private let cancellation: CancellationToken
    private let throttle: ProgressThrottler
    private let continuation: CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var finished = false
    private var finalizing = false
    private var pipelineError: Error?
    private var sampleQueue: [CMSampleBuffer] = []
    private var decodeInFlight = false
    private var producerDone = false
    private var decodeCompleted = 0
    private var lastActivity = Date()
    private var watchdog: DispatchSourceTimer?
    private let capacity = DispatchSemaphore(value: VTPipelineDriver.maxBufferedSamples)

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        readerOutput: AVAssetReaderOutput,
        writerInput: AVAssetWriterInput,
        decoder: VTDecompressionSession,
        encoder: VTCompressionSession,
        duration: CMTime,
        mediaName: String,
        progress: (@Sendable (ConversionProgress) -> Void)?,
        cancellation: CancellationToken,
        throttle: ProgressThrottler,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.reader = reader
        self.writer = writer
        self.readerOutput = readerOutput
        self.writerInput = writerInput
        self.decoder = decoder
        self.encoder = encoder
        self.duration = duration
        self.mediaName = mediaName
        self.progress = progress
        self.cancellation = cancellation
        self.throttle = throttle
        self.continuation = continuation
        self.watchdog = nil
    }

    static func run(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        readerOutput: AVAssetReaderOutput,
        writerInput: AVAssetWriterInput,
        decoder: VTDecompressionSession,
        encoder: VTCompressionSession,
        duration: CMTime,
        mediaName: String,
        progress: (@Sendable (ConversionProgress) -> Void)?,
        cancellation: CancellationToken,
        throttle: ProgressThrottler
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let driver = VTPipelineDriver(
                reader: reader,
                writer: writer,
                readerOutput: readerOutput,
                writerInput: writerInput,
                decoder: decoder,
                encoder: encoder,
                duration: duration,
                mediaName: mediaName,
                progress: progress,
                cancellation: cancellation,
                throttle: throttle,
                continuation: continuation
            )
            driver.start()
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: MediaPump.pumpQueue)
        timer.schedule(deadline: .now() + Self.stallInterval, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        lock.lock()
        watchdog = timer
        lock.unlock()
        timer.resume()
        MediaPump.pumpQueue.async { [weak self] in
            self?.produce()
        }
    }

    private func produce() {
        while !isFinished {
            if cancellation.isCancelled {
                fail(.cancelled)
                return
            }
            if capacity.wait(timeout: .now() + 1) == .timedOut {
                if isFinished { return }
                continue
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                handleReaderExhausted()
                return
            }
            lock.lock()
            sampleQueue.append(sample)
            lastActivity = Date()
            let shouldKick = !decodeInFlight
            lock.unlock()
            if shouldKick {
                kickDecode()
            }
        }
    }

    private func handleReaderExhausted() {
        switch reader.status {
        case .completed:
            lock.lock()
            producerDone = true
            lock.unlock()
            kickDecode()
            maybeFinish()
        case .failed:
            fail(.pipelineFailure("\(mediaName): reader failed: \(reader.error?.localizedDescription ?? "unknown")"))
        case .cancelled:
            fail(.cancelled)
        case .unknown, .reading:
            var attempts = 0
            while !isFinished {
                attempts += 1
                if attempts > 100 {
                    fail(.pipelineFailure("\(mediaName): reader did not complete (status \(reader.status.rawValue))"))
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
                switch reader.status {
                case .completed:
                    lock.lock()
                    producerDone = true
                    lock.unlock()
                    kickDecode()
                    maybeFinish()
                    return
                case .failed:
                    fail(.pipelineFailure("\(mediaName): reader failed: \(reader.error?.localizedDescription ?? "unknown")"))
                    return
                case .cancelled:
                    fail(.cancelled)
                    return
                default:
                    break
                }
            }
        }
    }

    private func kickDecode() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if finalizing || decodeInFlight || sampleQueue.isEmpty {
            lock.unlock()
            maybeFinish()
            return
        }
        decodeInFlight = true
        let sample = sampleQueue.removeFirst()
        lock.unlock()

        let decodeResult = VTDecompressionSessionDecodeFrame(
            decoder,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, pts, frameDuration in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.fail(.encodeFailed(L10n.errorDecodeFailed))
                return
            }
            let encodeResult = VTCompressionSessionEncodeFrame(
                self.encoder,
                imageBuffer: imageBuffer,
                presentationTimeStamp: pts,
                duration: frameDuration,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { [weak self] encStatus, _, encodedBuffer in
                guard let self else { return }
                if encStatus == noErr, let encodedBuffer {
                    self.appendEncoded(encodedBuffer)
                } else {
                    self.fail(.encodeFailed(L10n.errorEncodeFailed))
                }
            }
            if encodeResult != noErr {
                self.fail(.encodeFailed(L10n.errorEncodeFailed))
                return
            }
            if pts.isNumeric, self.duration.isNumeric, self.duration.seconds > 0 {
                self.throttle.report(
                    processed: pts.seconds,
                    duration: self.duration.seconds,
                    stage: .encoding,
                    progress: self.progress
                )
            }
        }
        if decodeResult != noErr {
            fail(.encodeFailed(L10n.errorDecodeFailed))
        }
    }

    private func appendEncoded(_ buffer: CMSampleBuffer) {
        guard !isFinished else { return }
        guard writerInput.append(buffer) else {
            fail(.pipelineFailure("\(mediaName): writer append rejected after \(decodeCompleted) frames; writer status \(writer.status.rawValue), writer error \(writer.error?.localizedDescription ?? "none")"))
            return
        }
        lock.lock()
        decodeCompleted += 1
        lastActivity = Date()
        let isFinalizing = finalizing
        lock.unlock()
        capacity.signal()
        if !isFinalizing {
            kickDecode()
        }
    }

    private func maybeFinish() {
        lock.lock()
        guard !finished, !finalizing, producerDone, sampleQueue.isEmpty, !decodeInFlight else {
            lock.unlock()
            return
        }
        finalizing = true
        lock.unlock()

        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)

        guard !isFinished else { return }
        writerInput.markAsFinished()
        finish(.success(()))
    }

    private func watchdogTick() {
        guard !isFinished else { return }
        let silence: TimeInterval
        lock.lock()
        silence = Date().timeIntervalSince(lastActivity)
        lock.unlock()
        guard silence > Self.stallInterval else { return }
        fail(.engineStalled(
            "VideoToolbox pipeline stalled for \(Int(silence))s after \(decodeCompleted) frames (\(mediaName)); writer status \(writer.status.rawValue), writer error \(writer.error?.localizedDescription ?? "none")"
        ))
    }

    private func fail(_ error: ConversionError) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(throwing: error)
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(with: result)
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}