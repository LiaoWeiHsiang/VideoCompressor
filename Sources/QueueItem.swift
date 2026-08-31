import Photos
import CoreLocation
import Foundation

enum VideoSource {
    case asset(PHAsset)
    case file(VideoFile)
}

struct QueueItem: Identifiable {
    enum Status: Equatable {
        case pending
        case loading
        case compressing
        case done
        case failed
    }

    let id = UUID()
    let source: VideoSource
    var status: Status = .pending
    var inputSizeText: String?
    var inputResolution: String?
    var outputURL: URL?
    var outputSizeText: String?
    var outputResolution: String?
    var errorMessage: String?
    /// Selected trim range in seconds, relative to the source video. nil means "use the
    /// whole video" (no trim applied).
    var trimRange: ClosedRange<Double>?
    /// The timestamp the compressed copy was actually stamped with, resolved from the
    /// chosen `DateMode` when this item was compressed. Used when saving to Photos so the
    /// asset's date matches the file's own metadata.
    var outputCreationDate: Date?
    /// Provenance for items that have no `PHAsset` to read it back from — an edited
    /// timeline is assembled in memory, so its date and location must be carried across
    /// explicitly or the saved copy would lose both.
    var overrideCreationDate: Date?
    var overrideLocation: CLLocation?
    /// Shown instead of the source filename for results the user produced in the editor.
    var displayTitle: String?

    var asset: PHAsset? {
        if case .asset(let asset) = source { return asset }
        return nil
    }

    var creationDate: Date? { asset?.creationDate ?? overrideCreationDate }
    var location: CLLocation? { asset?.location ?? overrideLocation }
}
