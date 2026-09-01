import XCTest
import AVFoundation
import Photos
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Runs a real library clip through both paths and prints what actually happens to it.
///
/// Synthetic fixtures cover portrait footage in both storage forms and neither path
/// disturbs it, so whatever makes a specific clip come out rotated and cropped is a
/// property those fixtures do not have — codec, bit depth, pixel aspect ratio, an unusual
/// transform. Rather than keep guessing at fixtures, read the real file.
final class RealClipOrientationDiagnostic: XCTestCase {

    /// Set to a filename fragment to target one clip; empty surveys the newest videos.
    private static let filenameFilter = "IMG_4510"

    @MainActor
    func testDiagnosePortraitClipThroughBothPaths() async throws {
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
        options.fetchLimit = 60
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        let matches = assets.filter { asset in
            guard !Self.filenameFilter.isEmpty else { return true }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
            return name.localizedCaseInsensitiveContains(Self.filenameFilter)
        }
        guard let asset = matches.first else {
            // Not a failure: say what *is* there so the filter can be corrected.
            let names = assets.prefix(20).map {
                PHAssetResource.assetResources(for: $0).first?.originalFilename ?? "?"
            }
            print("DIAG_NO_MATCH_FOR: \(Self.filenameFilter)")
            print("DIAG_AVAILABLE: \(names)")
            throw XCTSkip("no clip matching \(Self.filenameFilter)")
        }

        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
        print("DIAG_FILE: \(filename)")
        print("DIAG_PHASSET_PIXELS: \(asset.pixelWidth)x\(asset.pixelHeight)")
        print("DIAG_PHASSET_DURATION: \(asset.duration)")

        let video = try await VideoFile.from(asset: asset)
        defer { try? FileManager.default.removeItem(at: video.url) }

        let source = AVURLAsset(url: video.url)
        let tracks = try await source.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = naturalSize.applying(transform)
        let formats = try await track.load(.formatDescriptions)

        print("DIAG_VIDEO_TRACK_COUNT: \(tracks.count)")
        print("DIAG_NATURAL_SIZE: \(naturalSize)")
        print("DIAG_TRANSFORM: a=\(transform.a) b=\(transform.b) c=\(transform.c) d=\(transform.d) tx=\(transform.tx) ty=\(transform.ty)")
        print("DIAG_DISPLAY_SIZE: \(abs(displayed.width))x\(abs(displayed.height))")
        for description in formats {
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let fourCC = String(format: "%c%c%c%c",
                                (subtype >> 24) & 255, (subtype >> 16) & 255,
                                (subtype >> 8) & 255, subtype & 255)
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
            print("DIAG_CODEC: \(fourCC) dimensions=\(dimensions.width)x\(dimensions.height)")
            // A non-square pixel aspect ratio or a clean aperture would make the encoded
            // dimensions differ from what is meant to be displayed — a plausible cause of
            // a picture that ends up stretched or cropped.
            print("DIAG_PIXEL_ASPECT: \(String(describing: extensions[kCVImageBufferPixelAspectRatioKey as String]))")
            print("DIAG_CLEAN_APERTURE: \(String(describing: extensions[kCVImageBufferCleanApertureKey as String]))")
        }

        // ── Editor path ──────────────────────────────────────────────────────
        let canvas = await EditorScreen.canvas(matching: video.url)
        print("DIAG_EDITOR_CANVAS: \(canvas.width)x\(canvas.height)")

        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
        let duration = try await source.load(.duration)
        _ = store.addVisualSegment(localURL: video.url, nativeDuration: CMTimeGetSeconds(duration))
        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true
        )
        print("DIAG_EDITOR_RENDER_SIZE: \(built.videoComposition.renderSize)")
        if let frame = try? Self.firstCompositionFrame(built) {
            print("DIAG_EDITOR_FRAME: \(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))")
        } else {
            print("DIAG_EDITOR_FRAME: <none>")
        }

        // ── Compression path ─────────────────────────────────────────────────
        let compressor = VideoCompressor()
        let outputURL = try await compressor.compress(
            inputURL: video.url,
            preset: .small,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)
        let outTrack = try XCTUnwrap(outTracks.first)
        let outNatural = try await outTrack.load(.naturalSize)
        let outTransform = try await outTrack.load(.preferredTransform)
        let outDisplayed = outNatural.applying(outTransform)
        print("DIAG_OUT_NATURAL_SIZE: \(outNatural)")
        print("DIAG_OUT_TRANSFORM: a=\(outTransform.a) b=\(outTransform.b) c=\(outTransform.c) d=\(outTransform.d) tx=\(outTransform.tx) ty=\(outTransform.ty)")
        print("DIAG_OUT_DISPLAY_SIZE: \(abs(outDisplayed.width))x\(abs(outDisplayed.height))")

        // The one thing that must hold either way: shape is preserved.
        let sourceIsPortrait = abs(displayed.height) > abs(displayed.width)
        let outputIsPortrait = abs(outDisplayed.height) > abs(outDisplayed.width)
        XCTAssertEqual(sourceIsPortrait, outputIsPortrait,
                       "compression changed the clip's orientation")
    }

    /// Same reader the compressor uses, so this sees what the encoder would see.
    private static func firstCompositionFrame(_ built: CompositionResult) throws -> CVPixelBuffer? {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var buffer: CVPixelBuffer?
        for _ in 0..<10 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            buffer = CMSampleBufferGetImageBuffer(sample)
        }
        return buffer
    }
}
