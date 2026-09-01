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
        // Same canvas the app derives, so these exercise the real render size rather than
        // a 720-based preset the app never uses.
        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: clips.first))
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
    /// Every one of TimelineKit's canvas presets is 720-based, so a timeline built on one
    /// exports 720p. Nothing about the result looks wrong — it is simply softer than the
    /// source, which is the opposite of what this app promises. The canvas is therefore
    /// derived from the clip itself; this checks that derivation still holds 1080p.
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
            renderSubtitles: true
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

    /// Colour adjustment and clip animation, with no transition involved.
    ///
    /// Both switch `CompositionBuilder` to its `UnifiedCompositor` path, which is a custom
    /// `AVVideoComposition` compositor — the part of AVFoundation least likely to survive
    /// being read through `AVAssetReaderVideoCompositionOutput` rather than exported.
    @MainActor
    func testAdjustmentAndAnimationSurviveTheCompressionPath() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 440)
        defer { try? FileManager.default.removeItem(at: a) }

        let store = try await makeTimeline(clips: [a])
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)

        var adjustment = SegmentAdjustment()
        adjustment.brightness = 0.2
        adjustment.saturation = 1.4
        store.setAdjustment(segmentID: segment.id, adjustment: adjustment)
        store.setClipAnimation(
            segmentID: segment.id,
            animation: ClipAnimation(semantic: .fadeIn, timing: .in, duration: 0.5)
        )

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true
        )
        XCTAssertNotNil(
            built.videoComposition.customVideoCompositorClass,
            "expected the unified compositor path once an adjustment exists"
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

        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: outputURL).load(.duration))
        print("ADJUST_OUTPUT_SECONDS: \(seconds)")
        XCTAssertEqual(seconds, 4.0, accuracy: 0.5)
        XCTAssertEqual(compressor.progress, 1.0, "adjustment path never completed")
    }

    /// A timeline containing a transition must produce a composition AVFoundation accepts.
    ///
    /// `AVVideoComposition` requires its instructions to be disjoint and ascending.
    /// Upstream let each segment's instruction span its whole duration *and* appended a
    /// transition instruction straddling the boundary, so all three overlapped and the
    /// composition was rejected outright — every export of a timeline with a transition
    /// failed with a bare `AVErrorInvalidVideoComposition`.
    @MainActor
    func testTransitionProducesAValidComposition() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 440)
        let b = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3, toneHz: 880)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = try await makeTimeline(clips: [a, b])
        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)
        XCTAssertEqual(segments.count, 2, "need two segments to place a transition between")

        XCTAssertNotNil(
            store.addTransition(between: segments[0].id, and: segments[1].id,
                                type: .fade, duration: 0.5),
            "addTransition refused a valid adjacent pair"
        )
        var adjustment = SegmentAdjustment()
        adjustment.brightness = 0.2
        store.setAdjustment(segmentID: segments[0].id, adjustment: adjustment)

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true
        )
        XCTAssertNotNil(
            built.videoComposition.customVideoCompositorClass,
            "expected the unified compositor path once a transition and adjustment exist"
        )

        try await assertCompositionIsValid(built, label: "TRANSITION")

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

        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: outputURL).load(.duration))
        print("TRANSITION_OUTPUT_SECONDS: \(seconds)")
        // Timeline positions are never shifted (audio is laid down at raw timeline times),
        // so the join stays where it was: 4 + 3.
        XCTAssertEqual(seconds, 7.0, accuracy: 0.6)
        XCTAssertEqual(compressor.progress, 1.0, "transition path never completed")
    }

    /// With footage to spare outside the in/out points, the transition must actually
    /// overlap the two clips — otherwise it would dissolve a clip against black, which
    /// looks worse than the hard cut it is supposed to replace.
    @MainActor
    func testTrimmedClipsGiveTheTransitionRealOverlap() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 440)
        let b = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4, toneHz: 880)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = try await makeTimeline(clips: [a, b])
        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)

        // Leave a second of unused footage on each facing side: A ends a second early,
        // B starts a second in.
        store.trimSegment(id: segments[0].id,
                          newTargetRange: TimeRange(start: 0, duration: 3),
                          newSourceRangeStart: 0)
        store.trimSegment(id: segments[1].id,
                          newTargetRange: TimeRange(start: 3, duration: 3),
                          newSourceRangeStart: 1)
        XCTAssertNotNil(
            store.addTransition(between: segments[0].id, and: segments[1].id,
                                type: .fade, duration: 0.5)
        )

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true
        )
        try await assertCompositionIsValid(built, label: "OVERLAP")

        // Three instructions means the middle one is the transition; two would mean it was
        // dropped for lack of footage and the clips just cut.
        XCTAssertEqual(
            built.videoComposition.instructions.count, 3,
            "expected body / transition / body — the transition window was dropped"
        )
        let window = built.videoComposition.instructions[1].timeRange
        XCTAssertEqual(built.videoComposition.instructions[1].requiredSourceTrackIDs?.count, 2,
                       "the transition window must draw from both clips at once")

        // Both composition tracks must genuinely hold media across that window, which is
        // the thing that was missing: the instruction existed but had nothing to blend.
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 2)
        for track in videoTracks {
            let segments = try await track.load(.segments)
            let covered = segments.contains { !$0.isEmpty && $0.timeMapping.target.containsTimeRange(window) }
            XCTAssertTrue(
                covered,
                "track \(track.trackID) has no media across \(CMTimeGetSeconds(window.start))..\(CMTimeGetSeconds(window.end))"
            )
        }
    }

    /// Prints AVFoundation's own complaints before asserting, so a failure says which
    /// instruction is wrong rather than just `AVErrorInvalidVideoComposition`.
    private func assertCompositionIsValid(
        _ built: CompositionResult,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let validator = CompositionValidationReporter()
        let duration = try await built.composition.load(.duration)
        let isValid = try await built.videoComposition.isValid(
            for: built.composition,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            validationDelegate: validator
        )
        print("\(label)_COMPOSITION_DURATION: \(CMTimeGetSeconds(duration))")
        for instruction in built.videoComposition.instructions {
            let r = instruction.timeRange
            print("\(label)_INSTR: \(CMTimeGetSeconds(r.start))..\(CMTimeGetSeconds(r.end)) tracks=\(instruction.requiredSourceTrackIDs ?? [])")
        }
        for problem in validator.problems { print("\(label)_PROBLEM: \(problem)") }

        XCTAssertTrue(isValid, "video composition is invalid: \(validator.problems)", file: file, line: line)

        // Spell the requirement out, since `isValid` alone would not say which rule broke.
        var previousEnd = CMTime.zero
        for instruction in built.videoComposition.instructions {
            XCTAssertTrue(
                instruction.timeRange.start >= previousEnd,
                "instructions overlap or are out of order at \(CMTimeGetSeconds(instruction.timeRange.start))",
                file: file, line: line
            )
            previousEnd = instruction.timeRange.end
        }
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

/// Collects AVFoundation's own complaints about a video composition, which are otherwise
/// reduced to a bare `AVErrorInvalidVideoComposition` by the time a reader reports them.
final class CompositionValidationReporter: NSObject, AVVideoCompositionValidationHandling {
    var problems: [String] = []

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingInvalidValueForKey key: String
    ) -> Bool {
        problems.append("invalid value for key: \(key)")
        return true
    }

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange
    ) -> Bool {
        problems.append("empty time range: \(CMTimeGetSeconds(timeRange.start))..\(CMTimeGetSeconds(timeRange.end))")
        return true
    }

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: any AVVideoCompositionInstructionProtocol
    ) -> Bool {
        problems.append("invalid time range in instruction: \(CMTimeGetSeconds(instruction.timeRange.start))..\(CMTimeGetSeconds(instruction.timeRange.end))")
        return true
    }

    func videoComposition(
        _ videoComposition: AVVideoComposition,
        shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: any AVVideoCompositionInstructionProtocol,
        layerInstruction: AVVideoCompositionLayerInstruction,
        asset: AVAsset
    ) -> Bool {
        problems.append("invalid track id \(layerInstruction.trackID) in instruction at \(CMTimeGetSeconds(instruction.timeRange.start))")
        return true
    }
}
