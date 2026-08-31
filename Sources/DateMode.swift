import Foundation

/// Which timestamp the compressed copy should carry — both in the file's own embedded
/// metadata and on the Photos asset created when saving.
enum DateMode: String, CaseIterable, Identifiable {
    case original = "與原始影片相同"
    case now = "使用壓縮當下時間"

    var id: String { rawValue }
}
