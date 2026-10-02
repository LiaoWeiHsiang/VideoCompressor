import XCTest
@testable import VideoCompressor

/// Whether clearing the scratch files frees space without taking anything that matters.
///
/// Prompted by the app reaching 24 GB in Settings: every compressed output is written to
/// the temporary directory and nothing ever deleted it. The risk in fixing that is deleting
/// too much, so these tests pin both halves — what must go, and what must stay.
final class StorageCleanerTests: XCTestCase {

    private func makeScratchFile(_ name: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-test-\(name)")
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    override func tearDown() {
        super.tearDown()
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil
        ) {
            for url in contents where url.lastPathComponent.hasPrefix("cleaner-test-") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func testScanCountsScratchFilesAndCleanRemovesThem() throws {
        let rubbish = try makeScratchFile("rubbish.mp4", bytes: 400_000)

        let before = StorageCleaner.scan(protecting: [])
        XCTAssertGreaterThanOrEqual(before.reclaimableBytes, 400_000)
        XCTAssertGreaterThanOrEqual(before.fileCount, 1)

        let freed = StorageCleaner.clean(protecting: [])
        XCTAssertGreaterThanOrEqual(freed.reclaimableBytes, 400_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rubbish.path))
    }

    /// A finished compression the user has not saved yet lives in tmp too. Deleting it
    /// would throw away work, which is worse than the disk usage being fixed.
    func testProtectedFilesSurviveAndAreReportedSeparately() throws {
        let keep = try makeScratchFile("keep.mp4", bytes: 300_000)
        let drop = try makeScratchFile("drop.mp4", bytes: 300_000)

        let scan = StorageCleaner.scan(protecting: [keep])
        XCTAssertGreaterThanOrEqual(scan.protectedBytes, 300_000,
                                    "a protected file should be reported, not counted as free space")

        let freed = StorageCleaner.clean(protecting: [keep])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path),
                      "a file still in use was deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.path))
        XCTAssertGreaterThanOrEqual(freed.protectedBytes, 300_000)
    }

    /// Protection must not depend on how the URL was spelled — the queue holds URLs built
    /// by different code paths, and `/private/var` versus `/var` is the same file.
    func testProtectionMatchesRegardlessOfPathForm() throws {
        let keep = try makeScratchFile("spelled.mp4", bytes: 200_000)
        let resolved = URL(fileURLWithPath: keep.resolvingSymlinksInPath().path)

        _ = StorageCleaner.clean(protecting: [resolved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path),
                      "the same file under a different path spelling was not protected")
    }

    /// The queue's own media lives in Application Support and is managed by QueueStore.
    /// Sweeping it would destroy pending edits, so it must be outside the sweep entirely.
    func testQueueMediaIsNeverTouched() throws {
        let source = try makeScratchFile("to-adopt.mp4", bytes: 150_000)
        let fileName = try XCTUnwrap(QueueStore.adoptMedia(at: source),
                                     "could not place a file in the queue's media store")
        let adopted = try XCTUnwrap(QueueStore.mediaURL(for: fileName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))

        _ = StorageCleaner.clean(protecting: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path),
                      "the sweep reached into the queue's media store")
        try? FileManager.default.removeItem(at: adopted)
    }

    /// Nothing to clean must read as nothing, not as a failure — the button is disabled on
    /// an empty report, so an inflated count would leave it offering work it cannot do.
    func testEmptyScratchReportsEmpty() {
        _ = StorageCleaner.clean(protecting: [])
        let report = StorageCleaner.scan(protecting: [])
        if report.fileCount == 0 {
            XCTAssertTrue(report.isEmpty)
            XCTAssertEqual(report.reclaimableBytes, 0)
        } else {
            // Another test's fixtures or a system file can sit in tmp; the invariant that
            // matters is that a non-zero count carries non-zero bytes.
            XCTAssertGreaterThan(report.reclaimableBytes, 0)
        }
    }
}
