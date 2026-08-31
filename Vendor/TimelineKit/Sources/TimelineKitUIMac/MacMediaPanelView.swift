#if canImport(AppKit)
import AppKit
import Observation
import TimelineKitUIShared

/// Browser 右栏：按拍摄日期分组的媒体面板。
///
/// FCP 风格：折叠式日期头（"2026年4月28日 (1)"）+ 每组的缩略图网格。
/// 数据源为 `TimelineLibraryStore.groupedMedia`（按拍摄日期倒序分组）。
@MainActor
final class MacMediaPanelView: NSView {

    // MARK: - Callbacks

    /// User tapped a media item — host adds it to the timeline.
    var onMediaSelected: ((LibraryMediaEntry) -> Void)?
    /// User tapped a project row — host switches the active project.
    var onSelectProject: ((UUID) -> Void)?

    // MARK: - Subviews

    private let libraryStore: TimelineLibraryStore
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 折叠状态：已折叠的日期（startOfDay）。
    private var collapsedDates: Set<Date> = []
    /// 当前活动项目 ID（高亮对应项目行）。
    var activeProjectID: UUID?

    private static let headerIdentifier = NSUserInterfaceItemIdentifier("MacMediaHeader")
    static let projectHeaderIdentifier = NSUserInterfaceItemIdentifier("MacProjectHeader")
    /// 拖出媒体条目到时间线的 pasteboard 类型（携带 Codable LibraryMediaEntry）。
    static let mediaDragType = NSPasteboard.PasteboardType("com.timelinekit.mediaentry")

    // MARK: - Init

    init(libraryStore: TimelineLibraryStore) {
        self.libraryStore = libraryStore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        setupViews()
        refresh()
        startObserving()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 84)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        // Section header (date) geometry.
        layout.headerReferenceSize = NSSize(width: 0, height: 28)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [NSColor(white: 0.08, alpha: 1)]
        collectionView.register(MacMediaGridItem.self, forItemWithIdentifier: MacMediaGridItem.identifier)
        collectionView.register(MacMediaSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Self.headerIdentifier)
        collectionView.register(MacProjectItem.self, forItemWithIdentifier: MacProjectItem.identifier)
        collectionView.register(MacProjectSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Self.projectHeaderIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        // 拖出媒体条目到时间线（数据源 pasteboardWriterItemAt 提供 item）。
        collectionView.registerForDraggedTypes([Self.mediaDragType])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
    }

    // MARK: - Store observation

    private var observesStore = false

    private func startObserving() {
        guard !observesStore else { return }
        observesStore = true
        observeLoop()
    }

