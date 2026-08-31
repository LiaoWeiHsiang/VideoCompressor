import XCTest
import Observation
import TimelineKitCore
import TimelineKitUIShared

/// Verifies the observation model that the macOS editor shell relies on for
/// timeline refresh: observing `store.document.timeline` (the actual @Observable
/// stored property) must fire when `addVisualSegment` mutates the document.
@MainActor
final class EditorStoreObservationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private var _value = 0
        private let lock = NSLock()
        var value: Int {
            get { lock.withLock { _value } }
        }
        func increment() { lock.withLock { _value += 1 } }
    }

    func testObservingDocumentTimelineFiresOnAddVisualSegment() {
        let canvas = EditorCanvas(width: 1920, height: 1080, fps: 30)
        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
        XCTAssertEqual(store.document.timeline.tracks.count, 0)

        let fired = Counter()
        withObservationTracking {
            _ = store.document.timeline
        } onChange: {
            fired.increment()
        }

        let segID = store.addVisualSegment(
            localURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            nativeDuration: 2
        )

        XCTAssertNotNil(segID, "addVisualSegment should create a segment")
        XCTAssertEqual(store.document.timeline.tracks.count, 1)
        XCTAssertEqual(store.document.timeline.tracks.first?.segments.count, 1)
        XCTAssertGreaterThan(fired.value, 0, "observing document.timeline should fire on mutation")
    }

    func testObservingComputedTimelinePropertyFires() {
        let canvas = EditorCanvas(width: 1920, height: 1080, fps: 30)
        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))

        let fired = Counter()
        withObservationTracking {
            _ = store.timeline
        } onChange: {
            fired.increment()
        }

        _ = store.addVisualSegment(
            localURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            nativeDuration: 2
        )

        // Computed property forwarding should also fire if the getter reads the
        // observable stored property during tracking.
        XCTAssertGreaterThan(fired.value, 0, "observing computed store.timeline should fire")
    }
}
