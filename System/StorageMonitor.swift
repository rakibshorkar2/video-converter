import Foundation

enum StorageMonitor {
    static func availableBytes(at url: URL = FileManager.default.temporaryDirectory) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func hasSufficientStorage(needed: Int64, at url: URL = FileManager.default.temporaryDirectory) -> Bool {
        let available = availableBytes(at: url)
        return available >= needed
    }

    static func totalBytes(at url: URL = FileManager.default.temporaryDirectory) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }
}