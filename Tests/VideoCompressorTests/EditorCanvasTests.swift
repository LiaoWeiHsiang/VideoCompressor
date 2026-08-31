import XCTest
import AVFoundation
import CoreGraphics
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// The editor canvas decides the shape of everything downstream — the preview, and the
/// render size the finished video is encoded at. Getting it wrong does not fail, it just
/// letterboxes the footage into black bars, so it needs asserting rather than eyeballing.
final class EditorCanvasTests: XCTestCase {

    /// Phone portrait footage is *stored* landscape with a 90° rotation in
    /// `preferredTransform`. Reading `naturalSize` alone therefore reports it as landscape,
    /// which is exactly how a portrait clip ends up pillarboxed in the editor.
    @MainActor
    func testRotatedPortraitFootageGetsAPortraitCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1920, height: 1080),          // stored landscape
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // Confirm the fixture really is the tricky case, not an already-portrait file.
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let naturalSize = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertGreaterThan(naturalSize.width, naturalSize.height,
                             "fixture should be stored landscape for this test to mean anything")

        let canvas = await EditorScreen.canvas(matching: url)
        print("PORTRAIT_CANVAS: \(canvas.width)x\(canvas.height)")
        XCTAssertLessThan(canvas.width, canvas.height, "rotated portrait clip got a landscape canvas")
    }

    @MainActor
    func testLandscapeFootageGetsALandscapeCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        print("LANDSCAPE_CANVAS: \(canvas.width)x\(canvas.height)")
        XCTAssertGreaterThan(canvas.width, canvas.height)
    }

    /// Portrait footage stored portrait, with no rotation to interpret.
    @MainActor
    func testNativelyPortraitFootageGetsAPortraitCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1080, height: 1920)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        XCTAssertLessThan(canvas.width, canvas.height)
    }

    /// The canvas has to carry through to the encoded file, not just the preview: a
    /// portrait edit must come out portrait at 1080 across, not 1080 tall.
    @MainActor
    func testPortraitEditIsEncodedPortraitAt1080() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2,
            size: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
        let duration = try await AVURLAsset(url: url).load(.duration)
        _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true,
            renderSize: CGSize(
                width: EditorScreen.exportShortSide * 16 / 9,
                height: EditorScreen.exportShortSide
            )
        )
        let renderSize = built.videoComposition.renderSize
        print("PORTRAIT_RENDER_SIZE: \(renderSize)")
        XCTAssertLessThan(renderSize.width, renderSize.height, "portrait edit rendered landscape")
        XCTAssertEqual(renderSize.width, 1080, accuracy: 2, "portrait output should be 1080 across")
    }
}
