import Foundation

enum CompressionPreset: String, CaseIterable, Identifiable {
    case high = "高畫質（最多 8 Mbps）"
    case medium = "平衡（最多 5 Mbps）"
    case small = "最小檔案（最多 2.5 Mbps）"

    var id: String { rawValue }

    /// Target average video bitrate in bits per second. Video is always capped at 1080p
    /// (never upscaled) and re-encoded as HEVC, which is far smaller than the H.264
    /// bitrates that iPhone footage is typically recorded at.
    var bitrate: Int {
        switch self {
        case .high: return 8_000_000
        case .medium: return 5_000_000
        case .small: return 2_500_000
        }
    }
}
