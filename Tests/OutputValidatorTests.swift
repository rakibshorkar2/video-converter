import XCTest
@testable import VideoConverter

final class OutputValidatorTests: XCTestCase {

    private func plan(engine: EngineKind) -> ConversionPlan {
        ConversionPlan(
            engine: engine,
            reason: "test",
            requiresTranscoding: engine != .streamCopy,
            streamCopyPossible: engine == .streamCopy,
            hardwareAccelerationAvailable: false,
            exportPreset: nil,
            unsupportedReason: nil
        )
    }

    private func assertValidationFailure(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let conversionError = error as? ConversionError else {
            XCTFail("expected ConversionError, got \(error)", file: file, line: line)
            return
        }
        guard case .validationFailed = conversionError else {
            XCTFail("expected validationFailed, got \(conversionError)", file: file, line: line)
            return
        }
    }

    func testValidPortraitOutputPasses() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: url, seconds: 2, fps: 30)
        let metadata = MediaFixtureFactory.metadataForPortrait(url: url)

        try await OutputValidator.validate(
            url: url,
            source: metadata,
            configuration: ConversionConfiguration(),
            plan: plan(engine: .avFoundation)
        )
    }

    func testMissingFileFails() async {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing.mp4")
        let metadata = MediaFixtureFactory.metadataForPortrait(url: url)

        do {
            try await OutputValidator.validate(
                url: url,
                source: metadata,
                configuration: ConversionConfiguration(),
                plan: plan(engine: .avFoundation)
            )
            XCTFail("expected failure")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testDurationMismatchFails() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: url, seconds: 2, fps: 30)
        var metadata = MediaFixtureFactory.metadataForPortrait(url: url)
        metadata.duration = 100

        do {
            try await OutputValidator.validate(
                url: url,
                source: metadata,
                configuration: ConversionConfiguration(),
                plan: plan(engine: .avFoundation)
            )
            XCTFail("expected failure")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testAudioMissingFailsWhenExpected() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: url, seconds: 2, fps: 30)
        var metadata = MediaFixtureFactory.metadataForPortrait(url: url)
        metadata.audioTracks = [
            AudioTrackInfo(codecName: "AAC", codecType: "aac ", bitrate: 64_000, sampleRate: 48_000, channels: 2)
        ]

        do {
            try await OutputValidator.validate(
                url: url,
                source: metadata,
                configuration: ConversionConfiguration(),
                plan: plan(engine: .avFoundation)
            )
            XCTFail("expected failure")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testAudioMissingPassesWhenAudioRemoved() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: url, seconds: 2, fps: 30)
        var metadata = MediaFixtureFactory.metadataForPortrait(url: url)
        metadata.audioTracks = [
            AudioTrackInfo(codecName: "AAC", codecType: "aac ", bitrate: 64_000, sampleRate: 48_000, channels: 2)
        ]
        var config = ConversionConfiguration()
        config.audioCodec = .none

        try await OutputValidator.validate(
            url: url,
            source: metadata,
            configuration: config,
            plan: plan(engine: .avFoundation)
        )
    }

    func testResolutionMismatchFails() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.mp4")
        try await MediaFixtureFactory.makePortraitH264(url: url, seconds: 2, fps: 30)
        let metadata = MediaFixtureFactory.metadataForPortrait(url: url)
        var config = ConversionConfiguration()
        config.resolution = .sd480

        do {
            try await OutputValidator.validate(
                url: url,
                source: metadata,
                configuration: config,
                plan: plan(engine: .avFoundation)
            )
            XCTFail("expected failure")
        } catch {
            assertValidationFailure(error)
        }
    }

    func testEmptyFileFails() async throws {
        let dir = MediaFixtureFactory.makeTemporaryDirectory(named: "ValidatorTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.mp4")
        try Data().write(to: url)
        let metadata = MediaFixtureFactory.metadataForPortrait(url: url)

        do {
            try await OutputValidator.validate(
                url: url,
                source: metadata,
                configuration: ConversionConfiguration(),
                plan: plan(engine: .avFoundation)
            )
            XCTFail("expected failure")
        } catch {
            assertValidationFailure(error)
        }
    }
}