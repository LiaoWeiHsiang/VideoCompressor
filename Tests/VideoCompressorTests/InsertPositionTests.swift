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

// MARK: - Landing on a join

extension InsertPositionTests {

    /// On a join the playhead belongs to neither clip, so the new one goes into the join —
    /// after the clip that ends there, not after the one that starts there.
    @MainActor
    func testClipLandsInTheJoinWhenThePlayheadIsOnASplitPoint() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3, 5])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(starts(store), [0, 4, 7])

        store.selection.playheadTime = 7      // exactly the join between clip 2 and clip 3

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        let newID = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        print("JOIN_STARTS: \(starts(store))")
        XCTAssertEqual(starts(store), [0, 4, 7, 9],
                       "the new clip should occupy the join at 7s")

        let inserted = try XCTUnwrap(store.timeline.segment(id: try XCTUnwrap(newID)))
        XCTAssertEqual(inserted.targetRange.start, 7, accuracy: 0.01,
                       "on a join the clip goes into it, not after the following clip")
    }

    /// Scrubbing lands near a join rather than exactly on it, so the tolerance has to be
    /// wide enough to be usable — but the distinction still has to hold well inside a clip.
    @MainActor
    func testJoinDetectionToleratesScrubbingImprecision() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        store.selection.playheadTime = 4.01   // a third of a frame past the join at 4s

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        XCTAssertEqual(starts(store), [0, 4, 6], "just past a join still counts as on it")
    }

    /// Well inside the second clip the old rule applies: after the clip being watched.
    @MainActor
    func testInsideAClipStillInsertsAfterIt() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        store.selection.playheadTime = 5.5    // middle of the second clip (4s–7s)

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        XCTAssertEqual(starts(store), [0, 4, 7], "should follow the clip being watched")
    }

    /// The transition removed must be the one spanning the join actually being split.
    @MainActor
    func testTransitionAtTheJoinBeingSplitIsTheOneRemoved() async throws {
        let (store, urls) = try await makeStore(clipLengths: [4, 3, 5])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)
            .sorted { $0.targetRange.start < $1.targetRange.start }
        XCTAssertNotNil(store.addTransition(between: segments[0].id, and: segments[1].id,
                                            type: .fade, duration: 0.5))
        XCTAssertNotNil(store.addTransition(between: segments[1].id, and: segments[2].id,
                                            type: .fade, duration: 0.5))
        XCTAssertEqual(store.timeline.transitions.count, 2)

        store.selection.playheadTime = 7      // the join between clips 2 and 3

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        let remaining = store.timeline.transitions
        XCTAssertEqual(remaining.count, 1, "only the split join's transition should go")
        XCTAssertEqual(remaining.first?.leadingSegmentID, segments[0].id,
                       "the untouched join between clips 1 and 2 should survive")
    }
}

// MARK: - The real flow: split, then add

extension InsertPositionTests {

    /// Split a clip, then add another straight away.
    ///
    /// This is the actual sequence a user performs, and it is not the same as setting the
    /// playhead to a join by hand: the split point comes from `splitSegment`'s own
    /// clamping, so whether it lands exactly on the playhead is the package's decision
    /// rather than ours.
    @MainActor
    func testAddingRightAfterASplitLandsBetweenTheHalves() async throws {
        let (store, urls) = try await makeStore(clipLengths: [6])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let original = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        store.selection.playheadTime = 2.5
        let rightID = store.splitSegment(id: original.id, at: store.selection.playheadTime)
        XCTAssertNotNil(rightID, "split did not happen")
        XCTAssertEqual(starts(store), [0, 2.5], "split should leave halves at 0s and 2.5s")
        XCTAssertEqual(store.selection.playheadTime, 2.5, accuracy: 0.001,
                       "the playhead should still be sitting on the new join")

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        let newID = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        print("SPLIT_THEN_ADD_STARTS: \(starts(store))")
        XCTAssertEqual(starts(store), [0, 2.5, 4.5],
                       "the new clip belongs between the halves, pushing the back half to 4.5s")

        let inserted = try XCTUnwrap(store.timeline.segment(id: try XCTUnwrap(newID)))
        XCTAssertEqual(inserted.targetRange.start, 2.5, accuracy: 0.01,
                       "added after the front half, not after the back half")

        // The back half must still be the back half, not reordered behind the new clip.
        let back = try XCTUnwrap(store.timeline.segment(id: try XCTUnwrap(rightID)))
        XCTAssertEqual(back.targetRange.start, 4.5, accuracy: 0.01)
    }

    /// Splitting very close to a clip's edge is clamped by the package, leaving the
    /// playhead short of the join it created. The insert should still read as "after the
    /// front half" — here via the inside-a-clip rule rather than the join rule.
    @MainActor
    func testAddingAfterAClampedSplitStillLandsAfterTheFrontHalf() async throws {
        let (store, urls) = try await makeStore(clipLengths: [6])
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let original = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        store.selection.playheadTime = 0.05          // closer to the edge than the 0.2s floor
        _ = store.splitSegment(id: original.id, at: store.selection.playheadTime)
        XCTAssertEqual(starts(store), [0, 0.2], "split clamped to the 0.2s minimum")

        let added = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)
        defer { try? FileManager.default.removeItem(at: added) }
        let duration = try await AVURLAsset(url: added).load(.duration)
        _ = store.addVisualSegment(localURL: added, nativeDuration: CMTimeGetSeconds(duration))

        print("CLAMPED_SPLIT_STARTS: \(starts(store))")
        XCTAssertEqual(starts(store), [0, 0.2, 2.2],
                       "still between the halves despite the playhead trailing the split")
    }
}
