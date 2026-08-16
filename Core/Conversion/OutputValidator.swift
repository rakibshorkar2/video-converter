import Foundation
import AVFoundation

enum OutputValidator {

    static func validate(url: URL, source: MediaMetadata, configuration: ConversionConfiguration) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.validationFailed(L10n.errorValidationMissing)
        }
        let size = FileStorageManager.fileSize(at: url)
        guard size > 0 else {
            throw ConversionError.validationFailed(L10n.errorValidationEmpty)
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ConversionError.validationFailed(L10n.errorValidationUnreadable)
        }
        guard duration.seconds > 0.05 else {
            throw ConversionError.validationFailed(L10n.errorValidationDuration)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ConversionError.validationFailed(L10n.errorValidationVideoTrack)
        }

        if configuration.audioCodec != .none && !source.audioTracks.isEmpty && configuration.audioTrackSelection != .none {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw ConversionError.validationFailed(L10n.errorValidationAudioTrack)
            }
        }

        if let expected = expectedVideoCodec(source: source, configuration: configuration) {
            let descriptions = try await videoTracks[0].load(.formatDescriptions)
            if let fd = descriptions.first {
                let actual = MediaAnalyzer.fourCCString(CMFormatDescriptionGetMediaSubType(fd)).lowercased()
                if !codecMatches(actual: actual, expected: expected) {
                    throw ConversionError.validationFailed(
                        String(format: L10n.errorValidationCodec, expected, actual)
                    )
                }
            }
        }
    }

    private static func expectedVideoCodec(source: MediaMetadata, configuration: ConversionConfiguration) -> String? {
        if configuration.streamCopy {
            return source.videoTrack?.codecType
        }
        switch configuration.videoCodec {
        case .h264: return "avc"
        case .hevc: return "hvc"
        case .mpeg4: return "mp4v"
        case .vp9: return "vp09"
        case .av1: return "av01"
        case .vp8: return "vp08"
        }
    }

    private static func codecMatches(actual: String, expected: String) -> Bool {
        let e = expected.lowercased()
        if e == "avc" { return actual.contains("avc") }
        if e == "hvc" { return actual.contains("hvc") }
        return actual.contains(e) || e.contains(actual)
    }
}