#if canImport(AppKit)
import AppKit

// MARK: - MacInspectorPanelView

/// Inspector panel placeholder (FCP style).
///
/// UI-structure milestone: shows the panel chrome + empty state only. The real
/// property form (driven by the selected segment) lands in a later iteration.
@MainActor
final class MacInspectorPanelView: NSView {

    private let titleLabel = NSTextField(labelWithString: "检查器")
    private let emptyLabel = NSTextField(labelWithString: "选择片段后显示属性\n位置 / 缩放 / 旋转 / 不透明度")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 与整体深色主题一致（时间线/预览 0.08）。不用语义色 windowBackgroundColor，
        // 避免浅色外观下解析为白色。
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

#endif
