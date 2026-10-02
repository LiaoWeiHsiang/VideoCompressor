import XCTest
import AVFoundation
@testable import VideoCompressor

/// Whether "same as the original video" actually reaches the file's own header.
///
/// Reported as "為什麼我選跟原影片時間一樣 壓縮出來還是當下時間". The existing tests only read
/// the date back through `AVAsset.creationDate`, which is satisfied by the
/// `com.apple.quicktime.creationdate` metadata item the compressor writes — so they passed
/// while the mvhd/tkhd/mdhd headers still said "now". Those headers are what Finder, the
/// Files app, exiftool and the servers built on exiftool read, which is nearly everything
/// outside this app.
final class MovieHeaderDateTests: XCTestCase {

    private func makeSource(shotAt: Date) async throws -> URL {
        try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2, size: CGSize(width: 320, height: 240)
        )
    }

    /// The header must carry the source's date, not the encode time.
    func testOriginalDateReachesTheMovieHeader() async throws {
        let shotAt = Date(timeIntervalSince1970: 1_500_000_000)   // 2017-07-14
        let source = try await makeSource(shotAt: shotAt)
        defer { try? FileManager.default.removeItem(at: source) }

        // The fixture writes no creation date of its own, so supply it the way an edited
        // clip does — through the composition source's `shotAt`.
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(videoTracks.first)
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                  of: sourceTrack, at: .zero)

        let output = try await VideoCompressor().compress(
            source: .composition(composition, videoComposition: nil, audioMix: nil, shotAt: shotAt),
            settings: CompressionSettings(),
            dateMode: .original
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let headerDate = try XCTUnwrap(MovieCreationDatePatcher.movieHeaderDate(of: output),
                                       "no movie header found in the output")
        print("HEADER_DATE: \(headerDate) expected \(shotAt)")
        XCTAssertEqual(headerDate.timeIntervalSince1970, shotAt.timeIntervalSince1970, accuracy: 2,
                       "the movie header still carries the encode time")

        // And the metadata item must agree with it — two readers of the same file should
        // never get two different answers.
        let item = try await AVURLAsset(url: output).load(.creationDate)
        let unwrappedItem = try XCTUnwrap(item)
        let loadedDate = try await unwrappedItem.load(.dateValue)
        let metadataDate = try XCTUnwrap(loadedDate)
        XCTAssertEqual(metadataDate.timeIntervalSince1970, shotAt.timeIntervalSince1970, accuracy: 2)
    }

    /// `.now` must still restamp, so choosing it is not quietly ignored.
    func testNowModeStampsTheHeaderWithTheCurrentTime() async throws {
        let shotAt = Date(timeIntervalSince1970: 1_500_000_000)
        let source = try await makeSource(shotAt: shotAt)
        defer { try? FileManager.default.removeItem(at: source) }

        let before = Date()
        let output = try await VideoCompressor().compress(
            inputURL: source, preset: .small, dateMode: .now
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let headerDate = try XCTUnwrap(MovieCreationDatePatcher.movieHeaderDate(of: output))
        XCTAssertGreaterThanOrEqual(headerDate.timeIntervalSince1970,
                                    before.timeIntervalSince1970 - 2)
        XCTAssertLessThanOrEqual(headerDate.timeIntervalSince1970,
                                 Date().timeIntervalSince1970 + 2)
    }

    /// The patcher must report what it changed. Patching nothing — a container it did not
    /// understand, say — would otherwise look exactly like success.
    func testPatcherReportsEveryHeaderItChanged() async throws {
        let source = try await makeSource(shotAt: Date())
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await VideoCompressor().compress(
            inputURL: source, preset: .small, dateMode: .now
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let target = Date(timeIntervalSince1970: 1_000_000_000)
        let patched = try MovieCreationDatePatcher.apply(target, to: output)
        // One mvhd, plus a tkhd and an mdhd for each of the video and audio tracks.
        XCTAssertGreaterThanOrEqual(patched, 3, "patched \(patched) headers")

        let readBack = try XCTUnwrap(MovieCreationDatePatcher.movieHeaderDate(of: output))
        XCTAssertEqual(readBack.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 2)

        // Patching timestamps must not disturb anything else: the file still has to play.
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "the file stopped being readable after patching")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5)
    }
}
