import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var createdAt: Date
    var inputFormat: String
    var outputFormat: String
    var inputSize: Int64
    var outputSize: Int64
    var duration: TimeInterval
    var status: JobStatus
    var outputURL: URL?
    var engine: EngineKind?
    var streamCopy: Bool

    var outputSizeString: String {
        ByteFormatter.string(from: outputSize)
    }

    var inputSizeString: String {
        ByteFormatter.string(from: inputSize)
    }

    var durationString: String {
        MediaMetadata.formatDuration(duration)
    }
}