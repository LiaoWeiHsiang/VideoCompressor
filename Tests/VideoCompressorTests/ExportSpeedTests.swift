import XCTest
import AVFoundation
import CoreImage
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Whether a speed change survives all the way into the file the user actually gets.
///
/// Reported twice: "變速完全沒有變速 只有影片長度改變而已". `SpeedContentTests` reads the
/// *composition* and passes — so the timeline model and `CompositionBuilder` are right, and
/// the fault must be somewhere after them. This runs the whole path the app runs: the store
/// mutation, the round-trip through the queue's persistence, the composition build, and the
/// encoder — then reads frames back out of the encoded file.
final class ExportSpeedTests: XCTestCase {

    /// Brightness of the encoded frame at `time`, which the `timecode` fixture sets from
    /// the source frame's own position: 0 at the start of the clip, 1 at the end.
    private func sourcePositionShown(in url: URL, at time: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let cgImage = try await generator.image(
            at: CMTime(seconds: time, preferredTimescale: 600)
        ).image

        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.couldNotReadFrame }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let i = ((height / 2) * width + width / 2) * 4
        return Double(pixels[i]) / 255.0
    }

    private enum Failure: Error { case couldNotReadFrame }

    /// Everything the app does between "user drags the speed slider" and "file on disk".
    @MainActor
    private func exportWithSpeed(_ speed: Double, roundTrip: Bool) async throws -> (URL, Double) {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 8, size: CGSize(width: 640, height: 480), pattern: .timecode
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: source))
        )
        let duration = try await AVURLAsset(url: source).load(.duration)
        let id = try XCTUnwrap(store.addVisualSegment(localURL: source,
                                                     nativeDuration: CMTimeGetSeconds(duration)))
        if speed != 1.0 { store.setVideoSpeed(segmentID: id, speed: speed) }

        var timeline = store.timeline
        if roundTrip {
            // The queue persists the edit and rebuilds from it later, so a field dropped in
            // encoding would leave a shortened slot playing at normal rate — exactly the
            // reported symptom.
            let data = try JSONEncoder().encode(timeline)
            timeline = try JSONDecoder().decode(EditorTimeline.self, from: data)
        }

        let restoredSpeed = try XCTUnwrap(timeline.segment(id: id)).speed
        let built = try await CompositionBuilder().build(from: timeline, renderSubtitles: true)
        let output = try await VideoCompressor().compress(
            source: .composition(
                built.composition,
                videoComposition: built.videoComposition,
                audioMix: built.audioMix,
                shotAt: nil
            ),
            settings: CompressionSettings(),
            dateMode: .now
        )
        return (output, restoredSpeed)
    }

    /// At 2x, one second into the *encoded file* must already show two seconds of footage.
    @MainActor
    func testDoubleSpeedSurvivesEncoding() async throws {
        let (normal, _) = try await exportWithSpeed(1.0, roundTrip: false)
        let (fast, _) = try await exportWithSpeed(2.0, roundTrip: false)
        defer { [normal, fast].forEach { try? FileManager.default.removeItem(at: $0) } }

        let atNormal = try await sourcePositionShown(in: normal, at: 2.0)
        let atFast = try await sourcePositionShown(in: fast, at: 2.0)
        print("EXPORT_SPEED at 2s: normal=\(atNormal) fast=\(atFast)")

        XCTAssertEqual(atNormal, 0.25, accuracy: 0.12, "sanity: normal playback")
        XCTAssertEqual(atFast, 0.50, accuracy: 0.12,
                       "the encoded file is not playing faster — only shortened")
    }

    /// The same, but through the persistence the queue uses. A speed lost in encoding leaves
    /// the shortened slot behind, which looks like a trimmed clip.
    @MainActor
    func testSpeedSurvivesThePersistedTimeline() async throws {
        let (normal, _) = try await exportWithSpeed(1.0, roundTrip: true)
        let (fast, restoredSpeed) = try await exportWithSpeed(2.0, roundTrip: true)
        defer { [normal, fast].forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(restoredSpeed, 2.0, accuracy: 1e-6,
                       "the saved timeline lost the speed setting")

        let atNormal = try await sourcePositionShown(in: normal, at: 2.0)
        let atFast = try await sourcePositionShown(in: fast, at: 2.0)
        print("EXPORT_SPEED_ROUNDTRIP at 2s: normal=\(atNormal) fast=\(atFast)")
        XCTAssertEqual(atFast, 0.50, accuracy: 0.12,
                       "speed is lost between saving the edit and encoding it")
    }

    /// The file must also be half as long — the part that already worked, kept as a guard so
    /// a fix for the rate cannot quietly break the duration.
    @MainActor
    func testDoubleSpeedHalvesTheEncodedDuration() async throws {
        let (normal, _) = try await exportWithSpeed(1.0, roundTrip: false)
        let (fast, _) = try await exportWithSpeed(2.0, roundTrip: false)
        defer { [normal, fast].forEach { try? FileManager.default.removeItem(at: $0) } }

        let normalSeconds = try await CMTimeGetSeconds(AVURLAsset(url: normal).load(.duration))
        let fastSeconds = try await CMTimeGetSeconds(AVURLAsset(url: fast).load(.duration))
        print("EXPORT_SPEED durations: normal=\(normalSeconds)s fast=\(fastSeconds)s")
        XCTAssertEqual(fastSeconds, normalSeconds / 2, accuracy: 0.4)
    }
}
