import XCTest
import AVFoundation
import CoreGraphics
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// The editor canvas decides the shape of everything downstream — the preview, and the
/// render size the finished video is encoded at. Getting it wrong does not fail, it just
/// letterboxes the footage into black bars, so it needs asserting rather than eyeballing.
final class EditorCanvasTests: XCTestCase {

    /// The rotation a phone actually records for portrait footage: a 90° turn *plus* the
    /// translation that brings the frame back into the positive quadrant. A bare
    /// `CGAffineTransform(rotationAngle:)` has no translation, so the picture lands
    /// entirely off-canvas — a fixture that tests nothing but black.
    static func portraitTransform(storedSize: CGSize) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: storedSize.height, ty: 0)
    }

    /// Phone portrait footage is *stored* landscape with a 90° rotation in
    /// `preferredTransform`. Reading `naturalSize` alone therefore reports it as landscape,
    /// which is exactly how a portrait clip ends up pillarboxed in the editor.
    @MainActor
    func testRotatedPortraitFootageGetsAPortraitCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1920, height: 1080),          // stored landscape
            preferredTransform: Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080))
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // Confirm the fixture really is the tricky case, not an already-portrait file.
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let naturalSize = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertGreaterThan(naturalSize.width, naturalSize.height,
                             "fixture should be stored landscape for this test to mean anything")

        let canvas = await EditorScreen.canvas(matching: url)
        print("PORTRAIT_CANVAS: \(canvas.width)x\(canvas.height)")
        XCTAssertLessThan(canvas.width, canvas.height, "rotated portrait clip got a landscape canvas")
    }

    @MainActor
    func testLandscapeFootageGetsALandscapeCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1920, height: 1080)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        print("LANDSCAPE_CANVAS: \(canvas.width)x\(canvas.height)")
        XCTAssertGreaterThan(canvas.width, canvas.height)
    }

    /// Portrait footage stored portrait, with no rotation to interpret.
    @MainActor
    func testNativelyPortraitFootageGetsAPortraitCanvas() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 1,
            size: CGSize(width: 1080, height: 1920)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        XCTAssertLessThan(canvas.width, canvas.height)
    }

    /// The canvas has to carry through to the encoded file, not just the preview: a
    /// portrait edit must come out portrait at 1080 across, not 1080 tall.
    @MainActor
    func testPortraitEditIsEncodedPortraitAt1080() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2,
            size: CGSize(width: 1920, height: 1080),
            preferredTransform: Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080))
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = await EditorScreen.canvas(matching: url)
        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
        let duration = try await AVURLAsset(url: url).load(.duration)
        _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true,
            renderSize: CGSize(
                width: EditorScreen.exportShortSide * 16 / 9,
                height: EditorScreen.exportShortSide
            )
        )
        let renderSize = built.videoComposition.renderSize
        print("PORTRAIT_RENDER_SIZE: \(renderSize)")
        XCTAssertLessThan(renderSize.width, renderSize.height, "portrait edit rendered landscape")
        XCTAssertEqual(renderSize.width, 1080, accuracy: 2, "portrait output should be 1080 across")
    }

    /// A portrait render size proves nothing about the picture inside it — a badly composed
    /// transform yields a portrait frame containing a rotated, cropped image, which is
    /// exactly the reported symptom (a middle slice, turned 90°). Compare what the
    /// composition draws against what the source itself looks like.
    @MainActor
    func testPortraitClipIsNotRotatedOrCroppedByTheEditor() async throws {
        for (label, size, transform) in [
            ("stored-portrait", CGSize(width: 1080, height: 1920), CGAffineTransform.identity),
            ("rotated-portrait", CGSize(width: 1920, height: 1080),
             Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080)))
        ] {
            let url = try await AudioVideoFactory.makeVideoWithAudio(
                seconds: 2, size: size, preferredTransform: transform, pattern: .quadrants
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let sourceFrameOrNil = try await Self.firstSourceFrame(url)
            let sourceFrame = try XCTUnwrap(sourceFrameOrNil)
            let sourceQuadrants = try XCTUnwrap(Self.quadrants(of: sourceFrame))
            print("\(label) SOURCE: \(sourceQuadrants)")

            let canvas = await EditorScreen.canvas(matching: url)
            let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
            let duration = try await AVURLAsset(url: url).load(.duration)
            _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))

            let built = try await CompositionBuilder().build(
                from: store.timeline,
                renderSubtitles: true,
                renderSize: CGSize(
                    width: EditorScreen.exportShortSide * 16 / 9,
                    height: EditorScreen.exportShortSide
                )
            )
            let renderedFrame = try XCTUnwrap(Self.firstCompositionFrame(built))
            let renderedQuadrants = try XCTUnwrap(Self.quadrants(of: renderedFrame))
            print("\(label) RENDERED: \(renderedQuadrants) size=\(CVPixelBufferGetWidth(renderedFrame))x\(CVPixelBufferGetHeight(renderedFrame))")

            XCTAssertEqual(
                renderedQuadrants, sourceQuadrants,
                "\(label): the editor rearranged the picture — rotated or cropped"
            )
        }
    }

    /// The same check for the plain compress path, which never touches the editor: a clip
    /// queued and compressed directly must come out looking exactly as it went in.
    @MainActor
    func testPortraitClipIsNotRotatedOrCroppedByCompression() async throws {
        for (label, size, transform) in [
            ("stored-portrait", CGSize(width: 1080, height: 1920), CGAffineTransform.identity),
            ("rotated-portrait", CGSize(width: 1920, height: 1080),
             Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080)))
        ] {
            let url = try await AudioVideoFactory.makeVideoWithAudio(
                seconds: 2, size: size, preferredTransform: transform, pattern: .quadrants
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let sourceFrameOrNil = try await Self.firstSourceFrame(url)
            let sourceQuadrants = try XCTUnwrap(Self.quadrants(of: try XCTUnwrap(sourceFrameOrNil)))

            let compressor = VideoCompressor()
            let outputURL = try await compressor.compress(inputURL: url, preset: .small)
            defer { try? FileManager.default.removeItem(at: outputURL) }

            // Read the output the way a player would, rotation flag applied.
            let outputFrameOrNil = try await Self.firstSourceFrame(outputURL)
            let outputFrame = try XCTUnwrap(outputFrameOrNil)
            let outputQuadrants = try XCTUnwrap(Self.quadrants(of: outputFrame))
            print("\(label) COMPRESSED: \(outputQuadrants) displayed=\(CVPixelBufferGetWidth(outputFrame))x\(CVPixelBufferGetHeight(outputFrame))")

            XCTAssertEqual(
                outputQuadrants, sourceQuadrants,
                "\(label): compression rearranged the picture — rotated or cropped"
            )
            XCTAssertLessThan(
                CVPixelBufferGetWidth(outputFrame), CVPixelBufferGetHeight(outputFrame),
                "\(label): a portrait clip compressed to a landscape-looking file"
            )
        }
    }
}

