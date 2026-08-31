#if canImport(AVFoundation)
import AVFoundation
import VideoToolbox
import TimelineKitCore

/// V5 render-pipeline-unification-spec §6：档位 → 编码参数映射表。
///
/// 集中维护：码率（基线 + 帧率倍率）、编码器（H.264 / HEVC / HEVC Main 10）。
/// 任何档位调整应**先改 docs/v2/export-pipeline-spec.md 附录 A**，再同步本表。
public enum ExportEncodingProfile {

    // MARK: - Bitrate (bits/sec)

    /// 基线码率（30fps）：分辨率 × 三档。
    /// 来源：competitive-benchmarks-v5.md §1.4 + render-pipeline-unification-spec §6.1。
    private static func baseBitrate(
        resolution: ExportConfig.Resolution,
        tier: ExportConfig.BitrateTier
    ) -> Int {
        switch (resolution, tier) {
        case (.p480,  .low):         return 1_000_000
        case (.p480,  .recommended): return 2_500_000
        case (.p480,  .high):        return 4_000_000
        case (.p720,  .low):         return 2_500_000
        case (.p720,  .recommended): return 5_000_000
        case (.p720,  .high):        return 8_000_000
        case (.p1080, .low):         return 5_000_000
        case (.p1080, .recommended): return 8_000_000
        case (.p1080, .high):        return 12_000_000
        case (.k2,    .low):         return 10_000_000
        case (.k2,    .recommended): return 16_000_000
        case (.k2,    .high):        return 24_000_000
        case (.k4,    .low):         return 20_000_000
        case (.k4,    .recommended): return 35_000_000
        case (.k4,    .high):        return 50_000_000
        }
    }

    /// 帧率倍率：24/25/30 = 1.0x；50/60 = 1.2x；120 = 1.5x。
    private static func fpsMultiplier(_ fps: ExportConfig.FrameRate) -> Double {
        switch fps {
        case .fps24, .fps25, .fps30: return 1.0
        case .fps50, .fps60:         return 1.2
        case .fps120:                return 1.5
        }
    }

    /// 实际码率 = 基线 × 帧率倍率。
    public static func bitrate(for config: ExportConfig) -> Int {
        let base = Double(baseBitrate(resolution: config.resolution, tier: config.bitrateTier))
        return Int(base * fpsMultiplier(config.fps))
    }

    // MARK: - Codec

    /// LOCAL PATCH (see VENDORED.md #1). Upstream used H.264 for 1080p and below for
    /// maximum compatibility. This app always targets HEVC: at equal quality it is
    /// roughly half the size of H.264, and small files are the entire point here. Every
    /// device this ships to is iOS 18+, so HEVC playback support is a given.
    public static func codec(for config: ExportConfig) -> AVVideoCodecType {
        return .hevc
    }

    // MARK: - Color properties

