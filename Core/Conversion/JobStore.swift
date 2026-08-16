import Foundation

enum JobStore {

    static var queueFileURL: URL {
        FileStorageManager.documentsDirectory.appendingPathComponent("queue.json")
    }

    static func save(_ jobs: [ConversionJob]) {
        let stored = jobs.map { StoredJob(job: $0) }
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("JobStore save failed: \(error)")
            #endif
        }
    }

    static func load() -> [StoredJob] {
        guard let data = try? Data(contentsOf: queueFileURL),
              let decoded = try? JSONDecoder().decode([StoredJob].self, from: data) else {
            return []
        }
        return decoded
    }

    static func clear() {
        try? FileManager.default.removeItem(at: queueFileURL)
    }
}

@MainActor
@Observable
final class HistoryStore {

    private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 200
    private var fileURL: URL {
        FileStorageManager.documentsDirectory.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("HistoryStore save failed: \(error)")
            #endif
        }
    }
}