import Foundation

enum JobStatus: String, Codable, Sendable {
    case queued
    case analyzing
    case preparing
    case converting
    case finalizing
    case saving
    case completed
    case failed
    case cancelled
    case interrupted
    case waitingForResources
}

enum ConversionStage: String, Codable, Sendable {
    case preparing
    case analyzing
    case decoding
    case encoding
    case muxing
    case finalizing
    case saving
    case completed

    var displayName: String {
        switch self {
        case .preparing: return L10n.stagePreparing
        case .analyzing: return L10n.stageAnalyzing
        case .decoding: return L10n.stageDecoding
        case .encoding: return L10n.stageEncoding
        case .muxing: return L10n.stageMuxing
        case .finalizing: return L10n.stageFinalizing
        case .saving: return L10n.stageSaving
        case .completed: return L10n.stageCompleted
        }
    }
}

enum EngineKind: String, Codable, Sendable {
    case streamCopy
    case avFoundation
    case videoToolbox
    case ffmpeg

    var displayName: String {
        switch self {
        case .streamCopy: return L10n.engineStreamCopy
        case .avFoundation: return L10n.engineAVFoundation
        case .videoToolbox: return L10n.engineVideoToolbox
        case .ffmpeg: return L10n.engineFFmpeg
        }
    }
}