import Foundation
import AVFoundation
import CoreGraphics

enum OutputValidator {

    static func validate(
        url: URL,
        source: MediaMetadata,
        configuration: ConversionConfiguration,
        plan: ConversionPlan
    ) async throws {
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
        guard videoTracks.count == 1 else {
            if videoTracks.isEmpty {
                throw ConversionError.validationFailed(L10n.errorValidationVideoTrack)
            }
            throw ConversionError.validationFailed(L10n.errorValidationVideoTrackCount)
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

        let naturalSize = try await videoTracks[0].load(.naturalSize)
        let transform = try await videoTracks[0].load(.preferredTransform)
        let rotation = MediaAnalyzer.rotationDegrees(from: transform)
        let outputDisplay = rotation == 90 || rotation == 270
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
        let expectedSizes = expectedDisplaySizes(source: source, configuration: configuration, plan: plan)
        if !expectedSizes.isEmpty {
            let tolerance = plan.engine == .exportSession ? 0.06 : 0.02
            let matched = expectedSizes.contains { candidate in
                abs(outputDisplay.width - candidate.width) <= tolerance * candidate.width &&
                abs(outputDisplay.height - candidate.height) <= tolerance * candidate.height
            }
            if !matched {
                let expectedText = expectedSizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }.joined(separator: " or ")
                throw ConversionError.validationFailed(
                    String(format: L10n.errorValidationResolution,
                           expectedText,
                           "\(Int(outputDisplay.width.rounded()))x\(Int(outputDisplay.height.rounded()))")
                )
            }
        }

        if let expectedFPS = configuration.frameRate.value {
            let actualFPS = Double(try await videoTracks[0].load(.nominalFrameRate))
            if actualFPS > 0, abs(actualFPS - expectedFPS) > 2 {
                throw ConversionError.validationFailed(
                    String(format: L10n.errorValidationFPS,
                           String(format: "%.0f fps", expectedFPS),
                           String(format: "%.0f fps", actualFPS))
                )
            }
        }

        let expectedAudio = configuration.audioCodec != .none
            && configuration.audioTrackSelection != .none
            && !source.audioTracks.isEmpty
        if expectedAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw ConversionError.validationFailed(L10n.errorValidationAudioTrack)
            }
            if !configuration.streamCopy, configuration.audioCodec != .copy,
               let expected = expectedAudioCodec(configuration.audioCodec) {
                let descriptions = try await audioTracks[0].load(.formatDescriptions)
                if let fd = descriptions.first {
                    let actual = MediaAnalyzer.fourCCString(CMFormatDescriptionGetMediaSubType(fd)).lowercased()
                    if !codecMatches(actual: actual, expected: expected) {
                        throw ConversionError.validationFailed(
                            String(format: L10n.errorValidationAudioCodec, expected, actual)
                        )
                    }
                }
            }
        }

        let isPlayable: Bool
        do {
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            throw ConversionError.validationFailed(L10n.errorValidationUnreadable)
        }
        guard isPlayable else {
            throw ConversionError.validationFailed(L10n.errorValidationPlayable)
        }

        if source.duration > 0 {
            let tolerance = max(1.5, source.duration * 0.1)
            if abs(duration.seconds - source.duration) > tolerance {
                throw ConversionError.validationFailed(
                    String(format: L10n.errorValidationDurationMismatch,
                           MediaMetadata.formatDuration(source.duration),
                           MediaMetadata.formatDuration(duration.seconds))
                )
            }
        }

        let reopened = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let reopenedDuration: CMTime
        let reopenedVideoTracks: [AVAssetTrack]
        do {
            reopenedDuration = try await reopened.load(.duration)
            reopenedVideoTracks = try await reopened.loadTracks(withMediaType: .video)
        } catch {
            throw ConversionError.validationFailed(L10n.errorValidationUnreadable)
        }
        guard reopenedDuration.seconds > 0.05, !reopenedVideoTracks.isEmpty else {
            throw ConversionError.validationFailed(L10n.errorValidationUnreadable)
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

    private static func expectedAudioCodec(_ codec: AudioCodecOption) -> String? {
        switch codec {
        case .aac: return "aac"
        case .alac: return "alac"
        case .pcm: return "lpcm"
        case .mp3: return ".mp3"
        case .opus: return "opus"
        case .flac: return "flac"
        case .copy, .none: return nil
        }
    }

    private static func expectedDisplaySizes(
        source: MediaMetadata,
        configuration: ConversionConfiguration,
        plan: ConversionPlan
    ) -> [CGSize] {
        let natural = CGSize(width: source.videoTrack?.naturalWidth ?? 0, height: source.videoTrack?.naturalHeight ?? 0)
        let display = CGSize(width: source.videoTrack?.displayWidth ?? 0, height: source.videoTrack?.displayHeight ?? 0)
        guard natural.width > 0, natural.height > 0 else { return [] }

        if plan.engine == .exportSession {
            guard let preset = plan.exportPreset else { return [display] }
            let frame = ConversionPlanner.presetFrameSize(preset)
            guard frame != .zero else { return [display] }
            return [display, ConversionPlanner.fitFrame(source: display, into: frame)]
        }

        let resolved = configuration.resolution.resolvedSize(for: display)
        if configuration.streamCopy {
            return [display]
        }
        var candidates: [CGSize] = []
        if resolved.width > 0, resolved.height > 0 {
            candidates.append(resolved)
        }
        let naturalResolved = configuration.resolution.resolvedSize(for: natural)
        if naturalResolved != resolved, naturalResolved.width > 0, naturalResolved.height > 0 {
            candidates.append(naturalResolved)
        }
        if candidates.isEmpty {
            candidates.append(display)
        }
        return candidates
    }

    private static func codecMatches(actual: String, expected: String) -> Bool {
        let a = actual.trimmingCharacters(in: .whitespaces).lowercased()
        let e = expected.trimmingCharacters(in: .whitespaces).lowercased()
        if e == "avc" { return a.contains("avc") }
        if e == "hvc" { return a.contains("hvc") }
        return a.contains(e) || e.contains(a)
    }
}