import XCTest
import AVFoundation
import CoreImage
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
@testable import VideoCompressor

/// Each transition effect must actually look different.
///
/// Reported as "轉場預覽效果全部都一樣". They were: the instruction carried only an opacity
/// ramp, so every preset in the grid rendered through `CIDissolveTransition` — a dozen
/// names for one cross-fade, in the preview and the exported file alike.
final class TransitionStyleTests: XCTestCase {

    /// A coarse fingerprint of a frame: average colour of a 3×3 grid. Two different
    /// effects at the same moment of the transition must not produce the same one.
    private func fingerprint(_ buffer: CVPixelBuffer) -> [Int]? {
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

        var result: [Int] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let x = width * (column * 2 + 1) / 6
                let y = height * (row * 2 + 1) / 6
                let i = (y * width + x) * 4
                // Quantised, so codec noise does not read as a difference.
                result.append(Int(pixels[i]) / 16)
                result.append(Int(pixels[i + 1]) / 16)
                result.append(Int(pixels[i + 2]) / 16)
            }
        }
        return result
    }

    /// Renders the middle of the transition, where the effects differ most.
    @MainActor
    private func midTransitionFrame(presetID: String) async throws -> [Int] {
        let a = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 3, size: CGSize(width: 640, height: 480), pattern: .quadrants)
        let b = try await AudioVideoFactory.makeVideoWithAudio(
            seconds: 3, size: CGSize(width: 640, height: 480))
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

        let store = EditorStore(
            timeline: EditorTimeline(canvas: await EditorScreen.canvas(matching: a))
        )
        for url in [a, b] {
            let duration = try await AVURLAsset(url: url).load(.duration)
            _ = store.addVisualSegment(localURL: url, nativeDuration: CMTimeGetSeconds(duration))
        }
        let segments = try XCTUnwrap(store.timeline.mainTrack?.segments)
            .sorted { $0.targetRange.start < $1.targetRange.start }
        XCTAssertNotNil(store.addTransition(between: segments[0].id, and: segments[1].id,
                                            presetID: presetID, duration: 1.0))

        let built = try await CompositionBuilder().build(from: store.timeline, renderSubtitles: true)
        let instructions = built.videoComposition.instructions
        XCTAssertEqual(instructions.count, 3, "\(presetID): expected a transition instruction")

        // Halfway through the middle instruction.
        let window = instructions[1].timeRange
        let mid = CMTimeGetSeconds(window.start) + CMTimeGetSeconds(window.duration) / 2

        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: mid, preferredTimescale: 600),
            duration: CMTime(seconds: 0.2, preferredTimescale: 600)
        )
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        guard reader.canAdd(output) else { throw XCTSkip("reader refused the composition") }
        reader.add(output)
        guard reader.startReading() else { throw XCTSkip("reader would not start") }
        defer { reader.cancelReading() }

        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "\(presetID): no frame at the join")
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        return try XCTUnwrap(fingerprint(buffer), "\(presetID): could not read the frame")
    }

    /// The whole point: the grid must offer genuinely different effects.
    @MainActor
    func testDifferentPresetsRenderDifferently() async throws {
        var seen: [String: [Int]] = [:]
        for presetID in ["crossFade", "fadeThroughBlack", "slideLeft", "pushRight", "wipeLeft"] {
            seen[presetID] = try await midTransitionFrame(presetID: presetID)
            print("STYLE_\(presetID): \(seen[presetID]!.prefix(9))")
        }

        let names = Array(seen.keys).sorted()
        var identicalPairs: [String] = []
        for i in 0..<names.count {
            for j in (i + 1)..<names.count where seen[names[i]] == seen[names[j]] {
                identicalPairs.append("\(names[i]) == \(names[j])")
            }
        }
        XCTAssertTrue(identicalPairs.isEmpty,
                      "these presets render identically: \(identicalPairs.joined(separator: ", "))")
    }

    /// Fading through black must actually reach black, which a cross-fade never does —
    /// the clearest way to tell the two apart.
    @MainActor
    func testFadeThroughBlackGoesDark() async throws {
        let fingerprint = try await midTransitionFrame(presetID: "fadeThroughBlack")
        let brightest = fingerprint.max() ?? 255
        print("STYLE_fadeThroughBlack brightest=\(brightest)")
        XCTAssertLessThan(brightest, 4, "the midpoint of a fade through black should be dark")
    }
}
