import XCTest
import AVFoundation
@testable import VideoConverter

final class ConversionStallRegressionTests: XCTestCase {

    private func runConversion(
        config: ConversionConfiguration,
        expectedEngine: EngineKind,
        engine: VideoConversionEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ConversionResult {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "StallRegression")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: source, seconds: 2, fps: 30)
        let metadata = MediaFixtureFactory.metadataForPortrait(url: source)
        let output = dir.appendingPathComponent("output-\(expectedEngine.rawValue).mp4")

        let request = ConversionRequest(
            sourceURL: source,
            configuration: config,
            outputURL: output,
            sourceMetadata: metadata
        )

        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, expectedEngine, file: file, line: line)

        let token = CancellationToken()
        let result = try await engine.convert(request, progress: { _ in }, cancellation: token)

        XCTAssertEqual(result.engine, expectedEngine, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
        XCTAssertGreaterThan(FileStorageManager.fileSize(at: output), 0, file: file, line: line)

        try await OutputValidator.validate(url: output, source: metadata, configuration: config, plan: plan)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, metadata.duration, accuracy: 1.5, file: file, line: line)
        return result
    }

    func testPortraitPhotosH264ConversionDoesNotStallWithExportSession() async throws {
        var config = ConversionConfiguration()
        config.qualityFactor = 1.0
        _ = try await runConversion(
            config: config,
            expectedEngine: .exportSession,
            engine: ExportSessionEngine()
        )
    }

    func testPortraitPhotosH264ConversionDoesNotStallWithAVFoundation() async throws {
        var config = ConversionConfiguration()
        config.videoBitrateOverrideMbps = 4
        _ = try await runConversion(
            config: config,
            expectedEngine: .avFoundation,
            engine: AVFoundationEngine()
        )
    }

    func testPortraitPhotosH264StreamCopyDoesNotStall() async throws {
        var config = ConversionConfiguration()
        config.streamCopy = true
        _ = try await runConversion(
            config: config,
            expectedEngine: .streamCopy,
            engine: StreamCopyEngine()
        )
    }

    func testPreCancelledTokenFailsFast() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "StallRegression")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: source, seconds: 2, fps: 30)
        let metadata = MediaFixtureFactory.metadataForPortrait(url: source)
        let output = dir.appendingPathComponent("output.mp4")
        let request = ConversionRequest(
            sourceURL: source,
            configuration: ConversionConfiguration(),
            outputURL: output,
            sourceMetadata: metadata
        )

        let token = CancellationToken()
        token.cancel()

        do {
            _ = try await AVFoundationEngine().convert(request, progress: { _ in }, cancellation: token)
            XCTFail("expected cancellation")
        } catch let error as ConversionError {
            guard case .cancelled = error else {
                XCTFail("expected cancelled, got \(error)")
                return
            }
        } catch {
            XCTFail("expected ConversionError, got \(error)")
        }
    }
}