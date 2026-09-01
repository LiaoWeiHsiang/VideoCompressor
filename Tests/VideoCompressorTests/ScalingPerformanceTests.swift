import XCTest
import AVFoundation
import CoreGraphics
@testable import VideoCompressor

/// Measures the path real footage takes.
///
/// The action camera this app was written for shoots 4K, so every clip goes through the
/// downscale to 1080p — which is the one per-frame operation in the pipeline. The synthetic
/// clips in the other tests are already 1080p or smaller and skip it entirely, so nothing
/// so far has measured the case that actually matters.
final class ScalingPerformanceTests: XCTestCase {

    @MainActor
    func testFourKDownscaleThroughput() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 6,
            size: CGSize(width: 3840, height: 2160)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let compressor = VideoCompressor()
        let started = Date()
        let outputURL = try await compressor.compress(inputURL: source, preset: .medium)
        let elapsed = Date().timeIntervalSince(started)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let tracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        print("SCALE_4K_ELAPSED: \(String(format: "%.2f", elapsed))s for 6s of 4K → \(Int(size.width))x\(Int(size.height))")
        print("SCALE_4K_REALTIME_FACTOR: \(String(format: "%.2f", 6.0 / elapsed))x")

        XCTAssertEqual(min(size.width, size.height), 1080, accuracy: 2, "4K should come out 1080p")
    }

    /// The same duration with no scaling, as a control: the difference between the two is
    /// what the downscale costs.
    @MainActor
    func testMatchedSourceThroughputWithoutScaling() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 6,
            size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let compressor = VideoCompressor()
        let started = Date()
        let outputURL = try await compressor.compress(inputURL: source, preset: .medium)
        let elapsed = Date().timeIntervalSince(started)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        print("SCALE_1080_ELAPSED: \(String(format: "%.2f", elapsed))s for 6s of 1080p (no scaling)")
        print("SCALE_1080_REALTIME_FACTOR: \(String(format: "%.2f", 6.0 / elapsed))x")
    }
}
