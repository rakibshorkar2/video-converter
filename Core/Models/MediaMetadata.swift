import Foundation

struct VideoTrackInfo: Codable, Sendable, Equatable {
    var codecName: String
    var codecType: String
    var naturalWidth: Int
    var naturalHeight: Int
    var displayWidth: Int
    var displayHeight: Int
    var frameRate: Double
    var bitrate: Int64?
    var rotation: Int
    var colorPrimaries: String?
    var transferFunction: String?
    var matrix: String?
    var is10Bit: Bool
    var isHDR10: Bool
    var isHLG: Bool
    var isDolbyVision: Bool

    var isHDR: Bool {
        isHDR10 || isHLG || isDolbyVision
    }

    var isHEVC: Bool {
        codecName.lowercased().contains("hevc") || codecName.lowercased().contains("h265") || codecType.lowercased().contains("hvc")
    }

    var isH264: Bool {
        codecName.lowercased().contains("h264") || codecName.lowercased().contains("avc") || codecType.lowercased().contains("avc")
    }
}

struct AudioTrackInfo: Codable, Sendable, Equatable {
    var codecName: String
    var codecType: String
    var bitrate: Int64?
    var sampleRate: Double
    var channels: Int
}

struct SubtitleTrackInfo: Codable, Sendable, Equatable {
    var codecName: String
    var codecType: String
}

struct MediaMetadata: Codable, Sendable, Equatable {
    var fileName: String
    var fileSize: Int64
    var duration: TimeInterval
    var videoTracks: [VideoTrackInfo]
    var audioTracks: [AudioTrackInfo]
    var subtitleTracks: [SubtitleTrackInfo]
    var creationDate: Date?
    var isPlayable: Bool
    var sourceFileExtension: String

    var videoTrack: VideoTrackInfo? {
        videoTracks.first
    }

    var hasVideo: Bool { !videoTracks.isEmpty }
    var hasAudio: Bool { !audioTracks.isEmpty }
    var hasSubtitles: Bool { !subtitleTracks.isEmpty }

    var resolutionString: String {
        guard let v = videoTrack else { return L10n.metadataNone }
        return "\(v.displayWidth) × \(v.displayHeight)"
    }

    var durationString: String {
        MediaMetadata.formatDuration(duration)
    }

    var fileSizeString: String {
        ByteFormatter.string(from: fileSize)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}