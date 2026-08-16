import Foundation
import AVFoundation

enum ConversionEngineRouter {

    static func selectEngine(for request: ConversionRequest) async -> VideoConversionEngine {
        let config = request.configuration

        switch config.enginePreference {
        case .videoToolbox:
            let engine = preferredEngine(.videoToolbox, for: request)
            if await engine.canHandle(request) { return engine }
        case .ffmpeg:
            if FormatCapabilities.isFFmpegEnabled {
                return FFmpegEngineFactory.make()
            }
        case .auto:
            break
        }

        if config.streamCopy {
            let engine = preferredEngine(.streamCopy, for: request)
            if await engine.canHandle(request) { return engine }
        }
        let avFoundation = preferredEngine(.avFoundation, for: request)
        if await avFoundation.canHandle(request) { return avFoundation }
        if FormatCapabilities.isFFmpegEnabled {
            return FFmpegEngineFactory.make()
        }
        return preferredEngine(.streamCopy, for: request)
    }

    private static func preferredEngine(_ kind: EngineKind, for request: ConversionRequest) -> VideoConversionEngine? {
        let engine = ConversionEngineRouterFactory.make(kind)
        return engine
    }
}

enum ConversionEngineRouterFactory {
    static func make(_ kind: EngineKind) -> VideoConversionEngine {
        switch kind {
        case .streamCopy: return StreamCopyEngineFactory.make()
        case .avFoundation: return AVFoundationEngineFactory.make()
        case .videoToolbox: return VideoToolboxEngineFactory.make()
        case .ffmpeg: return FFmpegEngineFactory.make()
        }
    }
}

private enum StreamCopyEngineFactory {
    static let shared = StreamCopyEngine()
    static func make() -> VideoConversionEngine { shared }
}

private enum AVFoundationEngineFactory {
    static let shared = AVFoundationEngine()
    static func make() -> VideoConversionEngine { shared }
}

private enum VideoToolboxEngineFactory {
    static let shared = VideoToolboxEngine()
    static func make() -> VideoConversionEngine { shared }
}

private enum FFmpegEngineFactory {
    static func make() -> VideoConversionEngine {
        #if FFMPEG_ENABLED
        return FFmpegEngine()
        #else
        return UnavailableFFmpegEngine()
        #endif
    }
}

#if !FFMPEG_ENABLED
private final class UnavailableFFmpegEngine: VideoConversionEngine {
    let identifier = EngineKind.ffmpeg
    func canHandle(_ request: ConversionRequest) async -> Bool { false }
    func convert(_ request: ConversionRequest, progress: @escaping @Sendable (ConversionProgress) -> Void, cancellation: CancellationToken) async throws -> ConversionResult {
        throw ConversionError.engineUnavailable(L10n.errorFFmpegNotIncluded)
    }
}
#endif