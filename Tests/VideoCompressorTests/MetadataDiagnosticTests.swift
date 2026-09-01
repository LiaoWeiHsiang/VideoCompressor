import XCTest
import AVFoundation
import Photos
@testable import VideoCompressor

/// Diagnostic for the reported bug: a compressed clip shows the right date in Photos but
/// the compression time in Immich. Photos reads `PHAsset.creationDate` (which we set
/// explicitly); Immich re-extracts the date from the file itself. So the question is what
/// date actually ends up *inside* the exported file.
final class MetadataDiagnosticTests: XCTestCase {

    /// Surveys several library videos so a camera original can be told apart from this
    /// app's own previous outputs — sampling only the newest asset risks measuring a file
    /// we produced ourselves, which would already have lost its metadata.
    @MainActor
    func testSurveyLibraryVideoMetadata() async throws {
        // Deliberately reads the current status instead of requesting it. A request puts up
        // a system prompt, and in an automated run nothing dismisses it — the test then
        // hangs indefinitely rather than failing, which is far worse than skipping.
        // Grant access out of band: `xcrun simctl privacy <device> grant photos <bundle>`.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw XCTSkip("no photo access (status: \(status.rawValue)) — grant it out of band")
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 12
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        for (index, asset) in assets.enumerated() {
            let resources = PHAssetResource.assetResources(for: asset)
            let filename = resources.first?.originalFilename ?? "?"
            guard let video = try? await VideoFile.from(asset: asset) else {
                print("SURVEY[\(index)] filename=\(filename) — could not export")
                continue
            }
            defer { try? FileManager.default.removeItem(at: video.url) }

            let a = AVURLAsset(url: video.url)
            let creation = try? await a.load(.creationDate)
            var date: Date?
            if let creation { date = try? await creation.load(.dateValue) }
            let meta = (try? await a.load(.metadata)) ?? []
            let formats = (try? await a.load(.availableMetadataFormats)) ?? []

            print("SURVEY[\(index)] file=\(filename) phDate=\(String(describing: asset.creationDate)) assetDate=\(String(describing: date)) metaCount=\(meta.count) formats=\(formats.map(\.rawValue)) hasGPS=\(asset.location != nil)")
        }
    }

    /// Runs the real before/after comparison on a *camera original*, identified by having
    /// embedded metadata formats (this app's own outputs have none).
    @MainActor
    func testCameraOriginalLosesEmbeddedDateAfterCompression() async throws {
        // Deliberately reads the current status instead of requesting it. A request puts up
        // a system prompt, and in an automated run nothing dismisses it — the test then
        // hangs indefinitely rather than failing, which is far worse than skipping.
        // Grant access out of band: `xcrun simctl privacy <device> grant photos <bundle>`.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw XCTSkip("no photo access (status: \(status.rawValue)) — grant it out of band")
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 25
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Prefer an Insta360 clip (VID_<date>_*.mp4) — that is the actual footage in this
        // user's workflow, and it stores metadata differently from an iPhone original.
        var chosen: (PHAsset, URL, [AVMetadataFormat])?
        for wantInsta in [true, false] {
            for asset in assets {
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
                let isInsta = name.hasPrefix("VID_")
                guard isInsta == wantInsta else { continue }
                guard let video = try? await VideoFile.from(asset: asset) else { continue }
                let formats = (try? await AVURLAsset(url: video.url).load(.availableMetadataFormats)) ?? []
                if !formats.isEmpty {
                    chosen = (asset, video.url, formats)
                    break
                }
                try? FileManager.default.removeItem(at: video.url)
            }
            if chosen != nil { break }
        }

        guard let (asset, sourceURL, formats) = chosen else {
            throw XCTSkip("no source with embedded metadata found in the newest 25 videos")
        }
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        print("CHOSEN_FILE: \(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?")")
        print("CHOSEN_PHDATE: \(String(describing: asset.creationDate))")
        print("CHOSEN_FORMATS: \(formats.map(\.rawValue))")

        try await dump(label: "SOURCE", url: sourceURL)

        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            inputURL: sourceURL,
            preset: .small,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            dateMode: .original
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await dump(label: "OUTPUT", url: outputURL)
        print("OUTPUT_FILENAME: \(outputURL.lastPathComponent)")

        // The name must describe when the footage was shot, not when it was compressed.
        let expected = VideoCompressor.makeOutputFilename(shotAt: asset.creationDate)
        XCTAssertTrue(
            outputURL.lastPathComponent.hasPrefix(expected),
            "expected a name starting with \(expected), got \(outputURL.lastPathComponent)"
        )
    }

    private func dump(label: String, url: URL) async throws {
        let asset = AVURLAsset(url: url)

        let creationItem = try? await asset.load(.creationDate)
        var resolved: Date?
        if let creationItem { resolved = try? await creationItem.load(.dateValue) }
        print("\(label)_AVASSET_CREATIONDATE: \(String(describing: resolved))")

        let metadata = (try? await asset.load(.metadata)) ?? []
        print("\(label)_METADATA_COUNT: \(metadata.count)")
        for item in metadata {
            let value = (try? await item.load(.stringValue)) ?? "<non-string>"
            print("\(label)_META: \(item.identifier?.rawValue ?? "nil") = \(value)")
        }

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        print("\(label)_FORMATS: \(formats.map(\.rawValue))")
        for format in formats {
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            for item in items {
                let value = (try? await item.load(.stringValue)) ?? "<non-string>"
                print("\(label)_FMT[\(format.rawValue)]: \(item.identifier?.rawValue ?? "nil") = \(value)")
            }
        }
    }
}
