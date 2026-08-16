import Foundation
import AVFoundation
import CoreGraphics

struct ConversionPlan: Sendable {
    let engine: EngineKind?
    let reason: String
    let requiresTranscoding: Bool
    let streamCopyPossible: Bool
    let hardwareAccelerationAvailable: Bool
    let exportPreset: String?
    let unsupportedReason: String?
}

enum ConversionPlanner {

    static func plan(for request: ConversionRequest) async -> ConversionPlan {
        let config = request.configuration

        switch config.enginePreference {
        case .videoToolbox:
            if await canUseVideoToolbox(request) {
                return makePlan(engine: .videoToolbox, reason: L10n.planReasonPreference, for: request)
            }
        case .ffmpeg:
            if FormatCapabilities.isFFmpegEnabled {
                return makePlan(engine: .ffmpeg, reason: L10n.planReasonPreference, for: request)
            }
        case .auto:
            break
        }

        if config.streamCopy {
            if AVFileType(container: config.outputContainer) != nil,
               FormatCapabilities.canStreamCopy(source: request.sourceMetadata, to: config.outputContainer) {
                return makePlan(engine: .streamCopy, reason: L10n.planReasonStreamCopy, for: request)
            }
            if FormatCapabilities.isFFmpegEnabled,
               FormatCapabilities.canStreamCopy(source: request.sourceMetadata, to: config.outputContainer) {
                return makePlan(engine: .ffmpeg, reason: L10n.planReasonStreamCopy, for: request)
            }
            return ConversionPlan(
                engine: nil,
                reason: L10n.planReasonStreamCopy,
                requiresTranscoding: false,
                streamCopyPossible: false,
                hardwareAccelerationAvailable: false,
                exportPreset: nil,
                unsupportedReason: String(format: L10n.errorStreamCopyIncompatible, config.outputContainer.displayName)
            )
        }

        if let preset = exportPreset(for: request) {
            return makePlan(engine: .exportSession, reason: L10n.planReasonExport, exportPreset: preset, for: request)
        }

        if canUseAVFoundation(request) {
            return makePlan(engine: .avFoundation, reason: L10n.planReasonAVFoundation, for: request)
        }

        if FormatCapabilities.isFFmpegEnabled {
            return makePlan(engine: .ffmpeg, reason: L10n.planReasonFFmpeg, for: request)
        }

        return ConversionPlan(
            engine: nil,
            reason: "",
            requiresTranscoding: true,
            streamCopyPossible: false,
            hardwareAccelerationAvailable: false,
            exportPreset: nil,
            unsupportedReason: unsupportedReason(for: request)
        )
    }

    static func exportPreset(for request: ConversionRequest) -> String? {
        let config = request.configuration
        guard !config.streamCopy else { return nil }
        guard config.outputContainer == .mp4 || config.outputContainer == .mov else { return nil }
        guard config.videoCodec == .h264 || config.videoCodec == .hevc else { return nil }
        guard config.audioCodec == .aac else { return nil }
        guard config.audioBitrate == 128_000, config.audioSampleRate == 48_000, config.audioChannels == 2 else { return nil }
        guard config.audioTrackSelection != .none else { return nil }
        guard config.frameRate == .original else { return nil }
        guard config.videoBitrateOverrideMbps == nil else { return nil }
        guard config.resolution != .custom else { return nil }

        let sourceVideo = request.sourceMetadata.videoTrack
        let isHDR = sourceVideo?.isHDR == true
        if isHDR {
            guard config.preserveHDR, config.videoCodec == .hevc else { return nil }
        }

        let isHEVC = config.videoCodec == .hevc
        let preset: String?

        switch config.resolution {
        case .uhd4k:
            preset = isHEVC ? AVAssetExportPresetHEVC3840x2160 : AVAssetExportPreset3840x2160
        case .fhd1080:
            preset = isHEVC ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        case .hd720:
            preset = isHEVC ? nil : AVAssetExportPreset1280x720
        case .sd480:
            preset = isHEVC ? nil : AVAssetExportPreset960x540
        case .sd360:
            preset = isHEVC ? nil : AVAssetExportPreset640x480
        case .qhd1440, .uhd8k:
            preset = nil
        case .original, .custom:
            switch config.qualityFactor {
            case 0.8...:
                preset = isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            case 0.6..<0.8:
                preset = isHEVC ? nil : AVAssetExportPresetMediumQuality
            default:
                preset = isHEVC ? nil : AVAssetExportPresetLowQuality
            }
        }

        guard let preset else { return nil }
        return AVAssetExportSession.allExportPresets().contains(preset) ? preset : nil
    }

