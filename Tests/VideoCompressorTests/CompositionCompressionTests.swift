import XCTest
import AVFoundation
import CoreGraphics
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// The join between the editor and the encoder.
///
/// TimelineKit ships its own `VideoExporter`, and using it would quietly undo the two
/// things this app exists for: the source-relative bitrate ceiling, and writing the
/// shooting date into the file. These tests exist to prove the edited timeline goes
/// through *our* pipeline instead — so a future change that reaches for the built-in
/// exporter fails here rather than in the user's Immich library.
final class CompositionCompressionTests: XCTestCase {

    /// Builds a timeline the same way the app's editor screen does.
    @MainActor
    private func makeTimeline(clips: [URL]) async throws -> EditorStore {
        let store = EditorStore(
            timeline: EditorTimeline(canvas: EditorCanvas.Preset.landscape_16_9.canvas)
        )
        for url in clips {
            let seconds = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
            let id = store.addVisualSegment(localURL: url, nativeDuration: seconds)
            XCTAssertNotNil(id, "addVisualSegment returned nil for \(url.lastPathComponent)")
        }
        return store
    }

    /// Two clips joined on a timeline must come out as one file whose duration is the sum,
    /// with the audio from both preserved.
    @MainActor
    func testTwoClipTimelineCompressesToSingleFile() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 440)
        let b = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3, toneHz: 880)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = try await makeTimeline(clips: [a, b])
        let built = try await CompositionBuilder().build(from: store.timeline)

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            source: .composition(
                built.composition,
                videoComposition: built.videoComposition,
                audioMix: built.audioMix,
                shotAt: nil
            ),
            preset: .small
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let output = AVURLAsset(url: outputURL)
        let seconds = CMTimeGetSeconds(try await output.load(.duration))
        print("COMPOSITION_OUTPUT_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 7.0, accuracy: 0.6, "4s + 3s should join into a ~7s file")

        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "the edit should flatten to one video track")
        XCTAssertEqual(audioTracks.count, 1, "audio from the timeline was dropped")

        XCTAssertEqual(compressor.progress, 1.0, "progress did not complete")
    }

    /// The bitrate ceiling must survive the composition path. This is the regression that
    /// would otherwise be invisible: the file plays fine, it is just far too big.
    @MainActor
    func testCompositionPathKeepsBitrateCeiling() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 440)
        let b = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3, toneHz: 880)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        func bytes(_ url: URL) -> Int64 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? Int64) ?? 0
        }
        let sourceBytes = bytes(a) + bytes(b)

        let store = try await makeTimeline(clips: [a, b])
        let built = try await CompositionBuilder().build(from: store.timeline)

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            source: .composition(
                built.composition,
                videoComposition: built.videoComposition,
                audioMix: built.audioMix,
                shotAt: nil
            ),
            preset: .small
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputBytes = bytes(outputURL)
        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: outputURL).load(.duration))
        let observedBitrate = Double(outputBytes) * 8 / seconds
        print("COMPOSITION_SOURCE_BYTES: \(sourceBytes) OUTPUT_BYTES: \(outputBytes)")
        print("COMPOSITION_OBSERVED_BPS: \(observedBitrate)")

        // The preset is the upper bound regardless of what the timeline contained. Allow
        // the same 50% headroom the file-path test does for soft rate control ramp-up.
        XCTAssertLessThan(
            observedBitrate,
            Double(CompressionPreset.small.bitrate) * 1.5,
            "composition output overshot the preset ceiling — the bitrate cap is not being applied"
        )
    }

    /// The editor must not quietly downgrade resolution.
    ///
    /// Every one of TimelineKit's canvas presets is 720-based, so building without an
    /// explicit `renderSize` exports 720p. Nothing about the result looks wrong — it is
    /// simply softer than the source, which is the opposite of what this app promises.
    @MainActor
    func testEditedOutputStaysAt1080p() async throws {
        // Must be AudioVideoFactory, not SyntheticVideoFactory: the latter declares an
        // audio track it never writes samples to, and reading an empty track through the
        // audio mix output fails the whole reader.
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 3,
            size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let store = try await makeTimeline(clips: [source])
        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true,
            renderSize: CGSize(
                width: EditorScreen.exportShortSide * 16 / 9,
                height: EditorScreen.exportShortSide
            )
        )
        print("EDITED_RENDER_SIZE: \(built.videoComposition.renderSize)")
        XCTAssertEqual(
            min(built.videoComposition.renderSize.width, built.videoComposition.renderSize.height),
            1080, accuracy: 1,
            "timeline rendered below 1080p — the canvas default won over the export size"
        )

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            source: .composition(
                built.composition,
                videoComposition: built.videoComposition,
                audioMix: built.audioMix,
                shotAt: nil
            ),
            preset: .small
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let videoTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        print("EDITED_OUTPUT_SIZE: \(size)")
        XCTAssertEqual(min(size.width, size.height), 1080, accuracy: 2, "output is not 1080p")
    }

    /// An edited clip must still be dated by when it was *filmed*, both in the file's
    /// metadata and in its name. This is the Immich bug, one layer up: the composition
    /// carries no metadata of its own, so the date has to be threaded through explicitly.
    @MainActor
    func testEditedClipKeepsShootingDate() async throws {
        let shotAt = ISO8601DateFormatter().date(from: "2026-08-15T20:39:00Z")!

        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3, toneHz: 440)
        defer { try? FileManager.default.removeItem(at: a) }

        let store = try await makeTimeline(clips: [a])
        let built = try await CompositionBuilder().build(from: store.timeline)

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            source: .composition(
                built.composition,
                videoComposition: built.videoComposition,
                audioMix: built.audioMix,
                shotAt: shotAt
            ),
            preset: .small,
            dateMode: .original
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Read back the way an Immich server would — from the file, not from Photos.
        let asset = AVURLAsset(url: outputURL)
        let creationItem = try await asset.load(.creationDate)
        let unwrapped = try XCTUnwrap(creationItem, "edited output carries no creation date at all")
        let resolved = try await unwrapped.load(.dateValue)
        print("EDITED_OUTPUT_DATE: \(String(describing: resolved))")
        XCTAssertEqual(
            try XCTUnwrap(resolved).timeIntervalSince(shotAt), 0, accuracy: 60,
            "edited output is dated by encoding time, not by when it was filmed"
        )

        XCTAssertTrue(
            outputURL.lastPathComponent.hasPrefix(VideoCompressor.makeOutputFilename(shotAt: shotAt)),
            "expected the shooting-date filename, got \(outputURL.lastPathComponent)"
        )
    }
}
