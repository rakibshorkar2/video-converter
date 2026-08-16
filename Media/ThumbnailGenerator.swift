import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

enum ThumbnailGenerator {

    private static let cache = NSCache<NSURL, CGImage>()
    private static let queue = DispatchQueue(label: "com.videoconverter.thumbnails", qos: .utility)

    static func thumbnail(for url: URL, maxSize: CGFloat = 400) async -> CGImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }

        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let duration = (try? await asset.load(.duration)) ?? .zero
        let time = CMTime(seconds: min(duration.seconds, 1.0), preferredTimescale: 600)

        let image: CGImage?
        if #available(iOS 16.0, *) {
            image = try? await generator.image(at: time).image
        } else {
            image = nil
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func clear() {
        cache.removeAllObjects()
    }
}