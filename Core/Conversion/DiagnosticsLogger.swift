import Foundation
import Observation

@MainActor
@Observable
final class DiagnosticsLogger {

    struct Entry: Identifiable, Codable, Sendable {
        var id: UUID
        var timestamp: Date
        var message: String
        var engine: EngineKind?
        var detail: String?
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 100
    private let storeKey = "diagnostics.entries.v1"

    init() {
        load()
    }

    func log(_ message: String, engine: EngineKind? = nil, detail: String? = nil) {
        entries.insert(Entry(id: UUID(), timestamp: Date(), message: message, engine: engine, detail: detail), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { entry in
            var line = "[\(formatter.string(from: entry.timestamp))] \(entry.message)"
            if let engine = entry.engine { line += " (engine: \(engine.displayName))" }
            if let detail = entry.detail { line += " — \(detail)" }
            return line
        }.joined(separator: "\n")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}