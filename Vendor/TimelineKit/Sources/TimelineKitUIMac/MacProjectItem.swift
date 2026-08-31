#if canImport(AppKit)
import AppKit
import TimelineKitUIShared

/// Browser 右栏"项目"分组里的单个项目行。
///
/// FCP 风格：左侧项目缩略图（当前用占位色块）+ 右侧项目名 / 创建时间 / 时长。
/// 点击该行切换活动项目（由宿主回调处理）。
@MainActor
final class MacProjectItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("MacProjectItem")

    private let thumbView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        container.layer?.cornerRadius = 4

        // 占位色块（项目缩略图暂用色块）。
        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        thumbView.layer?.cornerRadius = 4
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dateLabel)

        durationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 56),
            thumbView.heightAnchor.constraint(equalToConstant: 56),

            nameLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            dateLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
            dateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            durationLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
            durationLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 2),
            durationLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])
        self.view = container
    }

    func configure(project: LibraryProject, isSelected: Bool) {
        nameLabel.stringValue = project.name
        dateLabel.stringValue = Self.dateFormatter.string(from: project.createdAt)
        durationLabel.stringValue = Self.durationString(seconds: project.timeline.duration)
        // 选中态：亮色边框。
        self.view.layer?.borderWidth = isSelected ? 2 : 0
        self.view.layer?.borderColor = NSColor.systemYellow.cgColor
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    /// 时长（秒）→ `HH:mm:ss`（不足补零）。
    static func durationString(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

#endif
