import XCTest
import AVFoundation
@testable import VideoCompressor

/// Resolution, frame rate, audio and target size, plus the size estimate shown before
/// compressing.
final class CompressionSettingsTests: XCTestCase {

    private func bytes(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    // MARK: - Resolution

    @MainActor
    func testResolutionCapIsHonoured() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 3, size: CGSize(width: 3840, height: 2160)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        for (resolution, expectedShortEdge) in [
            (CompressionSettings.Resolution.p720, 720.0),
            (.p1080, 1080.0),
            (.original, 2160.0)
        ] {
            var settings = CompressionSettings()
            settings.resolution = resolution

            let compressor = VideoCompressor()
            let output = try await compressor.compress(
                source: .file(source), settings: settings
            )
            defer { try? FileManager.default.removeItem(at: output) }

            let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
            print("RES_\(resolution.rawValue): \(Int(size.width))x\(Int(size.height))")
            XCTAssertEqual(min(size.width, size.height), expectedShortEdge, accuracy: 2,
                           "\(resolution.rawValue) produced the wrong size")
        }
    }

    /// Footage below the cap must not be blown up — upscaling only adds bytes.
    @MainActor
    func testSmallFootageIsNotUpscaled() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2, size: CGSize(width: 640, height: 480)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        var settings = CompressionSettings()
        settings.resolution = .original

        let compressor = VideoCompressor()
        let output = try await compressor.compress(source: .file(source), settings: settings)
        defer { try? FileManager.default.removeItem(at: output) }

        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size.width, 640, accuracy: 2, "small footage was upscaled")
    }

    // MARK: - Frame rate

    /// Halving the rate must halve the frames while leaving the clip its own length —
    /// dropping frames, not re-timing them.
    @MainActor
    func testFrameRateCapDropsFramesWithoutChangingDuration() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 4, size: CGSize(width: 1280, height: 720), fps: 60
        )
        defer { try? FileManager.default.removeItem(at: source) }

        var settings = CompressionSettings()
        settings.frameRateCap = .fps30

        let compressor = VideoCompressor()
        let output = try await compressor.compress(source: .file(source), settings: settings)
        defer { try? FileManager.default.removeItem(at: output) }

        let asset = AVURLAsset(url: output)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let rate = try await track.load(.nominalFrameRate)
        print("FPS_CAP: duration=\(String(format: "%.2f", seconds))s rate=\(rate)")

        XCTAssertEqual(seconds, 4.0, accuracy: 0.4, "capping the rate must not change length")
        XCTAssertLessThan(rate, 45, "frames were not actually dropped")
    }

    /// Fewer frames must mean a smaller file — that is the entire reason for the setting.
    @MainActor
    func testFrameRateCapProducesASmallerFile() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 4, size: CGSize(width: 1280, height: 720), fps: 60
        )
        defer { try? FileManager.default.removeItem(at: source) }

        var uncapped = CompressionSettings()
        uncapped.quality = .preset(.high)
        var capped = uncapped
        capped.frameRateCap = .fps30

        let a = try await VideoCompressor().compress(source: .file(source), settings: uncapped)
        let b = try await VideoCompressor().compress(source: .file(source), settings: capped)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        print("FPS_SIZES: 60fps=\(bytes(a)) 30fps=\(bytes(b))")
        XCTAssertLessThan(bytes(b), bytes(a), "halving the frame rate did not save anything")
    }

    // MARK: - Audio

    @MainActor
    func testAudioCanBeDropped() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(seconds: 3)
        defer { try? FileManager.default.removeItem(at: source) }

        var settings = CompressionSettings()
        settings.includeAudio = false

        let compressor = VideoCompressor()
        let output = try await compressor.compress(source: .file(source), settings: settings)
        defer { try? FileManager.default.removeItem(at: output) }

        let audioTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "audio was kept despite being switched off")

        let videoTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "dropping audio must not disturb the picture")
    }

    // MARK: - Target size

    @MainActor
    func testTargetSizeIsRoughlyMet() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 6, size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        var settings = CompressionSettings()
        settings.quality = .targetSize(megabytes: 1.0)

        let compressor = VideoCompressor()
        let output = try await compressor.compress(source: .file(source), settings: settings)
        defer { try? FileManager.default.removeItem(at: output) }

        let megabytes = Double(bytes(output)) / 1_048_576
        print("TARGET_SIZE: asked 1.0 MB, got \(String(format: "%.2f", megabytes)) MB")
        // Rate control cannot hit a size exactly; what matters is not overshooting badly.
        XCTAssertLessThan(megabytes, 1.6, "target size was overshot")
    }

    // MARK: - Estimate

    /// The estimate has to track the encoder, so it is checked against a real encode
    /// rather than against its own arithmetic.
    @MainActor
    func testEstimateIsCloseToTheActualResult() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 6, size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let sourceBitrate = Double(try await track.load(.estimatedDataRate))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        var settings = CompressionSettings()
        settings.quality = .preset(.small)

        let estimate = try XCTUnwrap(CompressionEstimator.estimate(
            settings: settings, durationSeconds: duration, sourceBitrate: sourceBitrate
        ))

        let output = try await VideoCompressor().compress(source: .file(source), settings: settings)
        defer { try? FileManager.default.removeItem(at: output) }

        let actual = Double(bytes(output))
        let predicted = Double(estimate.bytes)
        let ratio = actual / predicted
        print("ESTIMATE: predicted=\(Int(predicted)) actual=\(Int(actual)) ratio=\(String(format: "%.2f", ratio))")
        print("ESTIMATE_TEXT: \(CompressionEstimator.describe(estimate))")

        XCTAssertGreaterThan(ratio, 0.4, "estimate was far too high")
        XCTAssertLessThan(ratio, 2.0, "estimate was far too low")
    }

    /// Dropping audio must show up in the estimate, not just in the file.
    func testEstimateAccountsForAudioBeingDropped() throws {
        var withAudio = CompressionSettings()
        withAudio.quality = .preset(.small)
        var without = withAudio
        without.includeAudio = false

        let a = try XCTUnwrap(CompressionEstimator.estimate(
            settings: withAudio, durationSeconds: 60, sourceBitrate: 20_000_000))
        let b = try XCTUnwrap(CompressionEstimator.estimate(
            settings: without, durationSeconds: 60, sourceBitrate: 20_000_000))
        XCTAssertLessThan(b.bytes, a.bytes, "dropping audio should lower the estimate")
    }

    /// When the source is already smaller than the request, say so — raising the quality
    /// setting would otherwise look like it does nothing.
    func testEstimateReportsWhenTheSourceIsTheLimit() throws {
        var settings = CompressionSettings()
        settings.quality = .preset(.high)          // 8 Mbps requested

        let estimate = try XCTUnwrap(CompressionEstimator.estimate(
            settings: settings, durationSeconds: 30, sourceBitrate: 3_000_000))
        XCTAssertTrue(estimate.limitedBySource, "should report that the source is the ceiling")
        print("ESTIMATE_LIMITED: \(CompressionEstimator.describe(estimate))")
    }
}
