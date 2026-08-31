import Photos
import CoreLocation
import Foundation

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "沒有相簿寫入權限，請至「設定」開啟權限"
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    static func save(videoURL: URL, creationDate: Date? = nil, location: CLLocation? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            // Carry the file's own name into Photos, so the date-stamped name survives
            // wherever the asset is exported or synced to later.
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = videoURL.lastPathComponent
            request.addResource(with: .video, fileURL: videoURL, options: options)
            if let creationDate {
                request.creationDate = creationDate
            }
            if let location {
                request.location = location
            }
        }
    }
}