    private func observeLoop() {
        withObservationTracking {
            _ = libraryStore.library
            _ = libraryStore.projects
            _ = libraryStore.mediaEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observesStore else { return }
                self.refresh()
                self.observeLoop()
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        collectionView.reloadData()

        let hasLibrary = libraryStore.hasLibrary
        let empty = libraryStore.groupedMedia.isEmpty
        if !hasLibrary {
            emptyLabel.stringValue = "创建资源库后导入媒体"
            emptyLabel.isHidden = false
        } else if empty {
            emptyLabel.stringValue = "导入媒体\n（图片 / 视频 / 音频）"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension MacMediaPanelView: NSCollectionViewDataSource {
    /// 是否有项目分组 section（section 0）。
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        let projectSections = projects.isEmpty ? 0 : 1
        return projectSections + libraryStore.groupedMedia.count
    }

    /// 将 section 映射为"项目 section"还是"日期分组索引"。
    private func isProjectSection(_ section: Int) -> Bool {
        !projects.isEmpty && section == 0
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        if isProjectSection(section) {
            return projects.count
        }
        let dateSection = section - (projects.isEmpty ? 0 : 1)
        let group = libraryStore.groupedMedia[dateSection]
        return collapsedDates.contains(group.date) ? 0 : group.items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        if isProjectSection(indexPath.section) {
            let item = collectionView.makeItem(withIdentifier: MacProjectItem.identifier, for: indexPath) as? MacProjectItem
                ?? MacProjectItem()
            let project = projects[indexPath.item]
            item.configure(project: project, isSelected: project.id == activeProjectID)
            return item
        }
        let item = collectionView.makeItem(withIdentifier: MacMediaGridItem.identifier, for: indexPath) as? MacMediaGridItem
            ?? MacMediaGridItem()
        let dateSection = indexPath.section - (projects.isEmpty ? 0 : 1)
        let group = libraryStore.groupedMedia[dateSection]
        let entry = group.items[indexPath.item]
        item.configure(entry: entry)
        return item
    }

    /// Provide a pasteboard writer so media items can be dragged out onto the
    /// timeline canvas. Encodes the LibraryMediaEntry as JSON. Project rows are
    /// not draggable.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        if isProjectSection(indexPath.section) { return nil }
        let dateSection = indexPath.section - (projects.isEmpty ? 0 : 1)
        let group = libraryStore.groupedMedia[dateSection]
        let entry = group.items[indexPath.item]
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(entry) {
            item.setData(data, forType: Self.mediaDragType)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        if isProjectSection(indexPath.section) {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.projectHeaderIdentifier, for: indexPath) as? MacProjectSectionHeader
                ?? MacProjectSectionHeader()
            header.configure(count: projects.count)
            return header
        }
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerIdentifier, for: indexPath) as? MacMediaSectionHeader
            ?? MacMediaSectionHeader()
        let dateSection = indexPath.section - (projects.isEmpty ? 0 : 1)
        let group = libraryStore.groupedMedia[dateSection]
        let count = group.items.count
        let isCollapsed = collapsedDates.contains(group.date)
        header.configure(date: group.date, count: count, isCollapsed: isCollapsed)
        header.onToggle = { [weak self] in
            guard let self else { return }
            if isCollapsed {
                self.collapsedDates.remove(group.date)
            } else {
                self.collapsedDates.insert(group.date)
            }
            self.collectionView.reloadData()
        }
        return header
    }

    /// 当前库内项目列表。
    private var projects: [LibraryProject] { libraryStore.projects }
}

// MARK: - NSCollectionViewDelegate

extension MacMediaPanelView: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let idx = indexPaths.first else { return }
        if isProjectSection(idx.section) {
            let project = projects[idx.item]
            onSelectProject?(project.id)
            return
        }
        let dateSection = idx.section - (projects.isEmpty ? 0 : 1)
        let group = libraryStore.groupedMedia[dateSection]
        let entry = group.items[idx.item]
        onMediaSelected?(entry)
    }
}

// MARK: - MacMediaGridItem

@MainActor
final class MacMediaGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MacMediaGridItem")

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        container.layer?.cornerRadius = 4

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(thumbView)

        nameLabel.font = .systemFont(ofSize: 9, weight: .medium)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            thumbView.heightAnchor.constraint(equalToConstant: 52),

            nameLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4)
        ])
        self.view = container
    }

    func configure(entry: LibraryMediaEntry) {
        nameLabel.stringValue = entry.originalFileName
        thumbView.image = NSImage(systemSymbolName: Self.symbol(for: entry.kind), accessibilityDescription: nil)
    }

    private static func symbol(for kind: LibraryMediaEntry.MediaKind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }
}

// MARK: - MacMediaSectionHeader

@MainActor
final class MacMediaSectionHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("MacMediaSectionHeader")

    var onToggle: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date, count: Int, isCollapsed: Bool) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日"
        let chevron = isCollapsed ? "▸" : "▾"
        titleLabel.stringValue = "\(chevron) \(fmt.string(from: date))  (\(count))"
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

// MARK: - MacProjectSectionHeader

/// "项目 (N)" 分组头（项目 section 的 header）。
@MainActor
final class MacProjectSectionHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("MacProjectHeader")

    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int) {
        titleLabel.stringValue = "▾ 项目  (\(count))"
    }
}

#endif
