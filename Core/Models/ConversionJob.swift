import Foundation
import Observation

enum OutputDestination: String, Codable, Sendable {
    case photos
    case filesDocuments
    case filesCustom
}

@MainActor
@Observable
final class ConversionJob: Identifiable {
    let id: UUID
    var sourceURL: URL?
    var sourceName: String
    var metadata: MediaMetadata?
    var configuration: ConversionConfiguration
    var destination: OutputDestination
    var status: JobStatus
    var stage: ConversionStage?
    var fraction: Double
    var speed: Double?
    var eta: TimeInterval?
    var outputURL: URL?
    var outputSize: Int64
    var engine: EngineKind?
    var errorMessage: String?
    var technicalDetails: String?
    var createdAt: Date
    var completedAt: Date?
    var isPinned: Bool

    init(sourceURL: URL?, sourceName: String, configuration: ConversionConfiguration = ConversionConfiguration(), destination: OutputDestination = .filesDocuments) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.configuration = configuration
        self.destination = destination
        self.status = .queued
        self.fraction = 0
        self.outputSize = 0
        self.createdAt = Date()
        self.isPinned = false
    }

    var canConfigure: Bool {
        status == .queued || status == .failed || status == .cancelled || status == .interrupted
    }

    var canCancel: Bool {
        status == .queued || status == .analyzing || status == .preparing || status == .converting || status == .finalizing || status == .saving || status == .waitingForResources
    }

    var canRetry: Bool {
        status == .failed || status == .cancelled || status == .interrupted
    }

    var isTerminal: Bool {
        status == .completed || status == .failed || status == .cancelled
    }

    var speedText: String {
        guard let speed else { return "" }
        return String(format: "%.1f×", speed)
    }

    var etaText: String {
        guard let eta, eta.isFinite, eta > 0 else { return "" }
        let total = Int(eta.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if m > 0 { return String(format: "%d:%02d", m, s) }
        return "0:\(String(format: "%02d", s))"
    }
}

struct StoredJob: Codable {
    var id: UUID
    var sourceName: String
    var sourceURL: URL?
    var metadata: MediaMetadata?
    var configuration: ConversionConfiguration
    var destination: OutputDestination
    var status: JobStatus
    var stage: ConversionStage?
    var fraction: Double
    var outputURL: URL?
    var outputSize: Int64
    var engine: EngineKind?
    var errorMessage: String?
    var technicalDetails: String?
    var createdAt: Date
    var completedAt: Date?
    var isPinned: Bool

    @MainActor
    init(job: ConversionJob) {
        self.id = job.id
        self.sourceName = job.sourceName
        self.sourceURL = job.sourceURL
        self.metadata = job.metadata
        self.configuration = job.configuration
        self.destination = job.destination
        self.status = job.status
        self.stage = job.stage
        self.fraction = job.fraction
        self.outputURL = job.outputURL
        self.outputSize = job.outputSize
        self.engine = job.engine
        self.errorMessage = job.errorMessage
        self.technicalDetails = job.technicalDetails
        self.createdAt = job.createdAt
        self.completedAt = job.completedAt
        self.isPinned = job.isPinned
    }
}