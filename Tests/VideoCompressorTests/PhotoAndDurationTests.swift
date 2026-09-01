import XCTest
import AVFoundation
import UIKit
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Photos on the timeline, and changing how long any clip occupies.
///
/// Both looked supported from reading the code — the picker already accepts images, and
/// static images are deliberately left without a duration cap so they can be stretched.
/// "Looked supported" has been wrong twice in this project, so it is asserted here.
final class PhotoAndDurationTests: XCTestCase {

    private func makeImage(_ color: UIColor = .systemTeal) throws -> URL {
        let size = CGSize(width: 1080, height: 1920)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    /// A photo added with no duration becomes an image segment with a default length.
    @MainActor
    func testPhotoBecomesAnImageSegment() async throws {
        let photo = try makeImage()
        defer { try? FileManager.default.removeItem(at: photo) }

        let store = EditorStore(timeline: EditorTimeline(canvas: EditorCanvas(width: 1080, height: 1920)))
        // nativeDuration nil is what marks a still: a photo has no inherent length.
        let id = store.addVisualSegment(localURL: photo, nativeDuration: nil)
        let segment = try XCTUnwrap(store.timeline.segment(id: try XCTUnwrap(id)))

        var isImage = false
        if case .image = segment.content { isImage = true }
        XCTAssertTrue(isImage, "a photo should land as an image segment, not a video one")
        XCTAssertGreaterThan(segment.targetRange.duration, 0, "a photo needs a default duration")
        print("PHOTO_DEFAULT_SECONDS: \(segment.targetRange.duration)")
    }

    /// A photo has no footage to run out of, so it must be stretchable well past its
    /// default — that is the whole point of putting a still on a timeline.
    @MainActor
    func testPhotoDurationCanBeStretchedAndShrunk() async throws {
        let photo = try makeImage()
        defer { try? FileManager.default.removeItem(at: photo) }

        let store = EditorStore(timeline: EditorTimeline(canvas: EditorCanvas(width: 1080, height: 1920)))
        let id = try XCTUnwrap(store.addVisualSegment(localURL: photo, nativeDuration: nil))

        store.trimSegment(id: id, newTargetRange: TimeRange(start: 0, duration: 10))
        XCTAssertEqual(try XCTUnwrap(store.timeline.segment(id: id)).targetRange.duration,
                       10, accuracy: 0.01, "a still should stretch to any length")

        store.trimSegment(id: id, newTargetRange: TimeRange(start: 0, duration: 1))
        XCTAssertEqual(try XCTUnwrap(store.timeline.segment(id: id)).targetRange.duration,
                       1, accuracy: 0.01, "and shrink again")
    }

    /// A photo mixed with video must actually render, for its full length.
    @MainActor
    func testPhotoAndVideoRenderTogether() async throws {
        let photo = try makeImage()
        let clip = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        defer { [photo, clip].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: clip))
        )
        let duration = try await AVURLAsset(url: clip).load(.duration)
        _ = store.addVisualSegment(localURL: clip, nativeDuration: CMTimeGetSeconds(duration))
        let photoID = try XCTUnwrap(store.addVisualSegment(localURL: photo, nativeDuration: nil))
        store.trimSegment(id: photoID,
                          newTargetRange: TimeRange(start: 4, duration: 3))

        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            source: .composition(built.composition,
                                 videoComposition: built.videoComposition,
                                 audioMix: built.audioMix,
                                 shotAt: nil),
            preset: .small
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: outputURL).load(.duration))
        print("PHOTO_PLUS_VIDEO_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 7.0, accuracy: 0.6, "4s of video plus a 3s still should be ~7s")
    }

    /// A video clip is different: it cannot be stretched past the footage that exists, or
    /// the extra time would have nothing to show.
    @MainActor
    func testVideoCannotBeStretchedPastItsFootage() async throws {
        let clip = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: clip) }

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: clip))
        )
        let duration = try await AVURLAsset(url: clip).load(.duration)
        let id = try XCTUnwrap(store.addVisualSegment(localURL: clip,
                                                     nativeDuration: CMTimeGetSeconds(duration)))

        store.trimSegment(id: id, newTargetRange: TimeRange(start: 0, duration: 30))
        let stretched = try XCTUnwrap(store.timeline.segment(id: id))
        print("VIDEO_STRETCH_ATTEMPT_SECONDS: \(stretched.targetRange.duration)")
        XCTAssertEqual(stretched.targetRange.duration, 4, accuracy: 0.2,
                       "a 4s clip cannot occupy 30s — there is no footage for the rest")

        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let composed = CMTimeGetSeconds(try await built.composition.load(.duration))
        print("VIDEO_STRETCH_RENDERED_SECONDS: \(composed)")
        XCTAssertEqual(composed, 4, accuracy: 0.5, "render invented footage that does not exist")
    }
}
