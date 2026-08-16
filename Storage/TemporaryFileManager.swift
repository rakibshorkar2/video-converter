import Foundation

enum TemporaryFileManager {

    static func workingDirectory(for jobID: UUID) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-converter", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func outputURL(for jobID: UUID, fileExtension: String) -> URL {
        workingDirectory(for: jobID).appendingPathComponent("output.\(fileExtension)")
    }

    static func cleanup(jobID: UUID) {
        let url = workingDirectory(for: jobID)
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupStaleFiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-converter", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in contents {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modDate, modDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func cleanupImportsDirectory() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: FileStorageManager.importsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for url in contents {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modDate, modDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func cleanupInbox() {
        let inbox = FileStorageManager.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: []) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}