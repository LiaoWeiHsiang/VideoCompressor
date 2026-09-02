import XCTest
import AVFoundation
import CoreImage
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Whether colour adjustments and preset filters actually reach the pixels.
///
/// Reported as "調節裡面的濾鏡沒有用，調整了不會變". Reading the code, all three render
/// paths apply them — so the question is which of them the app is actually looking at, and
/// that is only answerable by rendering and comparing.
final class AdjustmentRenderTests: XCTestCase {

    /// Average colour of a rendered frame, as three channels.
    private func averageColour(_ buffer: CVPixelBuffer) -> (r: Int, g: Int, b: Int)? {
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

        var totals = (r: 0, g: 0, b: 0)
        let step = max(1, (width * height) / 4000)
        var samples = 0
        for pixel in stride(from: 0, to: width * height, by: step) {
            let i = pixel * 4
            totals.r += Int(pixels[i]); totals.g += Int(pixels[i + 1]); totals.b += Int(pixels[i + 2])
            samples += 1
        }
        guard samples > 0 else { return nil }
        return (totals.r / samples, totals.g / samples, totals.b / samples)
    }

    private func firstFrame(_ built: CompositionResult) throws -> CVPixelBuffer? {
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
        for _ in 0..<12 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            buffer = CMSampleBufferGetImageBuffer(sample)
        }
        return buffer
    }

    @MainActor
    private func makeStore(_ url: URL) async throws -> EditorStore {
        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: url))
        )
        let duration = try await AVURLAsset(url: url).load(.duration)
        _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))
        return store
    }

    /// Brightness is the simplest adjustment: if this does not move the pixels, none of
    /// the others can either.
    @MainActor
    func testBrightnessChangesTheRenderedPixels() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2, size: CGSize(width: 640, height: 480), pattern: .quadrants
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let store = try await makeStore(source)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)

        let plain = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let before = try XCTUnwrap(averageColour(try XCTUnwrap(firstFrame(plain))))

        var adjustment = SegmentAdjustment()
        adjustment.brightness = 0.45
        store.setAdjustment(segmentID: segment.id, adjustment: adjustment)

        let adjusted = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let after = try XCTUnwrap(averageColour(try XCTUnwrap(firstFrame(adjusted))))

        print("ADJUST_BRIGHTNESS before=\(before) after=\(after)")
        let delta = abs(after.r - before.r) + abs(after.g - before.g) + abs(after.b - before.b)
        XCTAssertGreaterThan(delta, 30, "brightness did not reach the rendered pixels")
    }

    /// A preset filter is the thing that was reported as doing nothing.
    @MainActor
    func testPresetFilterChangesTheRenderedPixels() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2, size: CGSize(width: 640, height: 480), pattern: .quadrants
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let store = try await makeStore(source)
        let segment = try XCTUnwrap(store.timeline.mainTrack?.segments.first)

        let plain = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let before = try XCTUnwrap(averageColour(try XCTUnwrap(firstFrame(plain))))

        // Mono is unambiguous: the coloured quadrants must collapse towards grey.
        var adjustment = SegmentAdjustment()
        adjustment.filterName = .cinemaMono
        adjustment.filterIntensity = 1.0
        store.setAdjustment(segmentID: segment.id, adjustment: adjustment)

        let filtered = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let after = try XCTUnwrap(averageColour(try XCTUnwrap(firstFrame(filtered))))

        print("ADJUST_FILTER before=\(before) after=\(after)")
        let spreadBefore = max(before.r, before.g, before.b) - min(before.r, before.g, before.b)
        let spreadAfter = max(after.r, after.g, after.b) - min(after.r, after.g, after.b)
        print("ADJUST_FILTER spread before=\(spreadBefore) after=\(spreadAfter)")
        XCTAssertLessThan(spreadAfter, spreadBefore,
                          "a mono filter did not desaturate the picture")
    }

    /// The preview uses a different renderer than export. It has to apply adjustments too,
    /// or the picture only changes once the file is written — which is what "調整了不會變"
    /// would look like.
    @MainActor
    func testPreviewRendererAppliesAdjustments() async throws {
        let source = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 2, size: CGSize(width: 640, height: 480), pattern: .quadrants
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let renderSize = CGSize(width: 640, height: 480)
        let provider = PreviewFrameProvider()
        provider.setCanvasSize(renderSize)
        let previous = VideoLayerComposer.frameProvider
        VideoLayerComposer.frameProvider = provider
        defer {
            VideoLayerComposer.frameProvider = previous
            provider.invalidate()
        }

        func render(_ adjustment: SegmentAdjustment) async throws -> (r: Int, g: Int, b: Int) {
            var spec = VideoLayerSpec(
                assetURL: source,
                renderSize: renderSize,
                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
            )
            spec.adjustment = adjustment
            let at = CMTime(seconds: 1, preferredTimescale: 600)
            provider.preload(videoSpecs: [spec])
            provider.seek(to: at, activeSpecs: [spec], playbackActive: false)

            var produced: CIImage?
            for _ in 0..<120 {
                if let image = VideoLayerComposer.evaluate(spec: spec, at: at) { produced = image; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let image = try XCTUnwrap(produced, "preview produced no frame")
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(renderSize.width), Int(renderSize.height),
                                kCVPixelFormatType_32BGRA, nil, &buffer)
            let target = try XCTUnwrap(buffer)
            CIContext().render(image, to: target)
            return try XCTUnwrap(averageColour(target))
        }

        let before = try await render(.identity)
        var adjustment = SegmentAdjustment()
        adjustment.brightness = 0.45
        let after = try await render(adjustment)

        print("PREVIEW_ADJUST before=\(before) after=\(after)")
        let delta = abs(after.r - before.r) + abs(after.g - before.g) + abs(after.b - before.b)
        XCTAssertGreaterThan(delta, 30, "the preview renderer ignores adjustments")
    }
}
