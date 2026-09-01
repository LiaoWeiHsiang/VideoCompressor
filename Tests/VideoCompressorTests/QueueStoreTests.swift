import XCTest
import AVFoundation
import CoreLocation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Saved edits have to survive the app being terminated, which is the whole reason for
/// recording an edit instead of rendering it on the spot.
final class QueueStoreTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        QueueStore.save([])   // leave no fixtures behind for the next run
    }

    /// A restored edit must still point at footage that exists *now*.
    ///
    /// A timeline records its clips by absolute URL. The file it was built against lives in
    /// the temporary directory, which iOS purges, and an app's container path changes
    /// between installs — so a naive save/load produces a timeline whose clips resolve to
    /// nothing and an editor that opens blank with no error to explain it.
    @MainActor
    func testEditSurvivesARestartAndStillResolvesItsFootage() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: source))
        )
        let duration = try await AVURLAsset(url: source).load(.duration)
        _ = store.addVisualSegment(localURL: source, nativeDuration: CMTimeGetSeconds(duration))

        var item = QueueItem(source: .file(VideoFile(url: source)))
        item.editedTimeline = store.timeline
        item.editedSourceURL = source
        item.overrideCreationDate = Date(timeIntervalSince1970: 1_760_000_000)
        item.overrideLocation = CLLocation(latitude: 25.033, longitude: 121.5654)

        QueueStore.save([item])

        // Stand in for the app being killed and the temporary directory purged.
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let restored = QueueStore.load()
        XCTAssertEqual(restored.count, 1, "the pending item was not restored")
        let first = try XCTUnwrap(restored.first)

        let timeline = try XCTUnwrap(first.editedTimeline, "the edit was lost")
        let clipURL = try XCTUnwrap(timeline.materials.all.compactMap(\.localURL).first,
                                    "the restored timeline has no clip")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: clipURL.path),
            "restored timeline points at footage that no longer exists: \(clipURL.path)"
        )
        XCTAssertNotEqual(clipURL, source, "the clip should have been re-anchored, not kept as-is")

        XCTAssertEqual(first.overrideCreationDate?.timeIntervalSince1970 ?? 0,
                       1_760_000_000, accuracy: 1)
        XCTAssertEqual(first.location?.coordinate.latitude ?? 0, 25.033, accuracy: 0.001)

        // And it must still be renderable, not merely present.
        let built = try await CompositionBuilder().build(from: timeline, renderSubtitles: true)
        let seconds = CMTimeGetSeconds(try await built.composition.load(.duration))
        print("RESTORED_TIMELINE_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 2.0, accuracy: 0.5, "restored edit renders nothing")
    }

    /// Finished items are deliberately not kept: their output sits in the temporary
    /// directory, so restoring one would offer the user a file that may already be gone.
    @MainActor
    func testOnlyPendingItemsArePersisted() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        var done = QueueItem(source: .file(VideoFile(url: source)))
        done.status = .done
        done.outputURL = source

        QueueStore.save([done])
        XCTAssertTrue(QueueStore.load().isEmpty, "a finished item was persisted")
    }

    /// Dropping a clip from the queue must eventually reclaim its footage, or the store
    /// would grow without bound as clips are added and removed.
    @MainActor
    func testRemovedItemsStopOccupyingSpace() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let item = QueueItem(source: .file(VideoFile(url: source)))
        QueueStore.save([item])

        let stored = try XCTUnwrap(QueueStore.load().first)
        guard case .file(let video) = stored.source else {
            return XCTFail("expected a file-backed item")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path))

        QueueStore.save([])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: video.url.path),
            "footage for a removed item was left behind"
        )
    }
}
