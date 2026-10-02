import Foundation

/// Finds and removes the scratch files compression leaves behind.
///
/// Every compressed output is written to the temporary directory, and nothing ever deleted
/// it: saving to Photos or uploading to Immich copies the file elsewhere and leaves the
/// original in place. iOS purges tmp only under real storage pressure, so a few months of
/// use grew the app to 24 GB. Editing adds more of the same — rendered stills, exporter
/// intermediates, copies made when a clip is imported.
///
/// Deliberately limited to scratch locations. The queue's own media lives in Application
/// Support and is pruned by `QueueStore` against what the queue still references; deleting
/// from there would destroy pending work, which is the one thing this must not do.
enum StorageCleaner {

    struct Report: Equatable {
        var reclaimableBytes: Int64 = 0
        var fileCount: Int = 0
        /// Scratch files that are still in use and were therefore left alone.
        var protectedBytes: Int64 = 0

        var isEmpty: Bool { fileCount == 0 }

        var formattedReclaimable: String { Report.format(reclaimableBytes) }

        static func format(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useMB, .useGB]
            return formatter.string(fromByteCount: bytes)
        }
    }

    /// Where scratch files accumulate. The share extension's Inbox is included: a file
    /// handed over by another app stays there after it has been copied into the queue.
    private static var scratchRoots: [URL] {
        var roots = [FileManager.default.temporaryDirectory]
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.weihsiangliao.VideoCompressor"
        ) {
            roots.append(container.appendingPathComponent("Inbox", isDirectory: true))
        }
        return roots
    }

    /// What could be freed right now, without deleting anything.
    static func scan(protecting protectedURLs: Set<URL>) -> Report {
        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        var report = Report()

        for (url, size) in scratchFiles() {
            if protectedPaths.contains(url.standardizedFileURL.path) {
                report.protectedBytes += size
            } else {
                report.reclaimableBytes += size
                report.fileCount += 1
            }
        }
        return report
    }

    /// Deletes what `scan` reported, returning what was actually freed.
    ///
    /// The caller must pass every file the app still needs — a finished compression waiting
    /// to be saved, the source of a pending edit. A file that cannot be deleted is skipped
    /// rather than aborting the sweep, so one locked file does not leave the rest behind.
    @discardableResult
    static func clean(protecting protectedURLs: Set<URL>) -> Report {
        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        var freed = Report()

        for (url, size) in scratchFiles() {
            guard !protectedPaths.contains(url.standardizedFileURL.path) else {
                freed.protectedBytes += size
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                freed.reclaimableBytes += size
                freed.fileCount += 1
            } catch {
                // Most likely still open — an in-flight encode. Leave it.
                continue
            }
        }
        return freed
    }

    // MARK: - Enumeration

    /// Every regular file under the scratch roots, with its size on disk.
    ///
    /// Directories are not reported: removing a file is enough to free the space, and
    /// deleting the directories themselves would race with code that expects tmp to exist.
    private static func scratchFiles() -> [(URL, Int64)] {
        var results: [(URL, Int64)] = []

        for root in scratchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey
                ])
                guard values?.isRegularFile == true else { continue }
                // Allocated size is what the volume actually gave the file, which is what
                // Settings reports; fileSize is the fallback when the volume omits it.
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                results.append((url, size))
            }
        }
        return results
    }
}
