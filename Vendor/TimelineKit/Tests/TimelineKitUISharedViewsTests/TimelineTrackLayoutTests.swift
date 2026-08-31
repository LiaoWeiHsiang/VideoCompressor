import XCTest
import CoreGraphics
@testable import TimelineKitUISharedViews

/// Math tests for the shared TimelineTrackLayout (time ↔ pixel conversion).
/// Mirrors the semantics previously living inside iOS TrackCanvasView.TrackLayout.
@MainActor
final class TimelineTrackLayoutTests: XCTestCase {

    private let layout = TimelineTrackLayout(duration: 10, pixelsPerSecond: 100)

    // MARK: - Coordinate round-trip

    func testXTimeRoundTrip() {
        for time in stride(from: 0.0, through: 10.0, by: 0.5) {
            let x = layout.x(for: time)
            let back = layout.time(at: x)
            XCTAssertEqual(back, time, accuracy: 0.001, "round-trip failed at \(time)")
        }
    }

    func testXIncludesLeftPadding() {
        XCTAssertEqual(layout.x(for: 0), TimelineTrackLayout.defaultLeftPadding)
        XCTAssertEqual(layout.x(for: 5), TimelineTrackLayout.defaultLeftPadding + 500)
    }

    func testWidthForDuration() {
        XCTAssertEqual(layout.width(for: 4), 400)
        XCTAssertEqual(layout.width(for: 0), 0)
    }

    func testTimeClampsNegativeX() {
        XCTAssertEqual(layout.time(at: -50), 0)
        XCTAssertEqual(layout.time(at: 0), 0)
    }

    func testTimeDelta() {
        XCTAssertEqual(layout.timeDelta(for: 250), 2.5)
    }

    // MARK: - Zoom bounds

    func testPPSClampedToRange() {
        let tooLow = TimelineTrackLayout(duration: 10, pixelsPerSecond: 1)
        XCTAssertEqual(tooLow.pixelsPerSecond, TimelineTrackLayout.defaultMinPPS)

        let tooHigh = TimelineTrackLayout(duration: 10, pixelsPerSecond: 999_999)
        XCTAssertEqual(tooHigh.pixelsPerSecond, TimelineTrackLayout.defaultMaxPPS)

        let customRange = TimelineTrackLayout(
            duration: 10, pixelsPerSecond: 5_000, ppsRange: 100...1_000
        )
        XCTAssertEqual(customRange.pixelsPerSecond, 1_000)
    }

    // MARK: - Fitted pps

    func testFittedPPSUsesDefaultForEmptyTimeline() {
        let pps = TimelineTrackLayout.fittedPPS(duration: 0.1, availableWidth: 800)
        XCTAssertEqual(pps, TimelineTrackLayout.defaultPPS)
    }

    func testFittedPPSFillsWidth() {
        let pps = TimelineTrackLayout.fittedPPS(duration: 8, availableWidth: 800)
        XCTAssertEqual(pps, 100, accuracy: 0.001)
    }

    func testFittedPPSNeverBelowMin() {
        let pps = TimelineTrackLayout.fittedPPS(duration: 10_000, availableWidth: 100)
        XCTAssertEqual(pps, TimelineTrackLayout.defaultMinPPS)
    }

    // MARK: - Total width

    func testTotalWidthUsesMinDurationOne() {
        let empty = TimelineTrackLayout(duration: 0, pixelsPerSecond: 100)
        XCTAssertEqual(empty.totalWidth, 100 + TimelineTrackLayout.defaultLeftPadding)
    }

    func testTotalWidthScalesWithDuration() {
        XCTAssertEqual(layout.totalWidth, 10 * 100 + TimelineTrackLayout.defaultLeftPadding)
    }
}
