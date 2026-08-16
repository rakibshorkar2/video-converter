import XCTest
import AVFoundation
@testable import VideoConverter

final class ConversionPlannerTests: XCTestCase {

    func testDefaultConfigUsesExportSession() async {
        let request = MediaFixtureFactory.makeRequest(
            config: ConversionConfiguration(),
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPresetMediumQuality)
        XCTAssertTrue(plan.requiresTranscoding)
        XCTAssertNil(plan.unsupportedReason)
    }

    func testHighestQualityOriginalResolutionUsesHighestPreset() async {
        var config = ConversionConfiguration()
        config.qualityFactor = 1.0
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPresetHighestQuality)
    }

    func testLowQualityUsesLowPreset() async {
        var config = ConversionConfiguration()
        config.qualityFactor = 0.4
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPresetLowQuality)
    }

    func testHEVCMediumQualityFallsBackToAVFoundation() async {
        var config = ConversionConfiguration()
        config.videoCodec = .hevc
        config.qualityFactor = 0.5
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .avFoundation)
        XCTAssertNil(plan.exportPreset)
    }

    func testHEVCHighestQualityUsesHEVCHighestPreset() async {
        var config = ConversionConfiguration()
        config.videoCodec = .hevc
        config.qualityFactor = 1.0
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPresetHEVCHighestQuality)
    }

    func testBitrateOverrideFallsBackToAVFoundation() async {
        var config = ConversionConfiguration()
        config.videoBitrateOverrideMbps = 8
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .avFoundation)
        XCTAssertNil(plan.exportPreset)
    }

    func testCustomAudioSettingsFallBackToAVFoundation() async {
        var config = ConversionConfiguration()
        config.audioBitrate = 96_000
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .avFoundation)
        XCTAssertNil(plan.exportPreset)
    }

    func testLosslessUsesStreamCopy() async {
        var config = ConversionConfiguration()
        config.streamCopy = true
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .streamCopy)
        XCTAssertTrue(plan.streamCopyPossible)
        XCTAssertFalse(plan.requiresTranscoding)
    }

    func testWebMWithoutFFmpegIsUnsupported() async {
        var config = ConversionConfiguration()
        config.outputContainer = .webm
        config.videoCodec = .vp9
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertNil(plan.engine)
        XCTAssertNotNil(plan.unsupportedReason)
    }

    func testVideoToolboxPreferenceIsHonored() async {
        var config = ConversionConfiguration()
        config.enginePreference = .videoToolbox
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .videoToolbox)
    }

    func testVideoToolboxPreferenceFallsThroughWhenNotApplicable() async {
        var config = ConversionConfiguration()
        config.enginePreference = .videoToolbox
        config.resolution = .sd480
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
    }

    func testHDRSourceWithH264TargetSkipsExport() async {
        var config = ConversionConfiguration()
        config.videoCodec = .h264
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForHDRSource(url: URL(fileURLWithPath: "/tmp/hdr.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .avFoundation)
        XCTAssertNil(plan.exportPreset)
    }

    func testHDRSourceWithHEVCPreserveUsesExport() async {
        var config = ConversionConfiguration()
        config.videoCodec = .hevc
        config.preserveHDR = true
        config.qualityFactor = 1.0
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForHDRSource(url: URL(fileURLWithPath: "/tmp/hdr.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPresetHEVCHighestQuality)
    }

    func testResolutionPresetMapping() async {
        var config = ConversionConfiguration()
        config.resolution = .fhd1080
        let request = MediaFixtureFactory.makeRequest(
            config: config,
            metadata: MediaFixtureFactory.metadataForLandscapeH264(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
        XCTAssertEqual(plan.exportPreset, AVAssetExportPreset1920x1080)
    }

    func testPortraitSourceStillSelectsExport() async {
        let request = MediaFixtureFactory.makeRequest(
            config: ConversionConfiguration(),
            metadata: MediaFixtureFactory.metadataForPortrait(url: URL(fileURLWithPath: "/tmp/p.mp4"))
        )
        let plan = await ConversionPlanner.plan(for: request)
        XCTAssertEqual(plan.engine, .exportSession)
    }
}