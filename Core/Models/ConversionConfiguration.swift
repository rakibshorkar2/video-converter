import Foundation
import CoreGraphics

enum OutputContainer: String, Codable, CaseIterable, Sendable {
    case mp4
    case mov
    case m4v
    case mkv
    case webm
    case avi

    var displayName: String { rawValue.uppercased() }
}

enum VideoCodecOption: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
    case vp9
    case av1
    case vp8
    case mpeg4

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        case .vp8: return "VP8"
        case .mpeg4: return "MPEG-4 Part 2"
        }
    }

    var isFFmpegOnly: Bool {
        switch self {
        case .h264, .hevc: return false
        case .vp9, .av1, .vp8, .mpeg4: return true
        }
    }
}

enum AudioCodecOption: String, Codable, CaseIterable, Sendable {
    case copy
    case none
    case aac
    case alac
    case opus
    case flac
    case mp3
    case pcm

    var displayName: String {
        switch self {
        case .copy: return L10n.audioCopy
        case .none: return L10n.audioRemove
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .pcm: return "PCM"
        }
    }

    var isFFmpegOnly: Bool {
        switch self {
        case .opus, .flac, .mp3: return true
        default: return false
        }
    }
}

enum ResolutionOption: String, Codable, CaseIterable, Sendable {
    case original
    case uhd8k
    case uhd4k
    case qhd1440
    case fhd1080
    case hd720
    case sd480
    case sd360
    case custom

    var displayName: String {
        switch self {
        case .original: return L10n.resolutionOriginal
        case .uhd8k: return "8K (7680p)"
        case .uhd4k: return "4K (2160p)"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .sd360: return "360p"
        case .custom: return L10n.resolutionCustom
        }
    }

    var pixelHeight: Int? {
        switch self {
        case .original: return nil
        case .uhd8k: return 7680
        case .uhd4k: return 2160
        case .qhd1440: return 1440
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        case .sd360: return 360
        case .custom: return nil
        }
    }

    func resolvedSize(for sourceSize: CGSize) -> CGSize {
        guard let targetHeight = pixelHeight else { return sourceSize }
        guard sourceSize.width > 0, sourceSize.height > 0 else { return sourceSize }
        let scale = CGFloat(targetHeight) / sourceSize.height
        if scale >= 1 { return sourceSize }
        return CGSize(width: (sourceSize.width * scale).rounded(), height: (sourceSize.height * scale).rounded())
    }
}

enum FrameRateOption: String, Codable, CaseIterable, Sendable {
    case original
    case fps24
    case fps25
    case fps30
    case fps50
    case fps60

    var displayName: String {
        switch self {
        case .original: return L10n.frameRateOriginal
        default: return "\(value) fps"
        }
    }

    var value: Double? {
        switch self {
        case .original: return nil
        case .fps24: return 24
        case .fps25: return 25
        case .fps30: return 30
        case .fps50: return 50
        case .fps60: return 60
        }
    }

    func resolvedValue(original: Double?) -> Double? {
        value ?? original
    }
}

enum AudioTrackSelection: String, Codable, CaseIterable, Sendable {
    case all
    case first
    case none

    var displayName: String {
        switch self {
        case .all: return L10n.audioTracksAll
        case .first: return L10n.audioTracksFirst
        case .none: return L10n.audioTracksNone
        }
    }
}

enum EnginePreference: String, Codable, CaseIterable, Sendable {
    case auto
    case videoToolbox
    case ffmpeg

    var displayName: String {
        switch self {
        case .auto: return L10n.engineAuto
        case .videoToolbox: return L10n.engineVideoToolbox
        case .ffmpeg: return L10n.engineFFmpeg
        }
    }
}

enum ConversionPreset: String, Codable, CaseIterable, Sendable {
    case lossless
    case maximum
    case high
    case balanced
    case smaller
    case custom

    var displayName: String {
        switch self {
        case .lossless: return L10n.presetLossless
        case .maximum: return L10n.presetMaximum
        case .high: return L10n.presetHigh
        case .balanced: return L10n.presetBalanced
        case .smaller: return L10n.presetSmaller
        case .custom: return L10n.presetCustom
        }
    }
}

struct ConversionConfiguration: Codable, Equatable, Sendable {
    var outputContainer: OutputContainer = .mp4
    var videoCodec: VideoCodecOption = .h264
    var audioCodec: AudioCodecOption = .aac
    var streamCopy: Bool = false
    var resolution: ResolutionOption = .original
    var frameRate: FrameRateOption = .original
    var qualityFactor: Double = 0.7
    var videoBitrateOverrideMbps: Double?
    var audioBitrate: Int = 128_000
    var audioSampleRate: Int = 48_000
    var audioChannels: Int = 2
    var audioTrackSelection: AudioTrackSelection = .all
    var preserveMetadata: Bool = true
    var preserveHDR: Bool = true
    var hardwareAcceleration: Bool = true
    var customFilename: String?
    var enginePreference: EnginePreference = .auto

    static func preset(_ preset: ConversionPreset, sourceCodec: VideoCodecOption) -> ConversionConfiguration {
        var config = ConversionConfiguration()
        switch preset {
        case .lossless:
            config.streamCopy = true
            config.videoCodec = sourceCodec
            config.audioCodec = .copy
            config.qualityFactor = 1.0
        case .maximum:
            config.videoCodec = sourceCodec
            config.audioCodec = .aac
            config.qualityFactor = 1.0
        case .high:
            config.videoCodec = sourceCodec
            config.audioCodec = .aac
            config.qualityFactor = 0.85
        case .balanced:
            config.videoCodec = sourceCodec
            config.audioCodec = .aac
            config.qualityFactor = 0.65
        case .smaller:
            config.videoCodec = sourceCodec
            config.audioCodec = .aac
            config.qualityFactor = 0.45
            if config.resolution == .original {
                config.resolution = .fhd1080
            }
        case .custom:
            break
        }
        return config
    }
}