import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum HardwareAcceleration {

    static func encoderAvailable(codec: VideoCodecOption) -> Bool {
        guard let codecType = videoCodecType(for: codec) else { return false }
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 64,
            height: 64,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard status == noErr, let encoder else { return false }
        defer { VTCompressionSessionInvalidate(encoder) }

        var supported: CFDictionary?
        let copyStatus = VTCopySupportedPropertyDictionary(codecType as CFString, &supported)
        guard copyStatus == noErr, let supported else { return false }
        return CFDictionaryGetValue(
            supported,
            Unmanaged.passUnretained(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder).toOpaque()
        ) != nil
    }

    static func decoderAvailable(codec: VideoCodecOption) -> Bool {
        guard let codecType = videoCodecType(for: codec) else { return false }
        var formatDescription: CMVideoFormatDescription?
        let createStatus = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: codecType,
            width: 64,
            height: 64,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard createStatus == noErr, let formatDescription else { return false }
        var decoder: VTDecompressionSession?
        let decodeStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &decoder
        )
        guard decodeStatus == noErr, let decoder else { return false }
        defer { VTDecompressionSessionInvalidate(decoder) }
        return true
    }

    static func encoderUsesHardware(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            nil,
            &value
        )
        return status == noErr && (value as? CFBoolean) == kCFBooleanTrue
    }

    private static func videoCodecType(for codec: VideoCodecOption) -> CMVideoCodecType? {
        switch codec {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        default: return nil
        }
    }
}