// MARK: - Pixel-level orientation checks

/// Reads what a composition actually renders, rather than trusting its declared size.
///
/// `renderSize` being portrait says nothing about whether the picture inside it is
/// upright: a wrongly composed transform produces a portrait file containing a rotated,
/// cropped image. Only the pixels settle it.
extension EditorCanvasTests {

    /// One flat colour sampled from the middle of each quadrant, clockwise from top-left.
    struct Quadrants: Equatable, CustomStringConvertible {
        let topLeft: String, topRight: String, bottomLeft: String, bottomRight: String
        var description: String { "TL=\(topLeft) TR=\(topRight) BL=\(bottomLeft) BR=\(bottomRight)" }
    }

    /// Names the dominant channel, so JPEG-ish codec noise cannot flip a comparison.
    private static func name(r: UInt8, g: UInt8, b: UInt8) -> String {
        let high: (UInt8) -> Bool = { $0 > 140 }
        switch (high(r), high(g), high(b)) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, false):  return "yellow"
        default:                   return "other(\(r),\(g),\(b))"
        }
    }

    static func quadrants(of buffer: CVPixelBuffer) -> Quadrants? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }

        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func sample(_ fx: Double, _ fy: Double) -> String {
            let x = min(width - 1, max(0, Int(Double(width) * fx)))
            let y = min(height - 1, max(0, Int(Double(height) * fy)))
            let i = (y * width + x) * 4
            return name(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
        }
        // Row 0 of a CGContext bitmap is the top edge.
        return Quadrants(
            topLeft:     sample(0.25, 0.25),
            topRight:    sample(0.75, 0.25),
            bottomLeft:  sample(0.25, 0.75),
            bottomRight: sample(0.75, 0.75)
        )
    }

    /// First frame as the source file itself presents it.
    static func firstSourceFrame(_ url: URL) async throws -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Honour the rotation flag, so this is what a player would show.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let cgImage = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, cgImage.width, cgImage.height,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return buffer
    }

    /// First frame the composition renders, read exactly the way the compressor reads it.
    static func firstCompositionFrame(_ built: CompositionResult) throws -> CVPixelBuffer? {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Skip the very first frames; a transition or fade-in can start from black.
        var buffer: CVPixelBuffer?
        for _ in 0..<20 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            buffer = CMSampleBufferGetImageBuffer(sample)
        }
        reader.cancelReading()
        return buffer
    }
}

