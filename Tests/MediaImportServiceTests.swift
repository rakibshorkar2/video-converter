import XCTest
@testable import VideoConverter

final class MediaImportServiceTests: XCTestCase {

    private var importsDirectory: URL!
    private var service: MediaImportService!

    override func setUp() {
        super.setUp()
        importsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        service = MediaImportService(importsDirectory: importsDirectory, validateMedia: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: importsDirectory)
        importsDirectory = nil
        service = nil
        super.tearDown()
    }

    private func makeSource(named name: String, bytes: [UInt8]) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try! Data(bytes).write(to: file)
        return file
    }

    func testCopiesFileIntoImportsDirectory() async throws {
        let payload = Array(repeating: UInt8(0xAB), count: 4096)
        let source = makeSource(named: "clip.mov", bytes: payload)

        let media = try await service.importFile(from: source, fileName: "clip.mov", source: .files)

        XCTAssertEqual(media.source, .files)
        XCTAssertEqual(media.fileName, "clip.mov")
        XCTAssertEqual(media.fileSize, 4096)
        XCTAssertTrue(media.url.path.hasPrefix(importsDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.url.path))
        XCTAssertEqual(try Data(contentsOf: media.url), Data(payload))
    }

    func testSourceFileIsNotModified() async throws {
        let payload = Array(repeating: UInt8(0x11), count: 2048)
        let source = makeSource(named: "source.mp4", bytes: payload)

        _ = try await service.importFile(from: source, fileName: "source.mp4", source: .files)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), Data(payload))
    }

    func testSanitizesUnsafeFilenames() async throws {
        let source = makeSource(named: "safe.bin", bytes: [1, 2, 3, 4])

        let media = try await service.importFile(from: source, fileName: "a/b\\c?.mov", source: .files)

        XCTAssertFalse(media.fileName.contains("/"))
        XCTAssertFalse(media.fileName.contains("\\"))
        XCTAssertFalse(media.fileName.contains("?"))
        XCTAssertTrue(media.url.path.hasPrefix(importsDirectory.path))
    }

    func testAddsExtensionWhenMissing() async throws {
        let source = makeSource(named: "noextension", bytes: [1, 2, 3])

        let media = try await service.importFile(from: source, fileName: "clip", source: .files)

        XCTAssertEqual(media.fileName, "clip.mov")
    }

    func testDuplicateNamesGetUniqueFiles() async throws {
        let first = makeSource(named: "one.bin", bytes: [1])
        let second = makeSource(named: "two.bin", bytes: [2])

        let mediaOne = try await service.importFile(from: first, fileName: "video.mov", source: .files)
        let mediaTwo = try await service.importFile(from: second, fileName: "video.mov", source: .files)

        XCTAssertNotEqual(mediaOne.url, mediaTwo.url)
        XCTAssertEqual(mediaOne.fileName, "video.mov")
        XCTAssertEqual(mediaTwo.fileName, "video_2.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaOne.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaTwo.url.path))
    }

    func testZeroByteSourceRejected() async throws {
        let source = makeSource(named: "empty.mov", bytes: [])

        do {
            _ = try await service.importFile(from: source, fileName: "empty.mov", source: .files)
            XCTFail("Expected importDownloading error")
        } catch let error as ConversionError {
            guard case .importDownloading = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingSourceRejected() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("gone.mov")

        do {
            _ = try await service.importFile(from: missing, fileName: "gone.mov", source: .files)
            XCTFail("Expected importAccessDenied error")
        } catch let error as ConversionError {
            guard case .importAccessDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGarbageFileRejectedByValidation() async throws {
        let validating = MediaImportService(importsDirectory: importsDirectory, validateMedia: true)
        let source = makeSource(named: "junk.mov", bytes: Array("not a video".utf8))

        do {
            _ = try await validating.importFile(from: source, fileName: "junk.mov", source: .files)
            XCTFail("Expected importNotVideo error")
        } catch let error as ConversionError {
            guard case .importNotVideo = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: importsDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Failed import must not leave copies behind")
    }
}