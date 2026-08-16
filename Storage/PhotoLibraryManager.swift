import Foundation
import Photos
import UIKit

@MainActor
enum PhotoLibraryManager {

    static let albumName = "Video Converter"

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static var addOnlyStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func saveVideo(toPhotos url: URL, inAlbum albumName: String = PhotoLibraryManager.albumName) async throws -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .denied || status == .restricted {
            throw ConversionError.photosPermissionDenied
        }

        if status == .notDetermined {
            let requested = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if requested == .denied || requested == .restricted {
                throw ConversionError.photosPermissionDenied
            }
        }

        let assetID = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                placeholder = request?.placeholderForCreatedAsset
            } completionHandler: { success, error in
                if let error {
                    cont.resume(throwing: ConversionError.photosSaveFailed(error.localizedDescription))
                } else if success, let localID = placeholder?.localIdentifier {
                    cont.resume(returning: localID)
                } else {
                    cont.resume(throwing: ConversionError.photosSaveFailed(L10n.errorPhotosUnknownFailure))
                }
            }
        }

        try await addToAlbum(assetID: assetID, albumName: albumName)
        return assetID
    }

    private static func addToAlbum(assetID: String, albumName: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return }

        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var targetCollection: PHAssetCollection?
        existing.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == albumName {
                targetCollection = collection
                stop.pointee = true
            }
        }

        if targetCollection == nil {
            var placeholder: PHObjectPlaceholder?
            let created = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    placeholder = request.placeholderForCreatedAssetCollection
                } completionHandler: { success, _ in
                    cont.resume(returning: success)
                }
            }
            guard created, let collectionID = placeholder?.localIdentifier else { return }
            targetCollection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [collectionID],
                options: nil
            ).firstObject
        }

        guard let collection = targetCollection else { return }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let changeRequest = PHAssetCollectionChangeRequest(for: collection)
                changeRequest?.addAssets([asset] as NSArray)
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
        _ = result
    }
}