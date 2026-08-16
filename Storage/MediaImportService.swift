import Foundation
import UniformTypeIdentifiers

enum MediaImportSource: String, Sendable {
    case files
    case photos
    case shareSheet
    case dragAndDrop
}

struct ImportedMedia: Sendable {
    let url: URL
    let fileName: String
    let fileSize: Int64
    let source: MediaImportSource
    let contentType: UTType?
}

protocol MediaImporting {
    func importFile(from url: URL, fileName: String?, source: MediaImportSource) async throws -> ImportedMedia
}

struct MediaImportService: MediaImporting {

    let importsDirectory: URL
    let validateMedia: Bool
    private let logSink: (@Sendable (String) -> Void)?

    init(importsDirectory: URL = FileStorageManager.importsDirectory,
         validateMedia: Bool = true,
         logSink: (@Sendable (String) -> Void)? = nil) {
        self.importsDirectory = importsDirectory
        self.validateMedia = validateMedia
        self.logSink = logSink
    }

    func importFile(from url: URL, fileName proposedName: String?, source: MediaImportSource) async throws -> ImportedMedia {
        record("start source=\(source.rawValue) name=\(url.lastPathComponent)")

        // The security-scoped access must stay open until the copy below has
        // finished, so it is released in a defer.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            record("result=failure reason=missing")
            throw ConversionError.importAccessDenied
        }

        // No await happens between the caller handing us the URL and the copy
        // below, so provider temporary files are consumed immediately.
        let coordinatedURL = coordinatedReadURL(from: url)
        let sourceSize = FileStorageManager.fileSize(at: coordinatedURL)
        guard sourceSize > 0 else {
            record("result=failure reason=zeroBytes")
            throw ConversionError.importDownloading
        }
        record("securityScope=\(accessing) sourceSize=\(sourceSize)")

        let contentType = Self.contentType(of: coordinatedURL)
        let name = Self.destinationFileName(proposed: proposedName, from: coordinatedURL, contentType: contentType)
        let destination = FileStorageManager.uniqueURL(in: importsDirectory, fileName: name)
        record("destination name=\(destination.lastPathComponent) uttype=\(contentType?.identifier ?? "unknown")")

        do {
            try FileStorageManager.copyItem(from: coordinatedURL, to: destination)
        } catch {
            record("result=failure reason=copyFailed")
            throw ConversionError.importCopyFailed
        }
        let destinationSize = FileStorageManager.fileSize(at: destination)
        record("copyComplete destinationSize=\(destinationSize)")

        guard destinationSize > 0, destinationSize == sourceSize else {
            try? FileManager.default.removeItem(at: destination)
            record("result=failure reason=verificationMismatch sourceSize=\(sourceSize) destinationSize=\(destinationSize)")
            throw ConversionError.importVerificationFailed
        }

        if validateMedia {
            do {
                try await ImportValidator.validate(at: destination)
                record("validation=passed")
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        record("result=success")
        return ImportedMedia(
            url: destination,
            fileName: destination.lastPathComponent,
            fileSize: destinationSize,
            source: source,
            contentType: contentType
        )
    }

    private func coordinatedReadURL(from url: URL) -> URL {
        var coordinatedURL = url
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            coordinatedURL = readURL
        }
        if let coordinationError {
            record("coordinatedRead=false reason=\(coordinationError.localizedDescription)")
        }
        return coordinatedURL
    }

    private static func contentType(of url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    static func destinationFileName(proposed: String?, from url: URL, contentType: UTType?) -> String {
        let raw = proposed ?? url.lastPathComponent
        var name = FileStorageManager.sanitizeFileName(raw)
        if name == "." || name == ".." {
            name = "video"
        } else if name.hasPrefix(".") {
            name = "video" + name
        }
        if name.pathExtension.isEmpty {
            let ext = contentType?.preferredFilenameExtension ?? "mov"
            name += ".\(ext)"
        }
        return name
    }

    private func record(_ message: String) {
        logSink?(message)
    }
}

enum ImportValidator {
    static func validate(at url: URL) async throws {
        let metadata: MediaMetadata
        do {
            metadata = try await MediaAnalyzer.analyze(url: url)
        } catch {
            if FormatCapabilities.isFFmpegEnabled {
                return
            }
            throw ConversionError.importNotVideo
        }
        guard metadata.hasVideo else { throw ConversionError.importNotVideo }
        guard metadata.isPlayable else { throw ConversionError.importNotVideo }
    }
}