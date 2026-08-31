import Foundation
import CoreGraphics

// MARK: - TimelineTrackLayout

/// Shared time ↔ pixel math for the timeline track area.
///
/// Extracted from the iOS `TrackCanvasView.TrackLayout` so macOS and iOS render
/// tracks with pixel-identical coordinates. Pure CoreGraphics math — no UIKit /
/// AppKit dependency, safe for both platforms.
///
/// Layout model (剪映 paradigm):
///   - `leftPadding` keeps t=0 away from the left edge of the canvas.
///   - Content width = max(duration, 1.0) × pps + leftPadding.
///   - pps is clamped to `ppsRange` so zoom cannot explode or collapse.
@MainActor
public struct TimelineTrackLayout: Equatable, Sendable {
    /// Horizontal padding between the left edge and t=0 (points).
    public let leftPadding: CGFloat
    /// Valid zoom range for pixels-per-second.
    public let ppsRange: ClosedRange<CGFloat>

    public let duration: Double
    public let pixelsPerSecond: CGFloat
    public let totalWidth: CGFloat

    // MARK: - Defaults (mirror iOS TrackCanvasView constants)

    /// Minimum zoom: 20 pt per second.
    public static let defaultMinPPS: CGFloat = 20
    /// Maximum zoom: 600 pt per second.
    public static let defaultMaxPPS: CGFloat = 600
    /// Initial zoom for empty / very short timelines.
    public static let defaultPPS: CGFloat = 60
    /// Standard left padding used by both platforms.
    public static let defaultLeftPadding: CGFloat = 16

    /// Neutral layout used before a timeline is configured (mirrors the old
    /// `TrackLayout.empty` on iOS).
    public static let empty = TimelineTrackLayout(
        duration: 1,
        pixelsPerSecond: defaultMinPPS
    )

    public static func fittedPPS(
        duration: Double,
        availableWidth: CGFloat,
        range: ClosedRange<CGFloat> = defaultMinPPS...defaultMaxPPS,
        defaultPPS: CGFloat = defaultPPS
    ) -> CGFloat {
        // Empty / extremely short timelines must not inflate pps to astronomic
        // values (availableWidth / 0.1); fall back to the default pps instead.
        if duration < 0.5 { return defaultPPS }
        return max(availableWidth / CGFloat(duration), range.lowerBound)
    }

    public init(
        duration: Double,
        pixelsPerSecond: CGFloat,
        leftPadding: CGFloat = TimelineTrackLayout.defaultLeftPadding,
        ppsRange: ClosedRange<CGFloat> = TimelineTrackLayout.defaultMinPPS...TimelineTrackLayout.defaultMaxPPS
    ) {
        // totalWidth uses max(duration, 1.0) so an empty timeline still has a
        // usable content width; `duration` keeps the real timeline length for
        // ruler / consumers.
        let d   = max(duration, 0)
        let pps = TimelineTrackLayout.clamp(pixelsPerSecond, to: ppsRange)
        self.duration        = d
        self.pixelsPerSecond = pps
        self.leftPadding     = leftPadding
        self.ppsRange        = ppsRange
        self.totalWidth      = CGFloat(max(d, 1.0)) * pps + leftPadding
    }

    // MARK: - Coordinate conversion

    /// Canvas X for an absolute timeline time.
    public func x(for time: Double) -> CGFloat {
        leftPadding + CGFloat(time) * pixelsPerSecond
    }

    /// Canvas width for a duration span.
    public func width(for duration: Double) -> CGFloat {
        CGFloat(duration) * pixelsPerSecond
    }

    /// Timeline time at a canvas X (clamped to ≥ 0).
    public func time(at x: CGFloat) -> Double {
        Double(max(0, x - leftPadding)) / Double(pixelsPerSecond)
    }

    /// Timeline delta for a horizontal drag distance.
    public func timeDelta(for dx: CGFloat) -> Double {
        Double(dx) / Double(pixelsPerSecond)
    }

    // MARK: - Internal helper

    private static func clamp(_ v: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }
}
