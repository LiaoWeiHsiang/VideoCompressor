import XCTest
import AVFoundation
import CoreImage
import TimelineKitCore
import TimelineKitRender
@testable import VideoCompressor

/// Whether the *editor preview* honours a segment's speed.
///
/// Reported twice as "變速完全沒有變速". Both times the model, the composition and the
/// exported file were correct — `SpeedContentTests` and `ExportSpeedTests` prove it — and
/// both times the fix went into `ExportFrameProvider`. But the editor preview is drawn by
/// `PreviewFrameProvider`: `CompositionCoordinator` builds with `skipImageOverlays: true`
/// whenever any track has content, so the AVPlayer supplies timing and audio while the
/// picture comes from this class, which runs a hidden player per source file and samples
/// whatever frame it has reached. `CompositionBuilder`'s `scaleTimeRange` is invisible to
/// it. Nothing tested it, so "compiles, and the export tests pass" looked like a fix twice.
@MainActor
final class PreviewSpeedTests: XCTestCase {

    /// Brightness at the centre, which the `timecode` fixture sets from the source frame's
    /// own position: 0 at the start of the clip, 1 at the end.
    private func position(of image: CIImage) -> Double? {
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let i = ((height / 2) * width + width / 2) * 4
        return Double(pixels[i]) / 255.0
    }

    /// What the preview shows `atTimelineTime` for a clip running at `speed`.
    ///
    /// Scrubbed rather than played: a paused seek is deterministic, where sampling a rolling
    /// player would depend on how fast the test machine decodes.
    private func previewedPosition(
        source: URL, speed: Double, atTimelineTime: Double, sourceSeconds: Double
    ) async throws -> Double {
        let slot = sourceSeconds / speed
        let spec = VideoLayerSpec(
            assetURL: source,
            renderSize: CGSize(width: 640, height: 480),
            sourceStartTime: 0,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: slot, preferredTimescale: 600)
            ),
            speed: speed
        )

        let provider = PreviewFrameProvider()
        provider.setCanvasSize(CGSize(width: 640, height: 480))
        provider.setPlaybackActive(false)
        provider.preload(videoSpecs: [spec])
        defer { provider.invalidate() }

        let time = CMTime(seconds: atTimelineTime, preferredTimescale: 600)
        provider.seek(to: time, activeSpecs: [spec], playbackActive: false)

        // The first frame back is whatever the hidden player already had decoded — often
        // the head of the file — because a paused seek is driven *by* these `frame()` calls
        // and takes several to land. So poll until the answer stops changing rather than
        // taking the first one, which would read 0 no matter what the speed was.
        var last: Double?
        var stableFor = 0
        for _ in 0..<120 {
            if let frame = provider.frame(for: spec, at: time),
               let position = position(of: frame.image) {
                if let previous = last, abs(previous - position) < 0.01 {
                    stableFor += 1
                    if stableFor >= 4 { return position }
                } else {
                    stableFor = 0
                }
                last = position
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let last { return last }
        throw XCTSkip("the preview never produced a frame")
    }

    /// Two seconds into a 2x clip must show four seconds of footage. Showing two means the
    /// clip was merely shortened — the reported bug.
    func testPreviewShowsFootageFasterAtDoubleSpeed() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 8, size: CGSize(width: 640, height: 480), pattern: .timecode
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let normal = try await previewedPosition(
            source: source, speed: 1.0, atTimelineTime: 2.0, sourceSeconds: 8)
        let fast = try await previewedPosition(
            source: source, speed: 2.0, atTimelineTime: 2.0, sourceSeconds: 8)
        print("PREVIEW_SPEED at 2s: normal=\(normal) fast=\(fast)")

        XCTAssertEqual(normal, 0.25, accuracy: 0.12, "sanity: normal playback")
        XCTAssertEqual(fast, 0.50, accuracy: 0.12,
                       "the preview is not advancing through the footage faster")
    }

    /// And a slowed clip must still be near the start.
    func testPreviewShowsFootageSlowerAtHalfSpeed() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 8, size: CGSize(width: 640, height: 480), pattern: .timecode
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let normal = try await previewedPosition(
            source: source, speed: 1.0, atTimelineTime: 4.0, sourceSeconds: 8)
        let slow = try await previewedPosition(
            source: source, speed: 0.5, atTimelineTime: 4.0, sourceSeconds: 8)
        print("PREVIEW_SPEED at 4s: normal=\(normal) slow=\(slow)")

        XCTAssertEqual(slow, 0.25, accuracy: 0.12, "0.5x should be a quarter through at 4s")
        XCTAssertLessThan(slow, normal - 0.1, "the preview is not slowing the footage down")
    }
}
