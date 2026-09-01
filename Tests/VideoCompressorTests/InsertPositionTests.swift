import XCTest
import AVFoundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Where a newly added clip lands on the timeline.
///
/// Upstream always appended to the end of the main track, so adding a clip while watching
/// the middle of a long timeline put it somewhere off screen.
final class InsertPositionTests: XCTestCase {

    @MainActor
    private func makeStore(clipLengths: [Double]) async throws -> (EditorStore, [URL]) {
        var urls: [URL] = []
        for seconds in clipLengths {
            urls.append(try await AudioVideoFactory.makeVideoWithAudio(seconds: seconds))
        }
        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: urls.first))
        )
        for url in urls {
            let duration = try await AVURLAsset(url: url).load(.duration)
            _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))
        }
        return (store, urls)
    }

    @MainActor
    private func starts(_ store: EditorStore) -> [Double] {
        (store.timeline.mainTrack?.segments ?? [])
            .sorted { $0.targetRange.start < $1.targetRange.start }
            .map { ($0.targetRange.start * 100).rounded() / 100 }
    }

    /// The new clip goes after the one being watched, and everything later moves along by
    /// its length rather than being overlapped.
    @MainActor
    func testClipLandsAfterTheSegmentUnderThePlayhead() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3, 5])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        // Adding several in a row must chain forward, which only holds because the playhead
        // follows each insertion; otherwise they stack in reverse after the first clip.
        XCTAssertEqual(starts(store), [0, 4, 7], "setup: three clips laid end to end")

        // Watching the middle of the second clip (4s–7s).
        store.selection.playheadTime = 5.5

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        let newID = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        print("INSERT_STARTS: \(starts(store))")
        XCTAssertEqual(starts(store), [0, 4, 7, 9],
                       "expected the 2s clip at 7s with the 5s clip pushed to 9s")

        let inserted = try XCTUnwrap(store.timeline.segment(id: try XCTUnwrap(newID)))
        XCTAssertEqual(inserted.targetRange.start, 7, accuracy: 0.01,
                       "new clip should start where the watched clip ends")
    }

    /// With the playhead past the last clip there is nothing to insert after, so appending
    /// is still the right answer.
    @MainActor
    func testClipIsAppendedWhenThePlayheadIsPastTheEnd() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        store.selection.playheadTime = 99

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        XCTAssertEqual(starts(store), [0, 4, 7])
    }

    /// Inserting into a join must not leave the transition that described it behind: it
    /// would show a badge between clips that are no longer adjacent.
    @MainActor
    func testTransitionAcrossTheInsertionPointIsRemoved() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)
        XCTAssertNotNil(store.addTransition(between: segments[0].id, and: segments[1].id,
                                            type: .fade, duration: 0.5))
        XCTAssertEqual(store.timeline.transitions.count, 1)

        store.selection.playheadTime = 1        // watching the first clip
        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        XCTAssertEqual(starts(store), [0, 4, 6], "new clip should sit between the two")
        XCTAssertTrue(store.timeline.transitions.isEmpty,
                      "the transition described a join that no longer exists")
    }

    /// The whole timeline must still render, at the summed length — an insertion that
    /// overlapped or left a gap would show up here and nowhere else.
    @MainActor
    func testTimelineStillRendersAfterInsertion() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        store.selection.playheadTime = 1
        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let seconds = CMTimeGetSeconds(try await built.composition.load(.duration))
        print("INSERT_TOTAL_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 9.0, accuracy: 0.5, "4 + 2 + 3 should render as ~9s")
    }
}
