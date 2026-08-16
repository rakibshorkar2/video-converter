import AVFoundation

extension AVFileType {
    init?(container: OutputContainer) {
        switch container {
        case .mp4: self = .mp4
        case .mov: self = .mov
        case .m4v: self = .m4v
        default: return nil
        }
    }
}