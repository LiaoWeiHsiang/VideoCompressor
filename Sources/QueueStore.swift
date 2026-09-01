import Foundation
import Photos
import CoreLocation
import TimelineKitCore

/// Keeps the pending queue — and the edits set up for it — across app launches.
///
/// Lining several clips up is meant to be done at leisure, so losing the work because iOS
/// reclaimed the app would defeat the point of separating editing from compressing.
///
/// Only pending items are kept. A finished item points at a compressed file in the
/// temporary directory, which iOS may purge at any time, and the user has already been
/// offered the chance to save it.
enum QueueStore {

    // MARK: - Locations

    /// Application Support rather than Caches or tmp: the system purges both of those
    /// under storage pressure, and a saved edit whose source file vanished is useless.
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let url = base.appendingPathComponent("Queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var mediaDirectory: URL? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var indexURL: URL? { directory?.appendingPathComponent("queue.json") }

    /// Resolves a stored filename against the *current* container.
    ///
    /// A timeline records its clips by absolute URL, and an app's container path changes
    /// between installs, so those URLs go stale. Everything is therefore stored by
    /// filename and re-anchored on load.
    static func mediaURL(for fileName: String) -> URL? {
        mediaDirectory?.appendingPathComponent(fileName)
    }

    /// Copies a clip into storage this app controls, returning its filename.
    static func adoptMedia(at url: URL) -> String? {
        guard let mediaDirectory else { return nil }
        let fileName = url.lastPathComponent
        let destination = mediaDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return fileName }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return fileName
        } catch {
            return nil
        }
    }

    // MARK: - Stored shape

    private struct StoredItem: Codable {
        var id: UUID
        /// Set when the clip came from the photo library.
        var assetLocalIdentifier: String?
        /// Set when the clip is a file this app holds (shared in from another app).
        var mediaFileName: String?
        var trimLowerBound: Double?
        var trimUpperBound: Double?
        var editedTimeline: EditorTimeline?
        /// Every clip the timeline refers to, as material id → filename. A map rather than
        /// one name because the editor's + button can add further clips to an edit.
        var editedSourceFileNames: [String: String]?
        var overrideCreationDate: Date?
        var latitude: Double?
        var longitude: Double?
    }

    // MARK: - Saving

    static func save(_ queue: [QueueItem]) {
        guard let indexURL else { return }

        let stored: [StoredItem] = queue.compactMap { item in
            guard item.status == .pending else { return nil }

            var entry = StoredItem(id: item.id)
            switch item.source {
            case .asset(let asset):
                entry.assetLocalIdentifier = asset.localIdentifier
            case .file(let video):
                guard let name = adoptMedia(at: video.url) else { return nil }
                entry.mediaFileName = name
            }

            entry.trimLowerBound = item.trimRange?.lowerBound
            entry.trimUpperBound = item.trimRange?.upperBound
            entry.overrideCreationDate = item.overrideCreationDate
            entry.latitude = item.overrideLocation?.coordinate.latitude
            entry.longitude = item.overrideLocation?.coordinate.longitude

            // An edit is only restorable together with the footage it was built against,
            // so every clip it references is taken into storage alongside it.
            if let timeline = item.editedTimeline {
                var names: [String: String] = [:]
                for asset in timeline.materials.all {
                    guard let url = asset.localURL, let name = adoptMedia(at: url) else { continue }
                    names[asset.id.uuidString] = name
                }
                if !names.isEmpty {
                    entry.editedTimeline = timeline
                    entry.editedSourceFileNames = names
                }
            }
            return entry
        }

        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: indexURL, options: .atomic)
            let referenced = Set(stored.compactMap(\.mediaFileName))
                .union(stored.flatMap { $0.editedSourceFileNames?.values ?? [:].values })
            pruneMedia(keeping: referenced)
        } catch {
            // Persistence is a convenience; a failure here must not disturb the session.
        }
    }

    /// Deletes footage no stored item refers to any more, so removing clips from the queue
    /// eventually reclaims their space.
    private static func pruneMedia(keeping fileNames: Set<String>) {
        guard let mediaDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: mediaDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in contents where !fileNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Loading

    static func load() -> [QueueItem] {
        guard let indexURL,
              let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([StoredItem].self, from: data)
        else { return [] }

        return stored.compactMap { entry in
            let source: VideoSource
            if let identifier = entry.assetLocalIdentifier {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = fetched.firstObject else { return nil }   // deleted from Photos
                source = .asset(asset)
            } else if let name = entry.mediaFileName,
                      let url = mediaURL(for: name),
                      FileManager.default.fileExists(atPath: url.path) {
                source = .file(VideoFile(url: url))
            } else {
                return nil
            }

            var item = QueueItem(source: source)
            if let lower = entry.trimLowerBound, let upper = entry.trimUpperBound, lower < upper {
                item.trimRange = lower...upper
            }
            item.overrideCreationDate = entry.overrideCreationDate
            if let latitude = entry.latitude, let longitude = entry.longitude {
                item.overrideLocation = CLLocation(latitude: latitude, longitude: longitude)
            }

            if let timeline = entry.editedTimeline,
               let names = entry.editedSourceFileNames,
               let restored = reanchored(timeline, using: names) {
                item.editedTimeline = restored
                item.editedSourceURL = restored.materials.all.compactMap(\.localURL).first
            }
            return item
        }
    }

    /// Points each clip in a restored timeline at its footage's current location.
    ///
    /// Without this the timeline still holds the absolute URL from the session that
    /// created it, which no longer resolves once the container path has changed — the
    /// editor would open on an empty canvas with no error to explain it.
    ///
    /// Returns nil if any clip is missing, since a partially restored edit would silently
    /// drop footage the user had placed.
    private static func reanchored(_ timeline: EditorTimeline, using fileNames: [String: String]) -> EditorTimeline? {
        var timeline = timeline
        for asset in timeline.materials.all where asset.localURL != nil {
            guard let name = fileNames[asset.id.uuidString],
                  let url = mediaURL(for: name),
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            var updated = asset
            updated.localURL = url
            timeline.materials[asset.id] = updated
        }
        return timeline
    }
}
