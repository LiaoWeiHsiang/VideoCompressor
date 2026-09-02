import XCTest
import AVFoundation
import CoreImage
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Whether speed actually changes the *playback rate*, not just the slot length.
///
/// Reported as "變速完全沒有變速 只有影片長度改變而已". The existing speed tests only checked
/// duration — and a clip that was merely truncated has exactly the same duration as one
/// that was sped up, so they could not tell the difference. These read back which source
/// frame is on screen.
final class SpeedContentTests: XCTestCase {

    /// Brightness of a rendered frame, which the `timecode` fixture sets from the source
    /// frame's own position: 0 at the start of the clip, 1 at the end.
    private func brightness(_ buffer: CVPixelBuffer) -> Double? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let i = ((height / 2) * width + width / 2) * 4
        return Double(pixels[i]) / 255.0
    }

    /// What the composition shows at `time`, as a position within the source clip.
    private func sourcePositionShown(
        _ built: CompositionResult, at time: Double
    ) throws -> Double {
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: time, preferredTimescale: 600),
            duration: CMTime(seconds: 0.2, preferredTimescale: 600)
        )
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        guard reader.canAdd(output) else { throw XCTSkip("reader refused the composition") }
        reader.add(output)
        guard reader.startReading() else { throw XCTSkip("reader would not start") }
        defer { reader.cancelReading() }

        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "no frame at \(time)s")
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        return try XCTUnwrap(brightness(buffer), "could not read the frame")
    }

    @MainActor
    private func build(speed: Double) async throws -> (CompositionResult, Double) {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 8, size: CGSize(width: 320, height: 240), pattern: .timecode
        )
        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: source))
        )
        let duration = try await AVURLAsset(url: source).load(.duration)
        let id = try XCTUnwrap(store.addVisualSegment(localURL: source,
                                                     nativeDuration: CMTimeGetSeconds(duration)))
        if speed != 1.0 { store.setVideoSpeed(segmentID: id, speed: speed) }

        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let slot = try XCTUnwrap(store.timeline.segment(id: id)).targetRange.duration
        try? FileManager.default.removeItem(at: source)
        return (built, slot)
    }

    /// At 2x, one second into the clip must already be showing two seconds of footage.
    /// A truncated clip would still be showing one.
    @MainActor
    func testDoubleSpeedAdvancesThroughFootageTwiceAsFast() async throws {
        let (normal, normalSlot) = try await build(speed: 1.0)
        let (fast, fastSlot) = try await build(speed: 2.0)

        print("SPEED_SLOTS: normal=\(normalSlot)s fast=\(fastSlot)s")
        XCTAssertEqual(fastSlot, normalSlot / 2, accuracy: 0.3, "2x should halve the slot")

        // Two seconds in: normal playback is a quarter through 8s of footage; at 2x it
        // should be half way.
        let atNormal = try sourcePositionShown(normal, at: 2.0)
        let atFast = try sourcePositionShown(fast, at: 2.0)
        print("SPEED_POSITION at 2s: normal=\(atNormal) fast=\(atFast)")

        XCTAssertEqual(atNormal, 0.25, accuracy: 0.12, "sanity: normal playback")
        XCTAssertEqual(atFast, 0.50, accuracy: 0.12,
                       "2x is not advancing through the footage faster — the clip was only shortened")
        XCTAssertGreaterThan(atFast, atNormal + 0.1,
                             "the sped-up clip shows the same footage as the normal one")
    }

    /// At 0.5x the opposite: two seconds in should still be near the very beginning.
    @MainActor
    func testHalfSpeedAdvancesThroughFootageSlower() async throws {
        let (normal, _) = try await build(speed: 1.0)
        let (slow, slowSlot) = try await build(speed: 0.5)

        print("SPEED_SLOW_SLOT: \(slowSlot)s")
        let atNormal = try sourcePositionShown(normal, at: 2.0)
        let atSlow = try sourcePositionShown(slow, at: 2.0)
        print("SPEED_POSITION at 2s: normal=\(atNormal) slow=\(atSlow)")

        XCTAssertLessThan(atSlow, atNormal - 0.05,
                          "0.5x is not slowing the footage down")
    }
}
