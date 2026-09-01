import Foundation
import AVFoundation

/// Everything the user can decide about how a clip is encoded.
///
/// Gathered into one value rather than added as more arguments to `compress` because the
/// choices interact: a resolution cap changes what bitrate is sensible, a frame-rate cap
/// changes it again, and a target file size overrides the bitrate entirely. Estimating the
/// result means reproducing exactly that arithmetic, so it lives beside the settings
/// instead of being duplicated in the UI.
struct CompressionSettings: Equatable {

    /// How the video bitrate is chosen.
    enum Quality: Equatable {
        /// One of the three presets — a ceiling, still capped at 85% of the source.
        case preset(CompressionPreset)
        /// Aim for a finished file of about this many megabytes.
        case targetSize(megabytes: Double)
    }

    /// Longest edge the output may have. Footage is never upscaled.
    enum Resolution: String, CaseIterable, Identifiable {
        case p720 = "720p"
        case p1080 = "1080p"
        case original = "維持原始"

        var id: String { rawValue }

        /// Long edge / short edge caps. `original` still has a ceiling because this app's
        /// purpose is shrinking files, and 4K output would defeat that.
        var limits: (longEdge: CGFloat, shortEdge: CGFloat) {
            switch self {
            case .p720:     return (1280, 720)
            case .p1080:    return (1920, 1080)
            case .original: return (3840, 2160)
            }
        }
    }

    /// Cap on frames per second. Halving the rate of action-camera footage is one of the
    /// few changes that reduces size substantially without touching resolution.
    enum FrameRateCap: String, CaseIterable, Identifiable {
        case original = "維持原始"
        case fps30 = "30 fps"
        case fps24 = "24 fps"

        var id: String { rawValue }

        var value: Double? {
            switch self {
            case .original: return nil
            case .fps30:    return 30
            case .fps24:    return 24
            }
        }
    }

    var quality: Quality = .preset(.medium)
    var resolution: Resolution = .p1080
    var frameRateCap: FrameRateCap = .original
    /// Off drops the audio track entirely — action footage is often just wind noise, and
    /// the track still costs space.
    var includeAudio: Bool = true

    static let `default` = CompressionSettings()

    /// Bits per second allotted to audio when it is kept. Matches the encoder settings.
    static let audioBitrate = 96_000

    /// The video bitrate these settings ask for, before the source-relative cap.
    ///
    /// A target size is spread over the clip's duration, with room left for the audio
    /// track — otherwise a size-limited file overshoots by exactly the audio.
    func requestedVideoBitrate(durationSeconds: Double) -> Int {
        switch quality {
        case .preset(let preset):
            return preset.bitrate
        case .targetSize(let megabytes):
            guard durationSeconds > 0 else { return CompressionPreset.medium.bitrate }
            let totalBits = megabytes * 1_048_576 * 8
            let audioBits = includeAudio ? Double(Self.audioBitrate) * durationSeconds : 0
            let videoBits = max(totalBits - audioBits, 0)
            return max(Int(videoBits / durationSeconds), 200_000)
        }
    }
}

/// Predicts the finished size, so a preset can be chosen knowingly rather than by
/// compressing and looking.
///
/// Deliberately shares `targetBitrate` with the encoder: an estimate derived from
/// different arithmetic than the encoder uses would drift away from reality as either side
/// changed, and a confidently wrong number is worse than none.
enum CompressionEstimator {

    struct Estimate {
        let bytes: Int64
        /// True when the source's own bitrate, not the chosen setting, is what limits the
        /// result — worth saying, because raising the quality setting then changes nothing.
        let limitedBySource: Bool
    }

    static func estimate(
        settings: CompressionSettings,
        durationSeconds: Double,
        sourceBitrate: Double
    ) -> Estimate? {
        guard durationSeconds > 0 else { return nil }

        let requested = Double(settings.requestedVideoBitrate(durationSeconds: durationSeconds))
        let effective = VideoCompressor.targetBitrate(
            requestedBitrate: Int(requested),
            estimatedSourceBitrate: Float(sourceBitrate)
        )

        let audioBits = settings.includeAudio
            ? Double(CompressionSettings.audioBitrate) * durationSeconds
            : 0
        let bytes = (Double(effective) * durationSeconds + audioBits) / 8

        return Estimate(
            bytes: Int64(bytes),
            limitedBySource: sourceBitrate > 0 && Double(effective) < requested - 1
        )
    }

    static func describe(_ estimate: Estimate) -> String {
        let size = ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)
        return estimate.limitedBySource ? "約 \(size)（受原始畫質限制）" : "約 \(size)"
    }
}
