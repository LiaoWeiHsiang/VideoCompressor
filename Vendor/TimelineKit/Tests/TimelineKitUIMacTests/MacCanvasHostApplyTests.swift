#if canImport(AppKit)
import XCTest
import AppKit
import TimelineKitCore
import TimelineKitUIShared
@testable import TimelineKitUIMac

/// Regression: adding media to a previously-empty timeline must rebuild the
/// canvas rows + segment blocks, even though the canvas host already existed.
@MainActor
final class MacCanvasHostApplyTests: XCTestCase {

    private func makeStore(tracks: [EditorTrack]) -> EditorStore {
        let canvas = EditorCanvas(width: 1920, height: 1080, fps: 30)
        let timeline = EditorTimeline(canvas: canvas, tracks: tracks)
        return EditorStore(timeline: timeline)
    }

    private func hostWithWindow(_ host: MacTimelineCanvasHost, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// Count segment blocks across all track rows on the canvas.
    private func blockCount(_ host: MacTimelineCanvasHost) -> Int {
        // Drill into the host → scrollView → documentView (canvas) → rows.
        guard let scroll = host.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let canvas = scroll.documentView as? MacTimelineCanvasView else {
            return -1
        }
        return canvas.subviews
            .compactMap { $0 as? MacTrackRowView }
            .reduce(0) { $0 + $1.segmentViews.count }
    }

    func testApplyAfterEmptyTimelineRebuildsRows() {
        // Start with an empty timeline (no main track) — the demo's initial state.
        let store = makeStore(tracks: [])
        let host = MacTimelineCanvasHost(store: store, libraryStore: TimelineLibraryStore())
        _ = hostWithWindow(host, size: NSSize(width: 1000, height: 500))

        // First apply: empty timeline.
        host.apply(timeline: store.timeline, selection: store.selection)
        let blocksBefore = blockCount(host)

        // Simulate addVisualSegment: it now auto-creates a main track.
        let segID = store.addVisualSegment(localURL: URL(fileURLWithPath: "/tmp/v.mp4"), nativeDuration: 2)
        XCTAssertNotNil(segID, "addVisualSegment should succeed on empty timeline")

        // Second apply with the populated timeline.
        host.apply(timeline: store.timeline, selection: store.selection)

        let blocksAfter = blockCount(host)
        XCTAssertEqual(store.document.timeline.tracks.count, 1, "store should now have 1 track")
        XCTAssertGreaterThan(blocksAfter, blocksBefore, "canvas should gain segment blocks after add")
        XCTAssertEqual(blocksAfter, 1, "expected exactly 1 segment block")

        // Render path: the block must have a non-zero frame so it is actually visible.
        guard let scroll = host.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let canvas = scroll.documentView as? MacTimelineCanvasView else {
            XCTFail("canvas not found")
            return
        }
        let rows = canvas.subviews.compactMap { $0 as? MacTrackRowView }
        let blockFrames = rows.flatMap { $0.segmentViews.values }.map(\.frame)
        XCTAssertFalse(blockFrames.isEmpty, "no block frames")
        for (i, f) in blockFrames.enumerated() {
            XCTAssertGreaterThan(f.width, 0, "block \(i) width should be > 0 (got \(f))")
            XCTAssertGreaterThan(f.height, 0, "block \(i) height should be > 0 (got \(f))")
        }
        // Canvas must be non-empty and sized.
        XCTAssertGreaterThan(canvas.frame.width, 0, "canvas width should be > 0")
        XCTAssertGreaterThan(canvas.frame.height, 0, "canvas height should be > 0")
    }
}

#endif
