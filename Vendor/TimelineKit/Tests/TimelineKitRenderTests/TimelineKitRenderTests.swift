import XCTest
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import TimelineKitCore
import TimelineKitRender

/// macOS smoke tests for TimelineKitRender.
///
/// Verifies that the types previously gated behind `#if canImport(UIKit)`
/// (TimelineRenderer, TextLayerComposer, TimelineClock, ...) exist and function
/// on macOS — the whole point of the macOS support milestone.
@MainActor
final class TimelineKitRenderTests: XCTestCase {

    // MARK: - Helpers

    /// Writes a solid-color PNG to a temp file and returns its URL.
    private func makeTestImageURL(
        width: Int = 64,
        height: Int = 64,
        red: CGFloat = 0.9,
        green: CGFloat = 0.2,
        blue: CGFloat = 0.1
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "test", code: 1)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tlk_test_\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "test", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 3)
        }
        return url
    }

    /// A timeline with one image segment on the main track and one text segment
    /// on a text track — exercises ImageLayerComposer + TextLayerComposer.
    private func makeTimeline(imageURL: URL) -> EditorTimeline {
        let canvas = EditorCanvas(width: 64, height: 64, fps: 30)

        let imageAssetID = UUID()
        let imageSegmentID = UUID()
        let imageAsset = EditorAsset(
            id: imageAssetID,
            type: .image,
            localURL: imageURL,
            nativeDuration: nil,
            naturalWidth: 64,
            naturalHeight: 64
        )
        let imageSegment = EditorSegment(
            id: imageSegmentID,
            materialID: imageAssetID,
            sourceRange: nil,
            targetRange: TimeRange(start: 0, duration: 2),
            content: .image(SegmentContent.ImageContent())
        )
        let mainTrack = EditorTrack(
            id: UUID(),
            kind: .video,
            label: "main",
            zPosition: 0,
            segments: [imageSegment],
            isMainTrack: true
        )

        let textSegmentID = UUID()
        let textSegment = EditorSegment(
            id: textSegmentID,
            materialID: UUID(),
            sourceRange: nil,
            targetRange: TimeRange(start: 0, duration: 2),
            content: .text(SegmentContent.TextContent(
                text: "Hello macOS",
                style: TextStyle(fontSize: 16, color: "#FFFFFF")
            ))
        )
        let textTrack = EditorTrack(
            id: UUID(),
            kind: .text,
            label: "text",
            zPosition: 10,
            segments: [textSegment]
        )

        var materials = MaterialsPool()
        materials.add(imageAsset)

        return EditorTimeline(
            canvas: canvas,
            tracks: [mainTrack, textTrack],
            materials: materials
        )
    }

    /// Asserts a CVPixelBuffer is not entirely black (i.e. actually rendered).
    private func assertNotBlack(_ buffer: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            XCTFail("nil base address", file: file, line: line)
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var nonBlack = 0
        // Sample every 4th row/col to keep the test fast.
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let i = y * bytesPerRow + x * 4
                let b = ptr[i]
                let g = ptr[i + 1]
                let r = ptr[i + 2]
                if r > 40 || g > 40 || b > 40 { nonBlack += 1 }
            }
        }
        XCTAssertGreaterThan(nonBlack, 0, "frame is entirely black", file: file, line: line)
    }

    // MARK: - TimelineRenderer

    func testRendererRendersImageAndTextFrame() throws {
        let imageURL = try makeTestImageURL()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let timeline = makeTimeline(imageURL: imageURL)
        let renderer = TimelineRenderer()
        renderer.update(timeline: timeline, canvasSize: CGSize(width: 64, height: 64))

        guard let buffer = renderer.renderFrame(at: 0.5) else {
            XCTFail("renderFrame returned nil on macOS")
            return
        }
        assertNotBlack(buffer)
    }

    // MARK: - TimelineClock

    func testClockFiresOnTickAndStops() async {
        let clock = TimelineClock()
        let expectation = expectation(description: "onTick fires")

        var tickCount = 0
        clock.onTick = {
            tickCount += 1
            if tickCount >= 2 { expectation.fulfill() }
        }

        clock.start()
        await fulfillment(of: [expectation], timeout: 2.0)
        clock.stop()

        let countAfterStop = tickCount
        // Give the (now-invalidated) timer a moment — count must not grow.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(tickCount, countAfterStop, "onTick kept firing after stop()")
    }
}
