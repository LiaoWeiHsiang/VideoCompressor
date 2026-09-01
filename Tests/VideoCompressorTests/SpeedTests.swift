import XCTest
import AVFoundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Per-segment playback speed.
///
/// Upstream carries `EditorSegment.speed` but applies it to audio only — its own header
/// says so — so a clip marked 2x kept playing at normal rate and overran its slot. The
/// value is applied in four places now, and missing any one of them desynchronises sound
/// from picture, which is exactly the kind of fault that looks fine in a still frame.
final class SpeedTests: XCTestCase {

    @MainActor
    private func makeStore(_ url: URL) async throws -> EditorStore {
        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: url))
        )
        let duration = try await AVURLAsset(url: url).load(.duration)
        _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))
        return store
    }

    /// Doubling the speed must halve the slot the clip occupies.
    @MainActor
    func testDoubleSpeedHalvesTheTimelineSlot() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await makeStore(url)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        XCTAssertEqual(segment.targetRange.duration, 8, accuracy: 0.1)

        store.setVideoSpeed(segmentID: segment.id, speed: 2.0)
        let sped = try XCTUnwrap(store.timeline.segment(id: segment.id))
        XCTAssertEqual(sped.targetRange.duration, 4, accuracy: 0.2, "2x should halve the slot")
        XCTAssertEqual(sped.speed, 2.0, accuracy: 0.001)
    }

    @MainActor
    func testHalfSpeedDoublesTheTimelineSlot() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await makeStore(url)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        store.setVideoSpeed(segmentID: segment.id, speed: 0.5)

        let slowed = try XCTUnwrap(store.timeline.segment(id: segment.id))
        XCTAssertEqual(slowed.targetRange.duration, 8, accuracy: 0.3, "0.5x should double the slot")
    }

    /// A speed change resizes the clip, so whatever follows has to move — otherwise a
    /// slowed clip silently overlaps its neighbour.
    @MainActor
    func testFollowingClipsMoveWhenSpeedChanges() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        let b = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = try await makeStore(a)
        let durationB = try await AVURLAsset(url: b).load(.duration)
        _ = store.addVisualSegment(localURL: b, nativeDuration: CMTimeGetSeconds(durationB))

        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)
            .sorted { $0.targetRange.start < $1.targetRange.start }
        XCTAssertEqual(segments.map { ($0.targetRange.start * 10).rounded() / 10 }, [0, 4])

        store.setVideoSpeed(segmentID: segments[0].id, speed: 2.0)   // 4s slot becomes 2s

        let after = try XCTUnwrap(store.timeline.mainTrack?.segments)
            .sorted { $0.targetRange.start < $1.targetRange.start }
            .map { ($0.targetRange.start * 10).rounded() / 10 }
        print("SPEED_STARTS: \(after)")
        XCTAssertEqual(after, [0, 2], "the second clip should follow the shortened first")
    }

    /// The rendered result must actually be shorter, and must still carry audio: the video
    /// and audio tracks are scaled by separate code paths, so a mistake in one shows up
    /// only here.
    @MainActor
    func testSpedUpClipRendersShorterWithAudioIntact() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await makeStore(url)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        store.setVideoSpeed(segmentID: segment.id, speed: 2.0)

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

        let output = AVURLAsset(url: outputURL)
        let seconds = CMTimeGetSeconds(try await output.load(.duration))
        print("SPEED_RENDERED_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 4.0, accuracy: 0.5, "8s at 2x should render as ~4s")

        // Audio and video are scaled by different code; if only one was done they end up
        // different lengths even though the file plays.
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1, "the clip's own audio was dropped")

        let videoDuration = CMTimeGetSeconds(try await XCTUnwrap(videoTracks.first).load(.timeRange).duration)
        let audioDuration = CMTimeGetSeconds(try await XCTUnwrap(audioTracks.first).load(.timeRange).duration)
        print("SPEED_TRACKS: video=\(videoDuration)s audio=\(audioDuration)s")
        XCTAssertEqual(videoDuration, audioDuration, accuracy: 0.3,
                       "picture and sound came out different lengths — one was not sped up")
    }

    /// Slowing down must not lose the footage: a 0.5x clip plays twice as long.
    @MainActor
    func testSlowedClipRendersLonger() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try await makeStore(url)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        store.setVideoSpeed(segmentID: segment.id, speed: 0.5)

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
        print("SLOW_RENDERED_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 8.0, accuracy: 0.6, "4s at 0.5x should render as ~8s")
    }
}
