import Foundation

enum ConversionError: LocalizedError, Sendable {
    case cancelled
    case noVideoTrack
    case unreadableSource
    case unsupportedCombination(String)
    case engineUnavailable(String)
    case hardwareEncoderUnavailable
    case insufficientStorage(needed: Int64, available: Int64)
    case invalidOutput
    case photosPermissionDenied
    case photosSaveFailed(String)
    case filesAccessFailed(String)
    case importAccessDenied
    case importDownloading
    case importCopyFailed
    case importNotVideo
    case importVerificationFailed
    case ffmpegFailed(String)
    case nativeEngineFailed(String)
    case validationFailed(String)
    case fileAlreadyExists(String)
    case thermalLimitReached
    case corruptedFile

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return L10n.errorCancelled
        case .noVideoTrack:
            return L10n.errorNoVideoTrack
        case .unreadableSource:
            return L10n.errorUnreadableSource
        case .unsupportedCombination(let detail):
            return String(format: L10n.errorUnsupportedCombination, detail)
        case .engineUnavailable(let detail):
            return String(format: L10n.errorEngineUnavailable, detail)
        case .hardwareEncoderUnavailable:
            return L10n.errorHardwareEncoderUnavailable
        case .insufficientStorage(let needed, let available):
            return String(format: L10n.errorInsufficientStorage,
                          ByteFormatter.string(from: needed),
                          ByteFormatter.string(from: available))
        case .invalidOutput:
            return L10n.errorInvalidOutput
        case .photosPermissionDenied:
            return L10n.errorPhotosPermissionDenied
        case .photosSaveFailed(let detail):
            return String(format: L10n.errorPhotosSaveFailed, detail)
        case .filesAccessFailed(let detail):
            return String(format: L10n.errorFilesAccessFailed, detail)
        case .importAccessDenied:
            return L10n.errorImportAccess
        case .importDownloading:
            return L10n.errorImportDownloading
        case .importCopyFailed:
            return L10n.errorImportCopyFailed
        case .importNotVideo:
            return L10n.errorImportNotVideo
        case .importVerificationFailed:
            return L10n.errorImportVerification
        case .ffmpegFailed(let detail):
            return String(format: L10n.errorFFmpegFailed, detail)
        case .nativeEngineFailed(let detail):
            return String(format: L10n.errorNativeEngineFailed, detail)
        case .validationFailed(let detail):
            return String(format: L10n.errorValidationFailed, detail)
        case .fileAlreadyExists(let name):
            return String(format: L10n.errorFileAlreadyExists, name)
        case .thermalLimitReached:
            return L10n.errorThermalLimitReached
        case .corruptedFile:
            return L10n.errorCorruptedFile
        }
    }

    var technicalDetail: String? {
        switch self {
        case .cancelled: return nil
        case .unsupportedCombination(let detail): return detail
        case .engineUnavailable(let detail): return detail
        case .photosSaveFailed(let detail): return detail
        case .filesAccessFailed(let detail): return detail
        case .ffmpegFailed(let detail): return detail
        case .nativeEngineFailed(let detail): return detail
        case .validationFailed(let detail): return detail
        default: return nil
        }
    }
}