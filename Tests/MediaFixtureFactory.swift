import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import VideoConverter

enum MediaFixtureFactory {

    static func makePortraitH264(
        url: URL,
        seconds: TimeInterval = 2,
        fps: Double = 30,
        width: Int = 540,
        height: Int = 960
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(videoInput) else { throw fixtureError("cannot add video input") }
        writer.add(videoInput)
        guard writer.startWriting() else { throw fixtureError("startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        guard writer.status == .writing else { throw fixtureError("startSession failed") }

        let frameCount = Int((seconds * fps).rounded())
        for i in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw fixtureError("no pixel buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw fixtureError("cannot create pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let color = UInt8((i * 5) % 256)
                memset(base, Int32(color), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let pts = CMTime(value: Int64(i), timescale: Int32(fps))
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw fixtureError("append failed at frame \(i)")
            }
        }
        videoInput.markAsFinished()
        guard await writer.finishWriting() else { throw fixtureError("finishWriting failed") }
        guard writer.status == .completed else {
            throw fixtureError("writer status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?")")
        }
    }

    static func metadataForPortrait(
        url: URL,
        seconds: TimeInterval = 2,
        fps: Double = 30,
        width: Int = 540,
        height: Int = 960
    ) -> MediaMetadata {
        MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: FileStorageManager.fileSize(at: url),
            duration: seconds,
            videoTracks: [VideoTrackInfo(
                codecName: "H.264",
                codecType: "avc1",
                naturalWidth: width,
                naturalHeight: height,
                displayWidth: width,
                displayHeight: height,
                frameRate: fps,
                bitrate: 2_000_000,
                rotation: 0,
                colorPrimaries: nil,
                transferFunction: nil,
                matrix: nil,
                is10Bit: false,
                isHDR10: false,
                isHLG: false,
                isDolbyVision: false
            )],
            audioTracks: [],
            subtitleTracks: [],
            creationDate: nil,
            isPlayable: true,
            sourceFileExtension: "mp4"
        )
    }

    static func metadataForLandscapeH264(url: URL, seconds: TimeInterval = 2, fps: Double = 30) -> MediaMetadata {
        MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: FileStorageManager.fileSize(at: url),
            duration: seconds,
            videoTracks: [VideoTrackInfo(
                codecName: "H.264",
                codecType: "avc1",
                naturalWidth: 1920,
                naturalHeight: 1080,
                displayWidth: 1920,
                displayHeight: 1080,
                frameRate: fps,
                bitrate: 8_000_000,
                rotation: 0,
                colorPrimaries: nil,
                transferFunction: nil,
                matrix: nil,
                is10Bit: false,
                isHDR10: false,
                isHLG: false,
                isDolbyVision: false
            )],
            audioTracks: [],
            subtitleTracks: [],
            creationDate: nil,
            isPlayable: true,
            sourceFileExtension: "mp4"
        )
    }

    static func metadataForHDRSource(url: URL) -> MediaMetadata {
        MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: 4_000_000,
            duration: 10,
            videoTracks: [VideoTrackInfo(
                codecName: "HEVC",
                codecType: "hvc1",
                naturalWidth: 1920,
                naturalHeight: 1080,
                displayWidth: 1920,
                displayHeight: 1080,
                frameRate: 30,
                bitrate: 12_000_000,
                rotation: 0,
                colorPrimaries: "BT2020",
                transferFunction: "PQ",
                matrix: "BT2020",
                is10Bit: true,
                isHDR10: true,
                isHLG: false,
                isDolbyVision: false
            )],
            audioTracks: [AudioTrackInfo(codecName: "AAC", codecType: "aac ", bitrate: 96_000, sampleRate: 48_000, channels: 2)],
            subtitleTracks: [],
            creationDate: nil,
            isPlayable: true,
            sourceFileExtension: "mp4"
        )
    }

    static func makeRequest(config: ConversionConfiguration, metadata: MediaMetadata) -> ConversionRequest {
        ConversionRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"),
            configuration: config,
            outputURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-out.mp4"),
            sourceMetadata: metadata
        )
    }

    static func makeTemporaryDirectory(named name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fixtureError(_ message: String) -> NSError {
        NSError(domain: "MediaFixtureFactory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}