// MARK: - The two paths that render frames themselves

/// Export without effects composes through AVFoundation layer instructions, which apply
/// the source's `preferredTransform`. The live preview and the effects path both build
/// their own frames instead, and each has to apply that rotation itself.
extension EditorCanvasTests {

    /// The effects path: any adjustment, transition or animation switches rendering to
    /// `UnifiedCompositor`, which takes raw track frames rather than transformed ones.
    @MainActor
    func testPortraitClipSurvivesTheEffectsRenderPath() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2,
            size: CGSize(width: 1920, height: 1080),
            preferredTransform: Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080)),
            pattern: .quadrants
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceFrameOrNil = try await Self.firstSourceFrame(url)
        let expected = try XCTUnwrap(Self.quadrants(of: try XCTUnwrap(sourceFrameOrNil)))
        print("EFFECTS_PATH SOURCE: \(expected)")

        let canvas = await EditorScreen.canvas(matching: url)
        let store = EditorStore(timeline: EditorTimeline(canvas: canvas))
        let duration = try await AVURLAsset(url: url).load(.duration)
        _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))

        // A brightness nudge is enough to force the unified compositor; keep it small so
        // the quadrant colours still classify the same way.
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)
        var adjustment = SegmentAdjustment()
        adjustment.brightness = 0.02
        store.setAdjustment(segmentID: segment.id, adjustment: adjustment)

        let built = try await CompositionBuilder().build(
            from: store.timeline,
            renderSubtitles: true,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertNotNil(built.videoComposition.customVideoCompositorClass,
                        "test needs the unified compositor path")

        let frame = try XCTUnwrap(Self.firstCompositionFrame(built))
        let rendered = try XCTUnwrap(Self.quadrants(of: frame))
        print("EFFECTS_PATH RENDERED: \(rendered) size=\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))")

        XCTAssertEqual(rendered, expected,
                       "the effects render path ignored the clip's rotation")
    }

    /// The live preview path: `VideoLayerComposer` pulls frames from `VideoFrameProvider`
    /// and fits them to the canvas itself. This is what the editor actually shows.
    @MainActor
    func testPortraitClipSurvivesThePreviewRenderPath() async throws {
        let url = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2,
            size: CGSize(width: 1920, height: 1080),
            preferredTransform: Self.portraitTransform(storedSize: CGSize(width: 1920, height: 1080)),
            pattern: .quadrants
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceFrameOrNil = try await Self.firstSourceFrame(url)
        let expected = try XCTUnwrap(Self.quadrants(of: try XCTUnwrap(sourceFrameOrNil)))
        print("PREVIEW_PATH SOURCE: \(expected)")

        let renderSize = CGSize(width: 1080, height: 1920)
        let provider = ExportFrameProvider()
        provider.setCanvasSize(renderSize)
        let previousProvider = VideoLayerComposer.frameProvider
        VideoLayerComposer.frameProvider = provider
        defer { VideoLayerComposer.frameProvider = previousProvider }

        let spec = VideoLayerSpec(
            assetURL: url,
            renderSize: renderSize,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        )
        provider.preload(videoSpecs: [spec])

        let image = try XCTUnwrap(
            VideoLayerComposer.evaluate(spec: spec, at: CMTime(seconds: 1, preferredTimescale: 600)),
            "preview produced no frame"
        )
        let context = CIContext()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(renderSize.width), Int(renderSize.height),
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        let target = try XCTUnwrap(buffer)
        context.render(image, to: target)

        let rendered = try XCTUnwrap(Self.quadrants(of: target))
        print("PREVIEW_PATH RENDERED: \(rendered)")

        XCTAssertEqual(rendered, expected,
                       "the preview render path ignored the clip's rotation")
    }
}
