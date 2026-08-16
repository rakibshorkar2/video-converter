import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

enum MediaAnalyzer {

    static func analyze(url: URL) async throws -> MediaMetadata {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let duration: CMTime
        let isPlayable: Bool
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let subtitleTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            isPlayable = try await asset.load(.isPlayable)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            subtitleTracks = ((try? await asset.loadTracks(withMediaType: .subtitle)) ?? []) + ((try? await asset.loadTracks(withMediaType: .text)) ?? [])
        } catch {
            throw ConversionError.unreadableSource
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let commonMetadata = (try? await asset.loadMetadata(for: .common)) ?? []
        let creationDate = commonMetadata.first(where: { $0.commonKey == .commonKeyCreationDate })?.dateValue

        var videoInfos: [VideoTrackInfo] = []
        for track in videoTracks {
            if let info = try? await videoInfo(for: track) {
                videoInfos.append(info)
            }
        }

        var audioInfos: [AudioTrackInfo] = []
        for track in audioTracks {
            if let info = try? await audioInfo(for: track) {
                audioInfos.append(info)
            }
        }

        var subInfos: [SubtitleTrackInfo] = []
        for track in subtitleTracks {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            if let fd = descriptions.first as? CMFormatDescription {
                let codec = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
                subInfos.append(SubtitleTrackInfo(codecName: codecName(forVideoCodec: codec), codecType: codec))
            }
        }

        return MediaMetadata(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            duration: duration.seconds.isNaN ? 0 : duration.seconds,
            videoTracks: videoInfos,
            audioTracks: audioInfos,
            subtitleTracks: subInfos,
            creationDate: creationDate,
            isPlayable: isPlayable,
            sourceFileExtension: url.pathExtension.lowercased()
        )
    }

    private static func videoInfo(for track: AVAssetTrack) async throws -> VideoTrackInfo {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let estimatedDataRate = Double(try await track.load(.estimatedDataRate))
        let descriptions = try await track.load(.formatDescriptions)

        let rotation = rotationDegrees(from: transform)

        var codecType = "unknown"
        var is10Bit = false
        var colorPrimaries: String?
        var transferFunction: String?
        var matrix: String?
        var profileLevel: String?

        if let fd = descriptions.first as? CMFormatDescription {
            codecType = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
            profileLevel = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ProfileLevel) as? String
            colorPrimaries = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            transferFunction = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            matrix = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_MatrixCoefficients) as? String
            if let level = profileLevel, level.lowercased().contains("10") || level.contains("10-bit") {
                is10Bit = true
            }
            if transferFunction?.contains("PQ") == true || transferFunction?.contains("HLG") == true {
                is10Bit = true
            }
        }

        let codecName = codecName(forVideoCodec: codecType)
        let displaySize = displaySize(natural: naturalSize, rotation: rotation)
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 0

        return VideoTrackInfo(
            codecName: codecName,
            codecType: codecType,
            naturalWidth: Int(naturalSize.width),
            naturalHeight: Int(naturalSize.height),
            displayWidth: Int(displaySize.width),
            displayHeight: Int(displaySize.height),
            frameRate: frameRate,
            bitrate: estimatedDataRate > 0 ? Int64(estimatedDataRate) : nil,
            rotation: rotation,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            matrix: matrix,
            is10Bit: is10Bit,
            isHDR10: transferFunction?.contains("PQ") == true,
            isHLG: transferFunction?.contains("HLG") == true,
            isDolbyVision: ["dvh1", "dvhe", "dva1", "dvh5"].contains(codecType.lowercased())
        )
    }

    private static func audioInfo(for track: AVAssetTrack) async throws -> AudioTrackInfo {
        let descriptions = try await track.load(.formatDescriptions)
        let estimatedDataRate = Double(try await track.load(.estimatedDataRate))
        guard let fd = descriptions.first as? CMFormatDescription else {
            return AudioTrackInfo(codecName: "unknown", codecType: "unknown", bitrate: nil, sampleRate: 0, channels: 0)
        }
        let codecType = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
        var asbd = AudioStreamBasicDescription()
        var sampleRate = 0.0
        var channels = 0
        if CMFormatDescriptionGetStreamBasicDescription(fd, &asbd) == noErr {
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
        }
        return AudioTrackInfo(
            codecName: audioCodecName(for: codecType),
            codecType: codecType,
            bitrate: estimatedDataRate > 0 ? Int64(estimatedDataRate) : nil,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    static func rotationDegrees(from transform: CGAffineTransform) -> Int {
        let angle = atan2(transform.b, transform.a)
        var degrees = Int((angle * 180 / .pi).rounded())
        while degrees < 0 { degrees += 360 }
        degrees %= 360
        switch degrees {
        case 0, 90, 180, 270: return degrees
        default: return 0
        }
    }

    private static func displaySize(natural: CGSize, rotation: Int) -> CGSize {
        if rotation == 90 || rotation == 270 {
            return CGSize(width: natural.height, height: natural.width)
        }
        return natural
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let valid = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        guard valid else { return String(format: "0x%08X", code) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    static func codecName(forVideoCodec codec: String) -> String {
        let c = codec.lowercased()
        if ["avc1", "avc3", "h264"].contains(c) { return "H.264" }
        if ["hvc1", "hev1"].contains(c) { return "HEVC" }
        if ["mp4v"].contains(c) { return "MPEG-4 Part 2" }
        if ["vp08"].contains(c) { return "VP8" }
        if ["vp09"].contains(c) { return "VP9" }
        if ["av01"].contains(c) { return "AV1" }
        if c.hasPrefix("ap") && (c.contains("4h") || c.contains("4x") || c.contains("4c")) { return "ProRes" }
        if ["mp2v", "mpeg"].contains(c) { return "MPEG-2" }
        if ["mjpg"].contains(c) { return "MJPEG" }
        if ["dvh1", "dvhe", "dva1", "dvh5"].contains(c) { return "Dolby Vision" }
        return codec.uppercased()
    }

    private static func audioCodecName(for codec: String) -> String {
        switch codec {
        case "aac ": return "AAC"
        case "alac": return "ALAC"
        case ".mp3": return "MP3"
        case "opus": return "Opus"
        case "fLaC": return "FLAC"
        case "lpcm": return "PCM"
        case "vorb": return "Vorbis"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "fl64", "fl32", "sowt", "twos", "in24", "in32": return "PCM"
        default: return codec
        }
    }
}