import Foundation
import AVFoundation
import CoreGraphics

#if FFMPEG_ENABLED

private let ffmpegWorkerQueue = DispatchQueue(label: "com.videoconverter.ffmpeg", qos: .userInitiated)

private final class FFmpegCallbackBox: @unchecked Sendable {
    let progress: @Sendable (ConversionProgress) -> Void
    let throttle = ProgressThrottler()
    private let lock = NSLock()
    private var _done = false

    init(progress: @escaping @Sendable (ConversionProgress) -> Void) {
        self.progress = progress
    }

    func markDone() {
        lock.lock()
        _done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _done
    }

    func handle(progressPointer: UnsafePointer<FFpegProgress>?) {
        guard let pointer = progressPointer else { return }
        let p = pointer.pointee
        let processed = Double(p.processedMicros) / 1_000_000.0
        let total = Double(p.totalMicros) / 1_000_000.0
        let stageText = p.stage.map { String(cString: $0) } ?? ""
        let stage: ConversionStage = stageText.contains("final") ? .finalizing : .encoding
        throttle.report(processed: processed, duration: total, stage: stage, progress: progress)
    }
}

final class FFmpegEngine: VideoConversionEngine {
    let identifier = EngineKind.ffmpeg

    func canHandle(_ request: ConversionRequest) async -> Bool {
        let config = request.configuration
        if config.streamCopy {
            return FormatCapabilities.canStreamCopy(source: request.sourceMetadata, to: config.outputContainer)
        }
        if config.videoCodec.isFFmpegOnly || config.audioCodec.isFFmpegOnly {
            return true
        }
        if FormatCapabilities.containerRequiresFFmpeg(config.outputContainer) {
            return true
        }
        return false
    }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        let config = request.configuration
        guard let ctx = ffpeg_context_create() else {
            throw ConversionError.ffmpegFailed("FFmpeg context creation failed")
        }
        defer { ffpeg_context_destroy(ctx) }

        let analysis = FFmpegEngine.analyzeSync(url: request.sourceURL)
        guard let analysis else {
            throw ConversionError.ffmpegFailed(ffpeg_last_error(ctx).map { String(cString: $0) } ?? "FFmpeg analysis failed")
        }
        guard let videoIndex = analysis.videoStreamIndex else {
            throw ConversionError.noVideoTrack
        }
        let audioIndices = analysis.audioStreamIndices

        var opts = FFpegConversionOptions(
            videoStreamIndex: -1,
            audioStreamIndex: -1,
            videoCodecId: 0,
            audioCodecId: 0,
            useHardwareVideo: 0,
            videoBitrate: 0,
            audioBitrate: 0,
            width: 0,
            height: 0,
            frameRate: 0,
            sampleRate: 0,
            channels: 0,
            copyMetadata: config.preserveMetadata ? 1 : 0,
            fastStart: config.enginePreference == .ffmpeg ? 1 : 0,
            copyOnlyFirstAudioStream: 0
        )

        if config.streamCopy {
            opts.videoStreamIndex = -1
            opts.copyOnlyFirstAudioStream = config.audioTrackSelection == .first ? 1 : 0
            if config.audioCodec == .none || config.audioTrackSelection == .none {
                opts.audioStreamIndex = -2
            } else {
                opts.audioStreamIndex = -1
            }
        } else {
            opts.videoStreamIndex = Int32(videoIndex)
            opts.videoCodecId = Self.videoCodecID(config.videoCodec)
            if config.videoCodec.isFFmpegOnly && !FormatCapabilities.videoCodecEncodable(config.videoCodec) {
                throw ConversionError.unsupportedCombination(
                    String(format: L10n.errorEncoderNotIncluded, config.videoCodec.displayName)
                )
            }
            if config.audioCodec == .none {
                opts.audioStreamIndex = -2
            } else if config.audioCodec == .copy {
                opts.audioStreamIndex = -1
                opts.copyOnlyFirstAudioStream = config.audioTrackSelection == .first ? 1 : 0
            } else if let firstAudio = audioIndices.first {
                opts.audioStreamIndex = Int32(firstAudio)
                opts.audioCodecId = Self.audioCodecID(config.audioCodec)
                if !FormatCapabilities.audioCodecEncodable(config.audioCodec) {
                    throw ConversionError.unsupportedCombination(
                        String(format: L10n.errorEncoderNotIncluded, config.audioCodec.displayName)
                    )
                }
            } else {
                opts.audioStreamIndex = -2
            }
            if let size = Self.targetSize(config: config, source: analysis) {
                opts.width = Int32(size.width)
                opts.height = Int32(size.height)
            }
            if let fps = config.frameRate.value {
                opts.frameRate = fps
            }
            if let bitrate = SizeEstimator.suggestedVideoBitrate(config: config, source: analysis.metadata) {
                opts.videoBitrate = bitrate
            }
            if config.audioCodec != .copy && config.audioCodec != .none {
                opts.audioBitrate = Int64(config.audioBitrate)
                opts.sampleRate = Int32(config.audioSampleRate)
                opts.channels = Int32(config.audioChannels)
            }
            opts.useHardwareVideo = config.hardwareAcceleration ? 1 : 0
        }

        let box = FFmpegCallbackBox(progress: progress)
        let inputPath = request.sourceURL.path
        let outputPath = request.outputURL.path

        let cCallback: FFpegProgressCallback = { userData, progressPointer in
            guard let userData else { return }
            let box = Unmanaged<FFmpegCallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.handle(progressPointer: progressPointer)
        }

        let cancelMonitor = Task {
            while !box.isDone {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if cancellation.isCancelled {
                    ffpeg_cancel(ctx)
                    return
                }
            }
        }

