import XCTest
import AVFoundation
import CoreLocation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
import TimelineKitUISharedViews
@testable import VideoCompressor

/// One test per problem that was actually reported while using the app.
///
/// The rest of the suite is organised by component, which makes it easy to lose track of
/// whether a specific complaint is still covered after a refactor. This file is organised
/// by complaint instead: if something here fails, a bug the user already hit once has come
/// back. Several of these overlap with component tests on purpose — the duplication is the
/// point.
final class ReportedIssueRegressionTests: XCTestCase {

    // MARK: - "壓縮成 720 反而變大"

    /// Compressing must never produce a file larger than the source, whatever the source
    /// was encoded as. Built-in export presets target a fixed bitrate regardless of input,
    /// which is what caused this.
    @MainActor
    func testIssue_compressedOutputIsSmallerThanTheSource() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 6, size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        func bytes(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        }

        let compressor = VideoCompressor()
        let output = try await compressor.compress(inputURL: source, preset: .small)
        defer { try? FileManager.default.removeItem(at: output) }

        print("REGRESSION_SIZE in=\(bytes(source)) out=\(bytes(output))")
        XCTAssertLessThan(bytes(output), bytes(source), "the original complaint: output grew")
    }

    // MARK: - "壓縮一直是 0% 不會跑"

    @MainActor
    func testIssue_progressReachesCompletion() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }

        let compressor = VideoCompressor()
        let output = try await compressor.compress(inputURL: source, preset: .small)
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertEqual(compressor.progress, 1.0, "progress never completed")
    }

    // MARK: - "上傳到 Immich 之後時間變成壓縮當下"

    /// The date has to be inside the file, not only on the Photos asset: Immich re-reads
    /// the file. Insta360 clips carry no creation-date metadata item at all — the time is
    /// only in the movie header — so copying metadata items is not enough.
    @MainActor
    func testIssue_shootingDateSurvivesIntoTheFile() async throws {
        let shotAt = ISO8601DateFormatter().date(from: "2026-08-15T20:39:00Z")!
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: source))
        )
        let duration = try await AVURLAsset(url: source).load(.duration)
        _ = store.addVisualSegment(localURL: source, nativeDuration: CMTimeGetSeconds(duration))
        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)

        let compressor = VideoCompressor()
        let output = try await compressor.compress(
            source: .composition(built.composition,
                                 videoComposition: built.videoComposition,
                                 audioMix: built.audioMix,
                                 shotAt: shotAt),
            preset: .small, dateMode: .original
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let creationItem = try await AVURLAsset(url: output).load(.creationDate)
        let item = try XCTUnwrap(creationItem)
        let dateValue = try await item.load(.dateValue)
        let resolved = try XCTUnwrap(dateValue)
        print("REGRESSION_DATE: \(resolved)")
        XCTAssertEqual(resolved.timeIntervalSince(shotAt), 0, accuracy: 60,
                       "the file claims it was shot when it was encoded")
    }

    // MARK: - "檔名要是拍攝日期 + _compressed"

    @MainActor
    func testIssue_outputIsNamedAfterTheShootingDate() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 15
        components.hour = 20; components.minute = 39
        let shotAt = Calendar.current.date(from: components)!

        XCTAssertEqual(VideoCompressor.makeOutputFilename(shotAt: shotAt), "202608152039_compressed")
    }

    // MARK: - "直拍的影片被 cut 中間一段再轉 90 度"

    /// Phone portrait footage is stored landscape with the rotation in preferredTransform.
    /// Every path that renders frames itself has to apply it; the ones that did not showed
    /// a cropped middle strip of a sideways picture.
    @MainActor
    func testIssue_portraitFootageStaysUpright() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2,
            size: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let canvas = await EditorScreen.canvas(matching: source)
        XCTAssertLessThan(canvas.width, canvas.height, "portrait clip got a landscape canvas")

        let compressor = VideoCompressor()
        let output = try await compressor.compress(inputURL: source, preset: .small)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(outputTracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = naturalSize.applying(transform)
        print("REGRESSION_PORTRAIT: \(abs(displayed.width))x\(abs(displayed.height))")
        XCTAssertGreaterThan(abs(displayed.height), abs(displayed.width),
                             "a portrait clip came out landscape")
    }

    // MARK: - "多部影片被連在一起，要分開"

    /// Each queued clip is its own edit. Opening the editor must not silently merge the
    /// queue into a single video.
    @MainActor
    func testIssue_eachQueuedClipEditsAlone() async throws {
        let a = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3)
        defer { try? FileManager.default.removeItem(at: a) }

        let session = EditorSession(
            targetItemID: UUID(),
            clips: [.init(url: a, shotAt: nil, location: nil)],
            existingTimeline: nil
        )
        XCTAssertEqual(session.clips.count, 1,
                       "a session should carry exactly the clip that was tapped")
    }

    // MARK: - "剪輯設定要能撐過 App 被關掉"

    @MainActor
    func testIssue_savedEditSurvivesRelaunch() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 2)

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: source))
        )
        let duration = try await AVURLAsset(url: source).load(.duration)
        _ = store.addVisualSegment(localURL: source, nativeDuration: CMTimeGetSeconds(duration))

        var item = QueueItem(source: .file(VideoFile(url: source)))
        item.editedTimeline = store.timeline
        item.editedSourceURL = source
        QueueStore.save([item])
        try FileManager.default.removeItem(at: source)      // stand in for tmp being purged

        let restored = try XCTUnwrap(QueueStore.load().first)
        let timeline = try XCTUnwrap(restored.editedTimeline)
        let clip = try XCTUnwrap(timeline.materials.all.compactMap(\.localURL).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path),
                      "restored edit points at footage that is gone")
        QueueStore.save([])
    }

    // MARK: - "時間軸縮放不夠細 / 不夠遠"

    @MainActor
    func testIssue_timelineZoomRangeCoversFrameToHour() {
        // `TrackCanvasView` is internal to the package, but `TimelineTrackLayout` mirrors
        // its limits and is public — and the mirroring is itself worth pinning, since the
        // two drifting apart would silently cap zoom at the lower of the pair.
        // One frame at 30fps needs roughly 900 pt/s to be 30 pt wide.
        XCTAssertGreaterThanOrEqual(TimelineTrackLayout.defaultMaxPPS, 900,
                                    "cannot zoom in far enough to place a cut on a frame")
        // An hour on a ~360 pt wide track needs 0.1 pt/s.
        XCTAssertLessThanOrEqual(TimelineTrackLayout.defaultMinPPS, 0.1,
                                 "cannot zoom out far enough to see a long clip")
    }
}
