#if canImport(AppKit)
import AppKit
import TimelineKitUIShared

/// Browser 左栏：资源库侧栏（FCP 左栏结构）。
///
/// 展示当前库名、"智能精选"、日期事件分组（按媒体分组日期派生的年份/日期列表）。
/// 选中一个事件时，右栏媒体面板聚焦该日期分组。
@MainActor
final class MacLibrarySidebarView: NSView {

    // MARK: - Callbacks

    var onCreateOrOpenLibrary: (() -> Void)?
    var onImportMedia: (() -> Void)?
    /// 用户选中某个资源库/事件（参数为 nil = 全库）。
    var onSelectScope: ((LibraryMediaEntry.MediaKind?) -> Void)?
    /// 用户点"创建项目"。
    var onCreateProject: (() -> Void)?
    /// 用户点某个项目（切换活动项目）。
    var onSelectProject: ((UUID) -> Void)?

    // MARK: - Subviews

    private let titleLabel = NSTextField(labelWithString: "资源库")
    private let libraryNameLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let importButton = NSButton()
    private let projectTitleLabel = NSTextField(labelWithString: "项目")
    private let createProjectButton = NSButton()
    private let projectListLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        libraryNameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        libraryNameLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        libraryNameLabel.lineBreakMode = .byTruncatingMiddle
        libraryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(libraryNameLabel)

        configureButton(openButton, title: "打开资源库", symbol: "folder", action: #selector(openTapped))
        configureButton(importButton, title: "导入媒体", symbol: "square.and.arrow.down", action: #selector(importTapped))

        projectTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        projectTitleLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        projectTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(projectTitleLabel)

        configureButton(createProjectButton, title: "新建项目", symbol: "plus", action: #selector(createProjectTapped))

        projectListLabel.font = .systemFont(ofSize: 11)
        projectListLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        projectListLabel.lineBreakMode = .byTruncatingMiddle
        projectListLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(projectListLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            libraryNameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            libraryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            libraryNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            importButton.topAnchor.constraint(equalTo: libraryNameLabel.bottomAnchor, constant: 16),
            importButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            openButton.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 8),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            projectTitleLabel.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 20),
            projectTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            createProjectButton.topAnchor.constraint(equalTo: projectTitleLabel.bottomAnchor, constant: 8),
            createProjectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            projectListLabel.topAnchor.constraint(equalTo: createProjectButton.bottomAnchor, constant: 10),
            projectListLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            projectListLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.title = title
        button.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }

    func setLibraryName(_ name: String?) {
        libraryNameLabel.stringValue = name ?? "未打开资源库"
    }

    func setProjects(_ projects: [LibraryProject]) {
        projectListLabel.stringValue = projects.isEmpty
            ? "暂无项目"
            : projects.map(\.name).joined(separator: "\n")
    }

    @objc private func openTapped() { onCreateOrOpenLibrary?() }
    @objc private func importTapped() { onImportMedia?() }
    @objc private func createProjectTapped() { onCreateProject?() }
}

#endif
