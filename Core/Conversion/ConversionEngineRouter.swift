import Foundation
import AVFoundation

enum ConversionEngineRouter {

    static let priorityOrder: [EngineKind] = [.exportSession, .streamCopy, .avFoundation, .videoToolbox, .ffmpeg]

    static func selectEngine(for request: ConversionRequest) async -> VideoConversionEngine {
        let plan = await ConversionPlanner.plan(for: request)
        return engine(for: plan)
    }

    static func engine(for plan: ConversionPlan) -> VideoConversionEngine {
        guard let kind = plan.engine else { return UnsupportedPlanEngine(plan: plan) }
        return ConversionEngineRouterFactory.make(kind)
    }

    static func fallbackEngine(after failedEngine: EngineKind, for request: ConversionRequest) async -> VideoConversionEngine? {
        guard let index = priorityOrder.firstIndex(of: failedEngine) else { return nil }
        for kind in priorityOrder.dropFirst(index + 1) {
            let candidate = ConversionEngineRouterFactory.make(kind)
            if await candidate.canHandle(request) { return candidate }
        }
        return nil
    }
}

enum ConversionEngineRouterFactory {
    static func make(_ kind: EngineKind) -> VideoConversionEngine {
        switch kind {
        case .streamCopy: return StreamCopyEngineFactory.make()
        case .exportSession: return ExportSessionEngineFactory.make()
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

private enum ExportSessionEngineFactory {
    static let shared = ExportSessionEngine()
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

private final class UnsupportedPlanEngine: VideoConversionEngine {
    let identifier = EngineKind.avFoundation
    private let plan: ConversionPlan

    init(plan: ConversionPlan) {
        self.plan = plan
    }

    func canHandle(_ request: ConversionRequest) async -> Bool { false }

    func convert(
        _ request: ConversionRequest,
        progress: @escaping @Sendable (ConversionProgress) -> Void,
        cancellation: CancellationToken
    ) async throws -> ConversionResult {
        throw ConversionError.unsupportedCombination(plan.unsupportedReason ?? "unsupported configuration")
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