    /// V5 §4.2 表格：SDR = Rec.709；HDR = BT.2020 PQ。
    public static func colorProperties(for config: ExportConfig) -> [String: Any] {
        if config.hdrEnabled {
            return [
                AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        return [
            AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    // MARK: - Video settings (for AVAssetWriterInput)

    /// 构造 `AVAssetWriterInput(mediaType: .video, outputSettings:)` 所需的字典。
    /// 调用方需保证 `config` 已被 `downgradeIfNeeded` 检查过（设备不支持 HDR 时降级为 SDR）。
    ///
    /// `renderSize`：实际的像素尺寸。`config.resolution.size` 始终是 16:9 横屏参考值，
    /// 无法表达竖屏；导出时调用方应传入 `videoComposition.renderSize`（已按 canvas 方向缩放）。
    /// nil 时回退到 `config.resolution.size`（仅用于 HDR 探测等不需要方向的场景）。
    /// LOCAL PATCH (see VENDORED.md #1). Upstream sets only `AVVideoAverageBitRateKey`,
    /// which VideoToolbox treats as a *soft* target it may overshoot on complex footage,
    /// and picks H.264 for 1080p and below. Both work against this app's whole purpose —
    /// shrinking clips before they go to an Immich server — and the missing hard cap is
    /// the same defect that previously produced files larger than the source.
    ///
    /// `sourceBitrateHint`: the source's own measured bitrate. The ceiling is capped at
    /// 85% of it so an already-efficient clip is never re-encoded *upward*.
    public static func videoOutputSettings(
        for config: ExportConfig,
        renderSize: CGSize? = nil,
        sourceBitrateHint: Float? = nil
    ) -> [String: Any] {
        let size = renderSize ?? config.resolution.size

        let targetBitrate = cappedBitrate(for: config, sourceBitrateHint: sourceBitrateHint)
        // Hard ceiling. AverageBitRate alone is advisory; DataRateLimits is what the
        // encoder must not exceed. 1.1x over one second leaves room for normal variation
        // without letting a busy scene balloon the file.
        let bytesPerSecondCap = Int(Double(targetBitrate) / 8.0 * 1.1)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey:           targetBitrate,
            kVTCompressionPropertyKey_DataRateLimits as String: [bytesPerSecondCap, 1],
            AVVideoExpectedSourceFrameRateKey:  config.fps.value,
            AVVideoMaxKeyFrameIntervalKey:      Int(config.fps.value * 2)   // GOP = 2 秒
        ]

        if config.hdrEnabled {
            compression[AVVideoProfileLevelKey]      = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            compression[AVVideoColorPrimariesKey]    = AVVideoColorPrimaries_ITU_R_2020
            compression[AVVideoTransferFunctionKey]  = AVVideoTransferFunction_SMPTE_ST_2084_PQ
            compression[AVVideoYCbCrMatrixKey]       = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            compression[AVVideoProfileLevelKey]      = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        let settings: [String: Any] = [
            AVVideoCodecKey:                 codec(for: config),
            AVVideoWidthKey:                 Int(size.width),
            AVVideoHeightKey:                Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey:       colorProperties(for: config)
        ]

        return settings
    }

    /// LOCAL PATCH (see VENDORED.md #1). Duration-weighted source bitrate across the
    /// composition's video tracks, used as the ceiling input.
    ///
    /// Weighted by duration rather than taking the max so that one short high-bitrate
    /// clip cannot raise the ceiling for a long, already-efficient timeline. Returns nil
    /// when nothing usable is reported, in which case the tier bitrate applies unchanged.
    public static func sourceBitrateHint(for asset: AVAsset) -> Float? {
        let tracks = asset.tracks(withMediaType: .video)
        guard !tracks.isEmpty else { return nil }

        var weightedSum: Double = 0
        var totalSeconds: Double = 0
        for track in tracks {
            let rate = Double(track.estimatedDataRate)
            let seconds = CMTimeGetSeconds(track.timeRange.duration)
            guard rate > 0, seconds > 0, seconds.isFinite else { continue }
            weightedSum += rate * seconds
            totalSeconds += seconds
        }
        guard totalSeconds > 0, weightedSum > 0 else { return nil }
        return Float(weightedSum / totalSeconds)
    }

    /// LOCAL PATCH (see VENDORED.md #1). Never encode above what the source itself needs.
    public static func cappedBitrate(for config: ExportConfig, sourceBitrateHint: Float?) -> Int {
        let tierBitrate = bitrate(for: config)
        guard let hint = sourceBitrateHint, hint > 0 else { return tierBitrate }
        let sourceCeiling = Int(hint * 0.85)
        let minimumBitrate = 500_000
        return max(min(tierBitrate, sourceCeiling), minimumBitrate)
    }

    // MARK: - Audio settings (fixed, AAC LC 128k)

    /// V4 沿用：AAC LC 128 kbps 44.1 kHz 立体声。
    public static func audioOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey:       44_100,
            AVEncoderBitRateKey:   128_000
        ]
    }

    // MARK: - HDR capability probe

    /// dry-run：尝试构造 HDR 编码器，检测设备/系统是否支持。
    /// 用于 M4 阶段 ExportConfigSheet 的 HDR Toggle 启用条件，
    /// 以及 VideoExporter.downgradeIfNeeded 的实时降级判断。
    static public func canEncodeHDR() -> Bool {
        let hdrConfig = ExportConfig(
            resolution: .p1080, fps: .fps30, bitrateTier: .recommended, hdrEnabled: true
        )
        let settings = videoOutputSettings(for: hdrConfig)
        let tempInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr_probe_\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else {
            return false
        }
        return writer.canAdd(tempInput)
    }
}
#endif
