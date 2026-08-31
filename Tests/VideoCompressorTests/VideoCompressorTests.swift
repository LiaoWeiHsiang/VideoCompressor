import XCTest
import Combine
import CoreGraphics
import AVFoundation
@testable import VideoCompressor

final class VideoCompressorTests: XCTestCase {
    @MainActor
    func testCompressionProgressAdvancesPastZero() async throws {
        let genStart = Date()
        let inputURL = try await SyntheticVideoFactory.makeVideo(seconds: 12, size: CGSize(width: 1920, height: 1080))
        print("SYNTHETIC_GEN_SECONDS: \(Date().timeIntervalSince(genStart))")
        let inputSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(inputSize ?? 0, 0, "Synthetic input video was not written")

        let compressor = VideoCompressor()
        var observedProgressValues: [(Double, TimeInterval)] = []
        var cancellables = Set<AnyCancellable>()

        let compressStart = Date()
        compressor.$progress
            .sink { value in
                observedProgressValues.append((value, Date().timeIntervalSince(compressStart)))
            }
            .store(in: &cancellables)

        let outputURL = try await compressor.compress(inputURL: inputURL, preset: .small)
        print("COMPRESS_SECONDS: \(Date().timeIntervalSince(compressStart))")
        print("PROGRESS_SAMPLES: \(observedProgressValues)")

        let sawMidProgress = observedProgressValues.contains { $0.0 > 0.0 && $0.0 < 1.0 }
        XCTAssertTrue(
            sawMidProgress,
            "Progress never reported a value between 0 and 1; observed: \(observedProgressValues)"
        )
        XCTAssertEqual(observedProgressValues.last?.0, 1.0, "Progress did not reach 100% on completion")

        let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let outputSize = (outputAttributes[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(outputSize, 0, "Compressed output file is empty")
        print("INPUT_BYTES: \(inputSize ?? 0), OUTPUT_BYTES: \(outputSize)")

        // This is the actual bug report: compressing must never produce a larger file
        // than the source, regardless of how the source happened to be encoded.
        XCTAssertLessThan(
            outputSize,
            inputSize ?? 0,
            "Compressed output (\(outputSize) bytes) is not smaller than the source (\(inputSize ?? 0) bytes)"
        )

        // The .small preset targets 2.5 Mbps, adaptively capped at 85% of the source's own
        // bitrate; verify the encoder honored that (with headroom for soft rate control)
        // instead of silently overshooting to a much larger bitrate.
        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration = try await outputAsset.load(.duration)
        let outputSeconds = CMTimeGetSeconds(outputDuration)
        let observedBitsPerSecond = Double(outputSize) * 8 / outputSeconds
        let inputBitsPerSecond = Double(inputSize ?? 0) * 8 / outputSeconds
        let expectedTarget = min(Double(CompressionPreset.small.bitrate), inputBitsPerSecond * 0.85)
        XCTAssertLessThan(
            observedBitsPerSecond,
            expectedTarget * 1.5,
            "Output bitrate (\(observedBitsPerSecond)) overshot the expected target (\(expectedTarget)) by more than 50%"
        )

        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    @MainActor
    func testCompressionPreservesCreationDateAndLocation() async throws {
        let sourceDate = ISO8601DateFormatter().date(from: "2024-05-06T12:30:00Z")!
        let sourceLocationISO6709 = "+25.0330+121.5654/"

        let inputURL = try await SyntheticVideoFactory.makeVideo(
            seconds: 3,
            size: CGSize(width: 640, height: 480),
            creationDate: sourceDate,
            locationISO6709: sourceLocationISO6709
        )

        let inputMetadata = try await AVURLAsset(url: inputURL).load(.metadata)
        XCTAssertTrue(
            inputMetadata.contains { $0.identifier == .quickTimeMetadataCreationDate },
            "Test setup failed: synthetic source video has no creation date metadata"
        )

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(inputURL: inputURL, preset: .small)

        let outputMetadata = try await AVURLAsset(url: outputURL).load(.metadata)
        print("OUTPUT_METADATA: \(outputMetadata.map { ($0.identifier?.rawValue, $0.stringValue) })")

        // The mp4 container remaps the QuickTime metadata keyspace on write (observed
        // identifier is "uiso/date" / "uiso/loci" rather than the quickTimeMetadata*
        // constants), so match on the actual preserved values instead of the exact
        // identifier enum case.
        let expectedDateString = ISO8601DateFormatter().string(from: sourceDate)
        XCTAssertTrue(
            outputMetadata.contains { $0.stringValue == expectedDateString },
            "Compressed output lost its creation date metadata; got: \(outputMetadata.map { $0.stringValue })"
        )

        XCTAssertTrue(
            outputMetadata.contains { $0.stringValue?.hasPrefix("+25.0330+121.5654") == true },
            "Compressed output lost its GPS location metadata; got: \(outputMetadata.map { $0.stringValue })"
        )

        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    @MainActor
    func testDateModeNowRestampsDateButKeepsLocation() async throws {
        let sourceDate = ISO8601DateFormatter().date(from: "2024-05-06T12:30:00Z")!
        let sourceLocationISO6709 = "+25.0330+121.5654/"

        let inputURL = try await SyntheticVideoFactory.makeVideo(
            seconds: 3,
            size: CGSize(width: 640, height: 480),
            creationDate: sourceDate,
            locationISO6709: sourceLocationISO6709
        )

        let compressor = VideoCompressor()
        let compressStart = Date()
        let outputURL = try await compressor.compress(inputURL: inputURL, preset: .small, dateMode: .now)

        let outputMetadata = try await AVURLAsset(url: outputURL).load(.metadata)
        print("NOW_MODE_METADATA: \(outputMetadata.map { ($0.identifier?.rawValue, $0.stringValue) })")

        // The original shooting date must be gone...
        let staleDateString = ISO8601DateFormatter().string(from: sourceDate)
        XCTAssertFalse(
            outputMetadata.contains { $0.stringValue == staleDateString },
            "dateMode .now still carried the source's original creation date"
        )

        // ...replaced by a timestamp from around the time we compressed.
        let stampedDate = outputMetadata
            .compactMap { $0.stringValue }
            .compactMap { ISO8601DateFormatter().date(from: $0) }
            .first
        let stamped = try XCTUnwrap(stampedDate, "dateMode .now wrote no creation date at all")
        XCTAssertEqual(stamped.timeIntervalSince(compressStart), 0, accuracy: 120, "Stamped date is not near the compression time")

        // Location must survive regardless of the date choice.
        XCTAssertTrue(
            outputMetadata.contains { $0.stringValue?.hasPrefix("+25.0330+121.5654") == true },
            "dateMode .now wrongly dropped GPS location; got: \(outputMetadata.map { $0.stringValue })"
        )

        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Regression guard for the Insta360 date bug.
    ///
    /// Those clips record the shooting time only in the movie header and carry no
    /// creation-date metadata item, so an implementation that merely copies the source's
    /// items writes no date at all — and `AVAssetWriter` then stamps the file with the
    /// encoding time. Photos still looked correct (its date is stored separately), but an
    /// Immich server reading the file saw the compression time.
    @MainActor
    func testCreationDateIsWrittenEvenWhenSourceHasNoDateMetadataItem() throws {
        let shotAt = ISO8601DateFormatter().date(from: "2026-08-15T03:40:00Z")!

        // Source metadata with no date item at all — exactly what an Insta360 file has.
        let vendorItem = AVMutableMetadataItem()
        vendorItem.identifier = AVMetadataIdentifier("uiso/AMBA")
        vendorItem.value = "vendor-blob" as NSString

        let result = VideoCompressor.metadata(
            from: [vendorItem],
            dateMode: .original,
            sourceCreationDate: shotAt
        )

        let dates = result.compactMap { item -> String? in
            guard item.identifier == .quickTimeMetadataCreationDate else { return nil }
            return item.value as? String
        }
        XCTAssertEqual(dates.count, 1, "exactly one creation-date item should be written")
        XCTAssertEqual(ISO8601DateFormatter().date(from: dates[0]), shotAt)

        // The vendor's own atoms must still ride along untouched.
        XCTAssertTrue(result.contains { $0.identifier == AVMetadataIdentifier("uiso/AMBA") })
    }

    /// `.now` must restamp regardless of what the source carried.
    @MainActor
    func testNowModeStampsCurrentDateWithNoSourceDate() throws {
        let before = Date()
        let result = VideoCompressor.metadata(from: [], dateMode: .now, sourceCreationDate: nil)

        let stamped = try XCTUnwrap(result.first { $0.identifier == .quickTimeMetadataCreationDate })
        let value = try XCTUnwrap(stamped.value as? String)
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: value))
        XCTAssertEqual(parsed.timeIntervalSince(before), 0, accuracy: 120)
    }

    /// With no date available anywhere, we must not invent one.
    @MainActor
    func testNoDateIsWrittenWhenSourceDateIsUnknown() throws {
        let result = VideoCompressor.metadata(from: [], dateMode: .original, sourceCreationDate: nil)
        XCTAssertTrue(result.isEmpty, "should not fabricate a creation date")
    }

    @MainActor
    func testOutputFilenameUsesShootingDate() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 15
        components.hour = 20; components.minute = 39
        let shotAt = Calendar.current.date(from: components)!

        XCTAssertEqual(
            VideoCompressor.makeOutputFilename(shotAt: shotAt),
            "202608152039_compressed"
        )
    }

    /// Without a known shooting date the name must still be usable, not empty or "nil".
    @MainActor
    func testOutputFilenameFallsBackToNow() {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 2
        components.hour = 3; components.minute = 4
        let now = Calendar.current.date(from: components)!

        XCTAssertEqual(
            VideoCompressor.makeOutputFilename(shotAt: nil, now: now),
            "202601020304_compressed"
        )
    }

    @MainActor
    func testCompressionAppliesTrimRange() async throws {
        let inputURL = try await SyntheticVideoFactory.makeVideo(seconds: 12, size: CGSize(width: 640, height: 480))

        let compressor = VideoCompressor()
        let trimRange = CMTimeRange(
            start: CMTime(seconds: 3, preferredTimescale: 600),
            end: CMTime(seconds: 8, preferredTimescale: 600)
        )
        let outputURL = try await compressor.compress(inputURL: inputURL, preset: .small, timeRange: trimRange)

        let outputDuration = try await AVURLAsset(url: outputURL).load(.duration)
        let outputSeconds = CMTimeGetSeconds(outputDuration)
        print("TRIMMED_OUTPUT_SECONDS: \(outputSeconds)")

        // Requested a 5-second slice (3s-8s) out of a 12-second source; the output should
        // reflect that slice, not the full original duration.
        XCTAssertEqual(outputSeconds, 5.0, accuracy: 0.5, "Trimmed output duration should be ~5s, not the full 12s source")

        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
}