        let resultCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            ffmpegWorkerQueue.async {
                let result = withUnsafePointer(to: &opts) { optsPointer in
                    ffpeg_convert(
                        ctx,
                        inputPath,
                        outputPath,
                        optsPointer,
                        cCallback,
                        Unmanaged.passUnretained(box).toOpaque()
                    )
                }
                box.markDone()
                continuation.resume(returning: result)
            }
        }
        cancelMonitor.cancel()

        if cancellation.isCancelled {
            throw ConversionError.cancelled
        }
        if resultCode < 0 {
            let detail = ffpeg_last_error(ctx).map { String(cString: $0) } ?? "FFmpeg error \(resultCode)"
            if detail.contains("cancelled") {
                throw ConversionError.cancelled
            }
            throw ConversionError.ffmpegFailed(detail)
        }

        return ConversionResult(
            outputURL: request.outputURL,
            engine: .ffmpeg,
            usedStreamCopy: config.streamCopy,
            usedHardwareAcceleration: config.hardwareAcceleration,
            duration: analysis.metadata.duration,
            outputSize: FileStorageManager.fileSize(at: request.outputURL)
        )
    }

    private static func videoCodecID(_ codec: VideoCodecOption) -> Int32 {
        switch codec {
        case .h264: return 0
        case .hevc: return 1
        case .vp9: return 2
        case .av1: return 3
        case .mpeg4: return 4
        case .vp8: return 5
        }
    }

    private static func audioCodecID(_ codec: AudioCodecOption) -> Int32 {
        switch codec {
        case .aac: return 0
        case .opus: return 1
        case .flac: return 2
        case .mp3: return 3
        case .pcm: return 4
        case .alac: return 5
        default: return 0
        }
    }

    private static func targetSize(config: ConversionConfiguration, source: FFmpegAnalysis) -> CGSize? {
        guard let video = source.metadata.videoTrack else { return nil }
        let sourceSize = CGSize(width: video.naturalWidth, height: video.naturalHeight)
        let resolved = config.resolution.resolvedSize(for: sourceSize)
        guard abs(resolved.width - sourceSize.width) > 1 || abs(resolved.height - sourceSize.height) > 1 else {
            return nil
        }
        return resolved
    }

    static func analyze(url: URL) async -> FFmpegAnalysis? {
        await withCheckedContinuation { continuation in
            ffmpegWorkerQueue.async {
                continuation.resume(returning: analyzeSync(url: url))
            }
        }
    }

    private static func analyzeSync(url: URL) -> FFmpegAnalysis? {
        guard let ctx = ffpeg_context_create() else { return nil }
        defer { ffpeg_context_destroy(ctx) }
        var streamsPointer: UnsafeMutablePointer<FFpegStreamInfo>?
        var count: Int32 = 0
        let result = ffpeg_analyze(ctx, url.path, &streamsPointer, &count)
        guard result == 0, let streamsPointer else { return nil }
        defer { ffpeg_free_streams(streamsPointer, count) }

        var videoStreamIndex: Int?
        var audioStreamIndices: [Int] = []
        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        var subtitleTracks: [SubtitleTrackInfo] = []
        var duration: TimeInterval = 0

        for i in 0..<Int(count) {
            let stream = streamsPointer[i]
            let codecName = stream.codecName.map { String(cString: $0) } ?? "unknown"
            switch Int(stream.type) {
            case 0:
                if videoStreamIndex == nil { videoStreamIndex = Int(stream.index) }
                let codec = VideoCodecName.codecName(fromFFmpegName: codecName)
                videoTracks.append(VideoTrackInfo(
                    codecName: codec,
                    codecType: codecName,
                    naturalWidth: Int(stream.width),
                    naturalHeight: Int(stream.height),
                    displayWidth: Int(stream.width),
                    displayHeight: Int(stream.height),
                    frameRate: stream.frameRate,
                    bitrate: stream.bitrate > 0 ? Int64(stream.bitrate) : nil,
                    rotation: 0,
                    colorPrimaries: nil,
                    transferFunction: nil,
                    matrix: nil,
                    is10Bit: false,
                    isHDR10: false,
                    isHLG: false,
                    isDolbyVision: false
                ))
                duration = max(duration, Double(stream.durationMicros) / 1_000_000.0)
            case 1:
                audioStreamIndices.append(Int(stream.index))
                audioTracks.append(AudioTrackInfo(
                    codecName: codecName,
                    codecType: codecName,
                    bitrate: stream.bitrate > 0 ? Int64(stream.bitrate) : nil,
                    sampleRate: Double(stream.sampleRate),
                    channels: Int(stream.channels)
                ))
            default:
                subtitleTracks.append(SubtitleTrackInfo(codecName: codecName, codecType: codecName))
            }
        }

        let fileSize = FileStorageManager.fileSize(at: url)
        let metadata = MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            creationDate: nil,
            isPlayable: true,
            sourceFileExtension: url.pathExtension.lowercased()
        )
        return FFmpegAnalysis(videoStreamIndex: videoStreamIndex, audioStreamIndices: audioStreamIndices, metadata: metadata)
    }
}

struct FFmpegAnalysis {
    let videoStreamIndex: Int?
    let audioStreamIndices: [Int]
    let metadata: MediaMetadata
}

private enum VideoCodecName {
    static func codecName(fromFFmpegName name: String) -> String {
        let n = name.lowercased()
        if n.contains("h264") || n.contains("avc") { return "H.264" }
        if n.contains("hevc") || n.contains("h265") { return "HEVC" }
        if n.contains("vp9") { return "VP9" }
        if n.contains("av1") { return "AV1" }
        if n.contains("vp8") { return "VP8" }
        if n.contains("mpeg4") { return "MPEG-4 Part 2" }
        return name
    }
}

#endif