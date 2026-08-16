import Foundation

enum FormatCapabilities {

    static var isFFmpegEnabled: Bool {
        #if FFMPEG_ENABLED
        return true
        #else
        return false
        #endif
    }

    static let nativeContainers: [OutputContainer] = [.mp4, .mov, .m4v]
    static let ffmpegContainers: [OutputContainer] = [.mkv, .webm, .avi]

    static func containerRequiresFFmpeg(_ container: OutputContainer) -> Bool {
        !nativeContainers.contains(container)
    }

    static func availableOutputContainers() -> [OutputContainer] {
        if isFFmpegEnabled {
            return [.mp4, .mov, .m4v, .mkv, .webm, .avi]
        }
        return nativeContainers
    }

    static func videoCodecAvailable(_ codec: VideoCodecOption) -> Bool {
        if codec.isFFmpegOnly { return isFFmpegEnabled }
        return true
    }

    static func audioCodecAvailable(_ codec: AudioCodecOption) -> Bool {
        if codec.isFFmpegOnly { return isFFmpegEnabled }
        return true
    }

    static func videoCodecEncodable(_ codec: VideoCodecOption) -> Bool {
        switch codec {
        case .h264, .hevc:
            return true
        case .vp9, .av1, .vp8:
            return false
        case .mpeg4:
            return isFFmpegEnabled
        }
    }

    static func audioCodecEncodable(_ codec: AudioCodecOption) -> Bool {
        switch codec {
        case .aac, .alac, .pcm:
            return true
        case .flac:
            return isFFmpegEnabled
        case .opus, .mp3:
            return false
        case .copy, .none:
            return true
        }
    }

    static func videoCopyable(to container: OutputContainer, codecType: String, ffmpegEnabled: Bool = FormatCapabilities.isFFmpegEnabled) -> Bool {
        let c = codecType.lowercased()
        let isH264 = ["avc1", "avc3", "h264"].contains(c)
        let isHEVC = ["hvc1", "hev1"].contains(c)
        let isDolbyVision = ["dvh1", "dvhe", "dva1", "dvh5"].contains(c)
        let isMPEG4 = c == "mp4v"
        let isVP8 = c == "vp08"
        let isVP9 = c == "vp09"
        let isAV1 = c == "av01"
        let isProRes = c.hasPrefix("ap")

        switch container {
        case .mp4:
            return isH264 || isHEVC || isDolbyVision || isMPEG4 || isProRes
        case .mov:
            return isH264 || isHEVC || isDolbyVision || isMPEG4 || isProRes
        case .m4v:
            return isH264 || isHEVC || isDolbyVision
        case .mkv:
            return ffmpegEnabled && (isH264 || isHEVC || isMPEG4 || isVP8 || isVP9 || isAV1)
        case .webm:
            return ffmpegEnabled && (isVP8 || isVP9 || isAV1)
        case .avi:
            return ffmpegEnabled && (isH264 || isMPEG4)
        }
    }

    static func audioCopyable(to container: OutputContainer, codecType: String, ffmpegEnabled: Bool = FormatCapabilities.isFFmpegEnabled) -> Bool {
        let c = codecType.lowercased()
        let isAAC = c == "aac "
        let isALAC = c == "alac"
        let isMP3 = c == ".mp3"
        let isOpus = c == "opus"
        let isVorbis = c == "vorb"
        let isFLAC = c == "flac"
        let isPCM = ["lpcm", "fl64", "fl32", "sowt", "twos", "in24", "in32"].contains(c)
        let isAC3 = c == "ac-3"
        let isEAC3 = c == "ec-3"

        switch container {
        case .mp4:
            return isAAC || isALAC || isMP3 || isFLAC || isEAC3
        case .mov:
            return isAAC || isALAC || isMP3 || isPCM || isAC3 || isEAC3
        case .m4v:
            return isAAC || isALAC || isMP3
        case .mkv:
            return ffmpegEnabled && (isAAC || isALAC || isMP3 || isOpus || isVorbis || isFLAC || isPCM || isAC3 || isEAC3)
        case .webm:
            return ffmpegEnabled && (isOpus || isVorbis)
        case .avi:
            return ffmpegEnabled && (isMP3 || isPCM || isAC3)
        }
    }

    static func canStreamCopy(source: MediaMetadata, to container: OutputContainer) -> Bool {
        let ffmpeg = isFFmpegEnabled
        if let video = source.videoTrack {
            guard videoCopyable(to: container, codecType: video.codecType, ffmpegEnabled: ffmpeg) else { return false }
        }
        for audio in source.audioTracks {
            guard audioCopyable(to: container, codecType: audio.codecType, ffmpegEnabled: ffmpeg) else { return false }
        }
        return true
    }

    static func containerSupportsVideoCodec(_ container: OutputContainer, codec: VideoCodecOption) -> Bool {
        switch codec {
        case .h264, .hevc:
            return !containerRequiresFFmpeg(container) || isFFmpegEnabled
        case .vp8, .vp9, .av1:
            return container == .mkv || container == .webm
        case .mpeg4:
            return container != .webm
        }
    }

    static func containerSupportsAudioCodec(_ container: OutputContainer, codec: AudioCodecOption) -> Bool {
        switch codec {
        case .copy, .none:
            return true
        case .aac:
            return !containerRequiresFFmpeg(container) || isFFmpegEnabled
        case .alac:
            return container == .mp4 || container == .mov || container == .m4v || container == .mkv
        case .pcm:
            return container == .mov || container == .mkv || container == .avi
        case .opus:
            return container == .mkv || container == .webm
        case .flac:
            return container == .mkv || container == .mp4
        case .mp3:
            return container == .mkv || container == .mp4 || container == .mov || container == .avi
        }
    }

    static func outputFileExtension(for container: OutputContainer) -> String {
        container.rawValue
    }
}