    static func fitFrame(source: CGSize, into frame: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, frame.width > 0, frame.height > 0 else { return source }
        let scale = min(frame.width / source.width, frame.height / source.height)
        return CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }

    static func expectedDisplaySize(source: MediaMetadata, plan: ConversionPlan) -> CGSize {
        let display = CGSize(width: source.videoTrack?.displayWidth ?? 0, height: source.videoTrack?.displayHeight ?? 0)
        guard let preset = plan.exportPreset else { return display }
        let frame = presetFrameSize(preset)
        guard frame != .zero else { return display }
        return fitFrame(source: display, into: frame)
    }

    static func presetFrameSize(_ preset: String) -> CGSize {
        switch preset {
        case AVAssetExportPresetLowQuality, AVAssetExportPreset640x480:
            return CGSize(width: 640, height: 480)
        case AVAssetExportPresetMediumQuality, AVAssetExportPreset960x540:
            return CGSize(width: 960, height: 540)
        case AVAssetExportPreset1280x720:
            return CGSize(width: 1280, height: 720)
        case AVAssetExportPreset1920x1080, AVAssetExportPresetHEVC1920x1080:
            return CGSize(width: 1920, height: 1080)
        case AVAssetExportPreset3840x2160, AVAssetExportPresetHEVC3840x2160:
            return CGSize(width: 3840, height: 2160)
        default:
            return .zero
        }
    }

    // MARK: - Capability checks

    static func canUseVideoToolbox(_ request: ConversionRequest) async -> Bool {
        let config = request.configuration
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

    static func canUseAVFoundation(_ request: ConversionRequest) -> Bool {
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

    // MARK: - Helpers

    private static func makePlan(
        engine: EngineKind,
        reason: String,
        exportPreset: String? = nil,
        for request: ConversionRequest
    ) -> ConversionPlan {
        let config = request.configuration
        let streamCopyPossible = engine == .streamCopy
        let hardwareAvailable: Bool
        switch engine {
        case .streamCopy, .exportSession:
            hardwareAvailable = false
        case .videoToolbox, .avFoundation:
            hardwareAvailable = config.hardwareAcceleration && HardwareAcceleration.encoderAvailable(codec: config.videoCodec)
        case .ffmpeg:
            hardwareAvailable = config.hardwareAcceleration && HardwareAcceleration.encoderAvailable(codec: config.videoCodec)
        }
        return ConversionPlan(
            engine: engine,
            reason: reason,
            requiresTranscoding: !streamCopyPossible,
            streamCopyPossible: streamCopyPossible,
            hardwareAccelerationAvailable: hardwareAvailable,
            exportPreset: exportPreset,
            unsupportedReason: nil
        )
    }

    private static func unsupportedReason(for request: ConversionRequest) -> String {
        let config = request.configuration
        if !FormatCapabilities.containerSupportsVideoCodec(config.outputContainer, codec: config.videoCodec) {
            return "\(config.outputContainer.displayName) + \(config.videoCodec.displayName)"
        }
        if !FormatCapabilities.containerSupportsAudioCodec(config.outputContainer, codec: config.audioCodec) {
            return "\(config.outputContainer.displayName) + \(config.audioCodec.displayName)"
        }
        if config.videoCodec.isFFmpegOnly || config.audioCodec.isFFmpegOnly || FormatCapabilities.containerRequiresFFmpeg(config.outputContainer) {
            return L10n.requiresFFmpegNote
        }
        return "unsupported configuration"
    }
}