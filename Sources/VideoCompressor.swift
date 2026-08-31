import AVFoundation
import CoreImage
import VideoToolbox
import Foundation

enum CompressionError: LocalizedError {
    case assetLoadFailed
    case readerCreationFailed(String)
    case writerCreationFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .assetLoadFailed:
            return "無法載入所選影片，請確認已從 iCloud 下載完成"
        case .readerCreationFailed(let message):
            return "無法讀取來源影片：\(message)"
        case .writerCreationFailed(let message):
            return "無法建立輸出檔案：\(message)"
        case .exportFailed(let message):
            return "壓縮失敗：\(message)"
        }
    }
}

@MainActor
final class VideoCompressor: ObservableObject {
    @Published var progress: Double = 0
    @Published var isCompressing = false

    private static let maxLongEdge: CGFloat = 1920
    private static let maxShortEdge: CGFloat = 1080

    func compress(
        inputURL: URL,
        preset: CompressionPreset,
        timeRange: CMTimeRange? = nil,
        dateMode: DateMode = .original
    ) async throws -> URL {
        isCompressing = true
        progress = 0
        defer { isCompressing = false }

        let asset = AVURLAsset(url: inputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressionError.assetLoadFailed
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let estimatedSourceBitrate = try await videoTrack.load(.estimatedDataRate)
        let duration = try await asset.load(.duration)
        let effectiveTimeRange = timeRange ?? CMTimeRange(start: .zero, duration: duration)
        let trimmedDurationSeconds = CMTimeGetSeconds(effectiveTimeRange.duration)
        let sourceMetadata = (try? await asset.load(.metadata)) ?? []
        // Read via `.creationDate` rather than scanning `sourceMetadata`: that resolves the
        // movie header too, which is the only place some cameras record the shooting time.
        var sourceCreationDate: Date?
        if let creationItem = try? await asset.load(.creationDate) {
            sourceCreationDate = try? await creationItem.load(.dateValue)
        }

        let targetSize = Self.targetNaturalSize(naturalSize: naturalSize, transform: transform)
        let targetBitrate = Self.targetBitrate(preset: preset, estimatedSourceBitrate: estimatedSourceBitrate)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.readerCreationFailed(error.localizedDescription)
        }

        let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw CompressionError.readerCreationFailed("影片軌道不支援讀取")
        }
        reader.add(videoOutput)
        reader.timeRange = effectiveTimeRange

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let outputURL = Self.makeOutputURL(shotAt: sourceCreationDate)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw CompressionError.writerCreationFailed(error.localizedDescription)
        }
        // Preserve GPS location and other embedded metadata from the source so compressed
        // videos keep the same "where" info as the original. The creation date either
        // rides along too, or gets restamped to now, depending on the caller's choice.
        writer.metadata = Self.metadata(
            from: sourceMetadata,
            dateMode: dateMode,
            sourceCreationDate: sourceCreationDate
        )

        // AverageBitRate alone is a "soft" target the encoder may overshoot on complex
        // content; DataRateLimits is the hard cap that actually keeps the output small.
        let bytesPerSecondCap = Int(Double(targetBitrate) / 8.0 * 1.1)
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            kVTCompressionPropertyKey_DataRateLimits as String: [bytesPerSecondCap, 1],
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoExpectedSourceFrameRateKey: max(Int(nominalFrameRate.rounded()), 1)
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CompressionError.writerCreationFailed("不支援的影片設定")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height)
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw CompressionError.readerCreationFailed(reader.error?.localizedDescription ?? "未知錯誤")
        }
        guard writer.startWriting() else {
            throw CompressionError.writerCreationFailed(writer.error?.localizedDescription ?? "未知錯誤")
        }
        writer.startSession(atSourceTime: effectiveTimeRange.start)

        let needsScaling = targetSize.width != naturalSize.width || targetSize.height != naturalSize.height
        let ciContext = CIContext()

        do {
            try await Self.pumpSamples(
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                adaptor: adaptor,
                audioOutput: audioOutput,
                audioInput: audioInput,
                needsScaling: needsScaling,
                sourceSize: naturalSize,
                targetSize: targetSize,
                ciContext: ciContext,
                startOffsetSeconds: CMTimeGetSeconds(effectiveTimeRange.start),
                durationSeconds: trimmedDurationSeconds,
                onProgress: { [weak self] value in
                    Task { @MainActor in
                        self?.progress = value
                    }
                }
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        progress = 1
        return outputURL
    }

    /// Names the output after when the footage was *shot*, e.g. `202608152039_compressed`.
    ///
    /// Deliberately the original shooting time rather than the compression time, and
    /// deliberately independent of `DateMode`: the filename is what identifies the clip in
    /// a share sheet or on an Immich server, and "when was this filmed" is the useful
    /// thing to read there. Formatted in the device's local time zone, so the name matches
    /// the wall-clock time the user remembers.
    static func makeOutputFilename(shotAt: Date?, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // stable numeric output
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: shotAt ?? now) + "_compressed"
    }

    /// Resolves the filename to a free path. Clips shot within the same minute would
    /// otherwise collide and silently overwrite each other when a queue is processed.
    private static func makeOutputURL(shotAt: Date?) -> URL {
        let base = makeOutputFilename(shotAt: shotAt)
        let directory = FileManager.default.temporaryDirectory

        var candidate = directory.appendingPathComponent(base).appendingPathExtension("mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    /// Identifiers that carry a "when was this shot" timestamp. When restamping to the
    /// compression time we drop every one of them, otherwise a stale date left in a
    /// second identifier could win when the file is read back.
    private static let creationDateIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataCreationDate,
        .quickTimeUserDataCreationDate,
        .commonIdentifierCreationDate,
        .isoUserDataDate,
        .quickTimeMetadataYear
    ]

    /// Builds the output's metadata, always writing the creation date explicitly.
    ///
    /// Copying the source's metadata items is not sufficient. Some cameras — Insta360
    /// among them — record the shooting time only in the movie header (`mvhd`) and carry
    /// no creation-date metadata item at all. `AVAssetWriter` always stamps that header
    /// with the time of encoding, so an output built purely from copied items silently
    /// claims it was shot at compression time. Photos still looked right because the
    /// `PHAsset` date is set separately, but anything reading the file itself (an Immich
    /// server, exiftool) saw the wrong date.
    ///
    /// `sourceCreationDate` therefore comes from `AVAsset.creationDate`, which resolves
    /// the movie header as well as metadata items.
    static func metadata(
        from source: [AVMetadataItem],
        dateMode: DateMode,
        sourceCreationDate: Date?
    ) -> [AVMetadataItem] {
        let effectiveDate: Date?
        switch dateMode {
        case .original: effectiveDate = sourceCreationDate
        case .now:      effectiveDate = Date()
        }

        // Drop every inherited date item first, so a stale one can't win over ours.
        let withoutDates = source.filter { item in
            if let identifier = item.identifier, creationDateIdentifiers.contains(identifier) {
                return false
            }
            return item.commonKey != .commonKeyCreationDate
        }

        guard let effectiveDate else { return withoutDates }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamped = AVMutableMetadataItem()
        stamped.identifier = .quickTimeMetadataCreationDate
        stamped.value = formatter.string(from: effectiveDate) as NSString
        return withoutDates + [stamped]
    }

    private static func targetNaturalSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let displaySize = naturalSize.applying(transform)
        let displayWidth = abs(displaySize.width)
        let displayHeight = abs(displaySize.height)

        let longEdge = max(displayWidth, displayHeight)
        let shortEdge = min(displayWidth, displayHeight)
        let scale = min(1.0, min(maxLongEdge / longEdge, maxShortEdge / shortEdge))

        func evenify(_ value: CGFloat) -> CGFloat {
            let scaled = (value * scale).rounded(.down)
            return scaled.truncatingRemainder(dividingBy: 2) == 0 ? scaled : scaled - 1
        }

        return CGSize(width: evenify(naturalSize.width), height: evenify(naturalSize.height))
    }

    /// Never encode above what the source itself actually needs. AVAssetExportSession's
    /// built-in presets target a fixed bitrate regardless of the source, which is how a
    /// "compress to 720p" export can end up larger than an already-efficient HEVC
    /// original. Instead, cap the request at a fraction of the source's own bitrate so
    /// the output is always meaningfully smaller.
    private static func targetBitrate(preset: CompressionPreset, estimatedSourceBitrate: Float) -> Int {
        let minimumBitrate = 500_000
        guard estimatedSourceBitrate > 0 else { return preset.bitrate }
        let sourceBasedCeiling = Int(estimatedSourceBitrate * 0.85)
        return max(min(preset.bitrate, sourceBasedCeiling), minimumBitrate)
    }

    private static func pumpSamples(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        needsScaling: Bool,
        sourceSize: CGSize,
        targetSize: CGSize,
        ciContext: CIContext,
        startOffsetSeconds: Double,
        durationSeconds: Double,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let videoQueue = DispatchQueue(label: "videocompressor.video.encode")
            let audioQueue = DispatchQueue(label: "videocompressor.audio.encode")
            let group = DispatchGroup()
            let errorLock = NSLock()
            var writingError: Error?

            func fail(_ error: Error) {
                errorLock.lock()
                if writingError == nil { writingError = error }
                errorLock.unlock()
                reader.cancelReading()
            }

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if reader.status != .reading {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        if needsScaling {
                            guard let pool = adaptor.pixelBufferPool else {
                                fail(CompressionError.exportFailed("無法建立影像緩衝區"))
                                videoInput.markAsFinished()
                                group.leave()
                                return
                            }
                            var outBufferOut: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBufferOut)
                            guard let outBuffer = outBufferOut else { continue }

                            let scaleX = targetSize.width / sourceSize.width
                            let scaleY = targetSize.height / sourceSize.height
                            let scaledImage = CIImage(cvPixelBuffer: pixelBuffer)
                                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                            ciContext.render(scaledImage, to: outBuffer)
                            adaptor.append(outBuffer, withPresentationTime: presentationTime)
                        } else {
                            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                        }
                    }

                    if durationSeconds > 0 {
                        let fraction = (CMTimeGetSeconds(presentationTime) - startOffsetSeconds) / durationSeconds
                        onProgress(min(max(fraction, 0), 0.98))
                    }
                }
            }

            if let audioOutput, let audioInput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if reader.status != .reading {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if !audioInput.append(sampleBuffer) {
                            fail(CompressionError.exportFailed(writer.error?.localizedDescription ?? "音訊寫入失敗"))
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                if reader.status == .failed {
                    fail(CompressionError.exportFailed(reader.error?.localizedDescription ?? "讀取失敗"))
                }

                if let writingError {
                    writer.cancelWriting()
                    continuation.resume(throwing: writingError)
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CompressionError.exportFailed(writer.error?.localizedDescription ?? "寫入失敗"))
                    }
                }
            }
        }
    }
}
