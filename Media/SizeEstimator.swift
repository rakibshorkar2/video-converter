import Foundation
import CoreGraphics

enum SizeEstimator {

    static func codecFactor(source: VideoTrackInfo?, target: VideoCodecOption) -> Double {
        guard let source else { return 1.0 }
        let srcIsH264 = source.isH264
        let srcIsHEVC = source.isHEVC
        switch target {
        case .h264:
            if srcIsHEVC { return 1.7 }
            return 1.0
        case .hevc:
            if srcIsH264 { return 0.55 }
            return 1.0
        case .mpeg4:
            return 1.3
        default:
            return 1.0
        }
    }

    static func suggestedVideoBitrate(config: ConversionConfiguration, source: MediaMetadata) -> Int64? {
        guard let video = source.videoTrack, let sourceBitrate = video.bitrate, sourceBitrate > 0 else { return nil }
        if let override = config.videoBitrateOverrideMbps, override > 0 {
            return Int64(override * 1_000_000)
        }
        let factor = codecFactor(source: video, target: config.videoCodec)
        let targetSize = config.resolution.resolvedSize(for: CGSize(width: video.naturalWidth, height: video.naturalHeight))
        let sourcePixels = Double(video.naturalWidth * video.naturalHeight)
        let targetPixels = Double(targetSize.width * targetSize.height)
        let resFactor = sourcePixels > 0 && targetPixels < sourcePixels ? targetPixels / sourcePixels : 1.0
        let sourceFPS = video.frameRate
        let targetFPS = config.frameRate.resolvedValue(original: sourceFPS) ?? sourceFPS
        let fpsFactor = sourceFPS > 0 && targetFPS > 0 && targetFPS < sourceFPS ? targetFPS / sourceFPS : 1.0
        return Int64(Double(sourceBitrate) * factor * resFactor * fpsFactor * config.qualityFactor)
    }

    static func estimatedOutputBytes(config: ConversionConfiguration, source: MediaMetadata) -> Int64 {
        let duration = max(source.duration, 0)

        var videoBytes: Int64 = 0
        if let bitrate = suggestedVideoBitrate(config: config, source: source) {
            videoBytes = Int64(Double(bitrate) / 8.0 * duration)
        } else if let src = source.videoTrack, let srcBitrate = src.bitrate {
            videoBytes = Int64(Double(srcBitrate) / 8.0 * duration)
        }

        var audioBytes: Int64 = 0
        switch config.audioCodec {
        case .none:
            audioBytes = 0
        case .copy:
            for track in source.audioTracks {
                if let bitrate = track.bitrate {
                    audioBytes += Int64(Double(bitrate) / 8.0 * duration)
                }
            }
        default:
            audioBytes = Int64(Double(config.audioBitrate) / 8.0 * duration)
        }

        if config.streamCopy {
            return videoBytes + audioBytes
        }
        return videoBytes + audioBytes
    }

    static func requiredStorage(bytes: Int64, sourceSize: Int64) -> Int64 {
        max(bytes, 0) * 2 + sourceSize + 512 * 1024 * 1024
    }
}