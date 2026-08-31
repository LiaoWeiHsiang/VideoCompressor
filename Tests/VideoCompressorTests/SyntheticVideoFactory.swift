import AVFoundation
import CoreGraphics
import Foundation

enum SyntheticVideoFactory {
    static func makeVideo(
        seconds: Double = 12,
        size: CGSize = CGSize(width: 1280, height: 720),
        fps: Int32 = 30,
        bitrate: Int = 20_000_000,
        creationDate: Date? = nil,
        locationISO6709: String? = nil,
        includeAudio: Bool = false
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var metadataItems: [AVMetadataItem] = []
        if let creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter().string(from: creationDate) as NSString
            metadataItems.append(item)
        }
        if let locationISO6709 {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = locationISO6709 as NSString
            metadataItems.append(item)
        }
        writer.metadata = metadataItems
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourcePixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourcePixelAttributes)

        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 64_000
            ]
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            track.expectsMediaDataInRealTime = false
            if writer.canAdd(track) {
                writer.add(track)
                audioInput = track
            }
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(seconds * Double(fps))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw NSError(domain: "SyntheticVideoFactory", code: 1)
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else {
                throw NSError(domain: "SyntheticVideoFactory", code: 2)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            // Fill with a grid of randomly colored blocks, redrawn every frame. This gives
            // the frame real, changing detail (unlike a flat color, which any encoder
            // shrinks to almost nothing) without being pure per-pixel noise, which is an
            // unrealistic worst case that even hardware encoders can't rate-limit well.
            // Blocky "static" like this is a reasonable stand-in for busy real footage.
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                let blockSize: CGFloat = 48
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        let color = CGColor(
                            red: CGFloat.random(in: 0...1),
                            green: CGFloat.random(in: 0...1),
                            blue: CGFloat.random(in: 0...1),
                            alpha: 1
                        )
                        context.setFillColor(color)
                        context.fill(CGRect(x: x, y: y, width: blockSize, height: blockSize))
                        x += blockSize
                    }
                    y += blockSize
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        return url
    }
}
