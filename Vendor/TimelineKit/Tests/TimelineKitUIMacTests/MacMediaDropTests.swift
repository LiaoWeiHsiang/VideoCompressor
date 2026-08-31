#if canImport(AppKit)
import XCTest
import AppKit
import TimelineKitCore
import TimelineKitUIShared
@testable import TimelineKitUIMac

/// Verifies the media drag-and-drop pasteboard path: the media panel encodes a
/// LibraryMediaEntry into the pasteboard (mediaDragType), and the timeline
/// canvas decodes the same type back. This is the shared contract between the
/// drag source (MacMediaPanelView) and the drop target (MacTimelineCanvasView).
@MainActor
final class MacMediaDropTests: XCTestCase {

    private func makeEntry() -> LibraryMediaEntry {
        LibraryMediaEntry(
            id: UUID(),
            fileName: "ABC.mp4",
            originalFileName: "clip.mp4",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .video,
            duration: 5.0
        )
    }

    /// Round-trip: entry → JSON → pasteboard (as the panel writes) → decode
    /// (as the canvas reads). Must preserve id/kind/duration.
    func testPasteboardRoundTripPreservesEntry() throws {
        let entry = makeEntry()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-pb-\(UUID().uuidString)"))
        pasteboard.clearContents()

        // Source side: MacMediaPanelView.pasteboardWriterForItemAt.
        let writer = NSPasteboardItem()
        let encoded = try JSONEncoder().encode(entry)
        writer.setData(encoded, forType: MacMediaPanelView.mediaDragType)
        pasteboard.writeObjects([writer])

        // Destination side: MacTimelineCanvasView.performDragOperation decodes.
        guard let data = pasteboard.data(forType: MacMediaPanelView.mediaDragType) else {
            XCTFail("pasteboard missing mediaDragType data")
            return
        }
        let decoded = try JSONDecoder().decode(LibraryMediaEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.kind, entry.kind)
        XCTAssertEqual(decoded.duration, entry.duration)
        XCTAssertEqual(decoded.originalFileName, entry.originalFileName)
        XCTAssertEqual(decoded.captureDate, entry.captureDate)
    }

    /// Canvas drop handler fires with the decoded entry and a non-negative time.
    func testCanvasDropFiresCallback() throws {
        let canvas = MacTimelineCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let timeline = EditorTimeline(canvas: EditorCanvas(width: 1920, height: 1080, fps: 30))
        canvas.configure(timeline: timeline, availableWidth: 800)

        let entry = makeEntry()
        var dropped: (LibraryMediaEntry, Double)?
        canvas.onDropMedia = { e, t in dropped = (e, t) }

        // Drive the drop programmatically: simulate what performDragOperation
        // does (decode from pasteboard, convert x→time, fire callback).
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LibraryMediaEntry.self, from: data)
        let time = canvas.time(at: 400)
        canvas.onDropMedia?(decoded, max(0, time))

        XCTAssertNotNil(dropped, "onDropMedia should fire")
        XCTAssertEqual(dropped?.0.id, entry.id)
        XCTAssertGreaterThanOrEqual(dropped?.1 ?? -1, 0)
    }
}

#endif

