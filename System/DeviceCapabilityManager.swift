import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Observation

@MainActor
@Observable
final class DeviceCapabilityManager {
    private(set) var supportsH264Encode = false
    private(set) var supportsHEVCEncode = false
    private(set) var supportsH264Decode = false
    private(set) var supportsHEVCDecode = false
    private(set) var supportsHDR = false
    private(set) var deviceIdentifier = ""
    private(set) var deviceModel = ""
    private(set) var systemVersion = ProcessInfo.processInfo.operatingSystemVersionString

    init() {
        detect()
    }

    func detect() {
        deviceIdentifier = DeviceCapabilityManager.machineIdentifier()
        deviceModel = DeviceCapabilityManager.marketingName(for: deviceIdentifier)
        supportsH264Encode = DeviceCapabilityManager.canCreateEncoder(codecType: kCMVideoCodecType_H264)
        supportsHEVCEncode = DeviceCapabilityManager.canCreateEncoder(codecType: kCMVideoCodecType_HEVC)
        supportsH264Decode = DeviceCapabilityManager.canCreateDecoder(codecType: kCMVideoCodecType_H264)
        supportsHEVCDecode = DeviceCapabilityManager.canCreateDecoder(codecType: kCMVideoCodecType_HEVC)
        supportsHDR = DeviceCapabilityManager.canCreateHEVC10BitEncoder()
    }

    var supportedVideoCodecs: [VideoCodecOption] {
        var codecs: [VideoCodecOption] = []
        if supportsH264Encode { codecs.append(.h264) }
        if supportsHEVCEncode { codecs.append(.hevc) }
        return codecs
    }

    private static func canCreateEncoder(codecType: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let spec = hardwareEncoderSpecification()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1280,
            height: 720,
            codecType: codecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    private static func canCreateHEVC10BitEncoder() -> Bool {
        var session: VTCompressionSession?
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        let spec = hardwareEncoderSpecification()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1280,
            height: 720,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if status == noErr, let session {
            let profile = kVTProfileLevel_HEVC_Main10_AutoLevel as CFString
            let setStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
            VTCompressionSessionInvalidate(session)
            return setStatus == noErr
        }
        return false
    }

    private static func canCreateDecoder(codecType: CMVideoCodecType) -> Bool {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: codecType,
            width: 1280,
            height: 720,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return false
        }
        var session: VTDecompressionSession?
        let spec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }

    private static func hardwareEncoderSpecification() -> [String: Any] {
        var spec: [String: Any] = [:]
        if #available(iOS 17.4, *) {
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] = true
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        } else {
            spec["EnableHardwareAcceleratedVideoEncoder"] = true
            spec["RequireHardwareAcceleratedVideoEncoder"] = true
        }
        return spec
    }

    private static func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private static func marketingName(for identifier: String) -> String {
        let map: [String: String] = [
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone 17 Air",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone16,7": "iPhone 16e",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone14,5": "iPhone 13",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone13,2": "iPhone 12",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone11,8": "iPhone XR",
            "iPhone11,2": "iPhone XS",
            "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max"
        ]
        return map[identifier] ?? identifier
    }
}