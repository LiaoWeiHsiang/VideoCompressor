import Foundation

/// Rewrites the creation/modification timestamps inside an MP4's own box headers.
///
/// `AVAssetWriter` stamps `mvhd`, `tkhd` and `mdhd` with the time of encoding and offers no
/// way to change it. Writing a `com.apple.quicktime.creationdate` metadata item — which the
/// compressor already does — is enough for `AVAsset.creationDate`, but most other readers
/// take the header instead: Finder and the Files app, exiftool's `CreateDate`,
/// `TrackCreateDate` and `MediaCreateDate`, and the servers that use exiftool, Immich among
/// them. So a clip compressed with "same as the original" still looked like it was shot the
/// moment it was compressed everywhere except inside this app.
///
/// Only the fixed-size timestamp fields are overwritten, in place: no box is moved, resized
/// or reordered, so the file stays byte-for-byte valid apart from those fields.
enum MovieCreationDatePatcher {

    /// QuickTime counts seconds from 1904-01-01 00:00 UTC, 66 years before the Unix epoch.
    private static let epochOffset: Int64 = 2_082_844_800

    enum Failure: Error {
        case unreadable
        case noMovieBox
    }

    /// Set every header timestamp in `fileURL` to `date`.
    ///
    /// Returns the number of boxes patched, which is what a test can assert on: silently
    /// patching nothing is the failure mode that would otherwise look like success.
    @discardableResult
    static func apply(_ date: Date, to fileURL: URL) throws -> Int {
        guard let handle = try? FileHandle(forUpdating: fileURL) else { throw Failure.unreadable }
        defer { try? handle.close() }

        let fileLength = try fileSize(of: handle)
        guard let moov = try findBox(type: "moov", in: handle, start: 0, end: fileLength) else {
            throw Failure.noMovieBox
        }

        var patched = 0
        // The movie header, then one set per track. A reader may consult any of them, so
        // leaving some behind would just move the inconsistency somewhere else.
        if let mvhd = try findBox(type: "mvhd", in: handle, start: moov.contentStart, end: moov.end) {
            try stamp(date, box: mvhd, in: handle)
            patched += 1
        }
        for trak in try findBoxes(type: "trak", in: handle, start: moov.contentStart, end: moov.end) {
            if let tkhd = try findBox(type: "tkhd", in: handle, start: trak.contentStart, end: trak.end) {
                try stamp(date, box: tkhd, in: handle)
                patched += 1
            }
            if let mdia = try findBox(type: "mdia", in: handle, start: trak.contentStart, end: trak.end),
               let mdhd = try findBox(type: "mdhd", in: handle, start: mdia.contentStart, end: mdia.end) {
                try stamp(date, box: mdhd, in: handle)
                patched += 1
            }
        }
        return patched
    }

    /// Reads back what a header says, so a test can check the file rather than trusting the
    /// writer. Returns nil when there is no movie box.
    static func movieHeaderDate(of fileURL: URL) throws -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { throw Failure.unreadable }
        defer { try? handle.close() }

        let fileLength = try fileSize(of: handle)
        guard let moov = try findBox(type: "moov", in: handle, start: 0, end: fileLength),
              let mvhd = try findBox(type: "mvhd", in: handle, start: moov.contentStart, end: moov.end)
        else { return nil }

        let version = try byte(at: mvhd.contentStart, in: handle)
        let field = mvhd.contentStart + 4          // after version(1) + flags(3)
        let seconds: Int64
        if version == 1 {
            seconds = Int64(try readUInt64(at: field, in: handle))
        } else {
            seconds = Int64(try readUInt32(at: field, in: handle))
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds - epochOffset))
    }

    // MARK: - Box walking

    private struct Box {
        /// First byte of the box's payload — after the size/type header, and after the
        /// 64-bit size when the box uses one.
        let contentStart: UInt64
        /// One past the last byte of the box.
        let end: UInt64
    }

    private static func stamp(_ date: Date, box: Box, in handle: FileHandle) throws {
        let version = try byte(at: box.contentStart, in: handle)
        let seconds = Int64(date.timeIntervalSince1970) + epochOffset
        let creation = box.contentStart + 4        // version(1) + flags(3)

        if version == 1 {
            let value = UInt64(max(seconds, 0)).bigEndian
            try write(Data(bytes: [value].withUnsafeBytes { Array($0) }, count: 8), at: creation, in: handle)
            try write(Data(bytes: [value].withUnsafeBytes { Array($0) }, count: 8), at: creation + 8, in: handle)
        } else {
            // 32-bit fields overflow in 2040; clamping keeps a nonsense date from wrapping
            // round to 1904, which would read as a valid-looking timestamp.
            let value = UInt32(clamping: seconds).bigEndian
            try write(Data(bytes: [value].withUnsafeBytes { Array($0) }, count: 4), at: creation, in: handle)
            try write(Data(bytes: [value].withUnsafeBytes { Array($0) }, count: 4), at: creation + 4, in: handle)
        }
    }

    private static func findBox(
        type: String, in handle: FileHandle, start: UInt64, end: UInt64
    ) throws -> Box? {
        try findBoxes(type: type, in: handle, start: start, end: end, stopAtFirst: true).first
    }

    private static func findBoxes(
        type: String, in handle: FileHandle, start: UInt64, end: UInt64, stopAtFirst: Bool = false
    ) throws -> [Box] {
        var found: [Box] = []
        var cursor = start

        // Labelled, because `break` inside a `switch` leaves the switch, not the loop — the
        // bail-outs below have to abandon the whole scan.
        scan: while cursor + 8 <= end {
            let size32 = try readUInt32(at: cursor, in: handle)
            guard let boxType = try? readType(at: cursor + 4, in: handle) else { break scan }

            let contentStart: UInt64
            let boxEnd: UInt64
            switch size32 {
            case 1:
                // 64-bit size: the real length follows the type.
                let large = try readUInt64(at: cursor + 8, in: handle)
                guard large >= 16 else { break scan }
                contentStart = cursor + 16
                boxEnd = cursor + large
            case 0:
                // Runs to the end of its container.
                contentStart = cursor + 8
                boxEnd = end
            default:
                guard size32 >= 8 else { break scan }
                contentStart = cursor + 8
                boxEnd = cursor + UInt64(size32)
            }
            guard boxEnd > cursor, boxEnd <= end else { break scan }

            if boxType == type {
                found.append(Box(contentStart: contentStart, end: boxEnd))
                if stopAtFirst { return found }
            }
            cursor = boxEnd
        }
        return found
    }

    // MARK: - Primitive reads

    private static func fileSize(of handle: FileHandle) throws -> UInt64 {
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return end
    }

    private static func read(_ count: Int, at offset: UInt64, in handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure.unreadable
        }
        return data
    }

    private static func byte(at offset: UInt64, in handle: FileHandle) throws -> UInt8 {
        try read(1, at: offset, in: handle)[0]
    }

    private static func readUInt32(at offset: UInt64, in handle: FileHandle) throws -> UInt32 {
        let data = try read(4, at: offset, in: handle)
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(at offset: UInt64, in handle: FileHandle) throws -> UInt64 {
        let data = try read(8, at: offset, in: handle)
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func readType(at offset: UInt64, in handle: FileHandle) throws -> String {
        let data = try read(4, at: offset, in: handle)
        guard let type = String(data: data, encoding: .ascii) else { throw Failure.unreadable }
        return type
    }

    private static func write(_ data: Data, at offset: UInt64, in handle: FileHandle) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }
}
