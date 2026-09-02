import AVFoundation
import CoreGraphics
import Foundation

/// Makes a test movie that has a REAL audio track with actual samples.
///
/// The existing `SyntheticVideoFactory` adds an AAC track but never writes samples to
/// it, so its "audio" track is empty — reading it back fails, which makes it useless for
/// testing any audio path. This factory drives both inputs with
/// `requestMediaDataWhenReady`, the pattern AVAssetWriter actually expects, instead of
/// blocking a thread and writing all of one track before the other (which deadlocks).
enum AudioVideoFactory {

    /// What the frames depict. `quadrants` paints four flat corners so a test can tell
    /// whether anything downstream rotated, flipped or cropped the picture.
    enum Pattern {
        case noise
        case quadrants
        /// Each frame is a grey level encoding its own position in the clip, so a test can
        /// read back *which source frame* a composition is showing. That is the only way to
        /// tell a sped-up clip from a truncated one: both have the same duration.
        case timecode
    }


    static func makeVideoWithAudio(
        seconds: Double = 4,
        size: CGSize = CGSize(width: 640, height: 480),
        fps: Int32 = 30,
        sampleRate: Double = 44_100,
        toneHz: Double = 440,
        /// Rotation to record on the track, the way a phone marks portrait footage that is
        /// still *stored* landscape. `.identity` leaves the frames as written.
        preferredTransform: CGAffineTransform = .identity,
        pattern: Pattern = .noise
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ]
        )
        guard writer.canAdd(videoInput) else { throw Failure.cannotAddInput }
        writer.add(videoInput)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw Failure.cannotAddInput }
        writer.add(audioInput)

        guard writer.startWriting() else { throw Failure.startWritingFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(seconds * Double(fps))
        let format = try makeAudioFormat(sampleRate: sampleRate)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let lock = NSLock()
            var failure: Error?
            func fail(_ error: Error) {
                lock.lock(); if failure == nil { failure = error }; lock.unlock()
            }

            group.enter()
            var frameIndex = 0
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "factory.video")) {
                while videoInput.isReadyForMoreMediaData {
                    guard frameIndex < totalFrames else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    autoreleasepool {
                        if let buffer = makePixelBuffer(adaptor: adaptor, size: size, frameIndex: frameIndex, pattern: pattern, totalFramesHint: totalFrames) {
                            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: fps))
                        }
                    }
                    frameIndex += 1
                }
            }

            group.enter()
            let framesPerChunk = Int(sampleRate / 10)
            let totalAudioFrames = Int(seconds * sampleRate)
            var audioFrameOffset = 0
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "factory.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard audioFrameOffset < totalAudioFrames else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let count = min(framesPerChunk, totalAudioFrames - audioFrameOffset)
                    do {
                        let sample = try makeToneSample(
                            format: format,
                            frameOffset: audioFrameOffset,
                            frameCount: count,
                            sampleRate: sampleRate,
                            toneHz: toneHz
                        )
                        audioInput.append(sample)
                    } catch {
                        fail(error)
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioFrameOffset += count
                }
            }

            group.notify(queue: .global()) {
                if let failure {
                    writer.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: Failure.finishFailed(writer.error))
                    }
                }
            }
        }

        return url
    }

    // MARK: - Helpers

    enum Failure: Error {
        case cannotAddInput
        case startWritingFailed(Error?)
        case finishFailed(Error?)
        case audioFormatFailed
        case audioBufferFailed
    }

    private static func makeAudioFormat(sampleRate: Double) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw Failure.audioFormatFailed }
        return format
    }

    /// A real sine tone, not silence — silence can be optimised away and would not prove
    /// that audio actually survives the composition round-trip.
    private static func makeToneSample(
        format: CMAudioFormatDescription,
        frameOffset: Int,
        frameCount: Int,
        sampleRate: Double,
        toneHz: Double
    ) throws -> CMSampleBuffer {
        let byteCount = frameCount * 2
        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(frameOffset + i) / sampleRate
            samples[i] = Int16(sin(2 * .pi * toneHz * t) * 16_000)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { throw Failure.audioBufferFailed }

        try samples.withUnsafeBytes { raw in
            guard CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ) == noErr else { throw Failure.audioBufferFailed }
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameOffset), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [2],
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { throw Failure.audioBufferFailed }

        return sampleBuffer
    }

    private static func makePixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        size: CGSize,
        frameIndex: Int,
        pattern: Pattern,
        totalFramesHint: Int
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) {
            if pattern == .timecode {
                // Brightness ramps linearly with the frame index, so a rendered frame can
                // be decoded back to the source time it came from.
                let level = CGFloat(frameIndex) / CGFloat(max(totalFramesHint, 1))
                context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                return buffer
            }

            if pattern == .quadrants {
                // Four flat, saturated corners. Any rotation, flip or crop applied along
                // the way rearranges them, which random noise could never reveal.
                let w = size.width / 2, h = size.height / 2
                let corners: [(CGRect, CGColor)] = [
                    (CGRect(x: 0, y: 0, width: w, height: h), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                    (CGRect(x: w, y: 0, width: w, height: h), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
                    (CGRect(x: 0, y: h, width: w, height: h), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                    (CGRect(x: w, y: h, width: w, height: h), CGColor(red: 1, green: 1, blue: 0, alpha: 1))
                ]
                for (rect, color) in corners {
                    context.setFillColor(color)
                    context.fill(rect)
                }
                return buffer
            }

            let blockSize: CGFloat = 64
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.setFillColor(CGColor(
                        red: CGFloat.random(in: 0...1),
                        green: CGFloat.random(in: 0...1),
                        blue: CGFloat.random(in: 0...1),
                        alpha: 1
                    ))
                    context.fill(CGRect(x: x, y: y, width: blockSize, height: blockSize))
                    x += blockSize
                }
                y += blockSize
            }
        }
        return buffer
    }
}
