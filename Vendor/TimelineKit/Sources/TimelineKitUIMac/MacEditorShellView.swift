#if canImport(AppKit)
import AppKit
import AVFoundation
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUISharedViews

// MARK: - MacEditorShellView

/// AppKit root container for the macOS editor shell (FCP style).
///
/// Layout:
///   - top toolbar (MacEditorToolbar)
///   - vertical split (NSSplitViewController):
///       - top area (MacEditorTopAreaView: Browser | Viewer | Inspector)
///       - timeline area (MacTimelineCanvasHost + control bar)
///
/// NSSplitViewController + NSSplitViewItem provide the initial proportions
/// (`preferredThicknessFraction`) and min/max pane sizes (`minimumThickness`)
/// natively — no manual divider math, no setPosition timing issues.
@MainActor
final class MacEditorShellView: NSView {

    // MARK: - Minimum heights

    static let topAreaMinHeight: CGFloat = 240
    static let timelineMinHeight: CGFloat = 140

    // MARK: - Subviews

    private let splitController = NSSplitViewController()
    private let topArea: MacEditorTopAreaView
    private let timelineHost: MacTimelineCanvasHost
    private let store: EditorStore

    // MARK: - Init

    init(
        store: EditorStore,
        libraryStore: TimelineLibraryStore,
        compositionPlayer: AVPlayer?,
        timelinePreviewView: TimelinePreviewView?,
        onImportMedia: (() -> Void)? = nil,
        onCreateOrOpenLibrary: (() -> Void)? = nil,
        onCreateProject: (() -> Void)? = nil,
        onSelectProject: ((UUID) -> Void)? = nil,
        activeProjectID: UUID? = nil
    ) {
        self.store = store
        self.topArea = MacEditorTopAreaView(
            store: store,
            libraryStore: libraryStore,
            compositionPlayer: compositionPlayer,
            timelinePreviewView: timelinePreviewView,
            onImportMedia: onImportMedia,
            onCreateOrOpenLibrary: onCreateOrOpenLibrary,
            onCreateProject: onCreateProject,
            onSelectProject: onSelectProject,
            activeProjectID: activeProjectID
        )
        self.timelineHost = MacTimelineCanvasHost(store: store, libraryStore: libraryStore)
        super.init(frame: .zero)
        // 强制深色外观：编辑器整体是深色主题（与 iOS 端 Color(white:0.08) 一致）。
        // 不设置时系统浅色外观会让 windowBackgroundColor 等语义色解析为白色，
        // 与时间线/预览的硬编码深色背景不一致。
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// preferredThicknessFraction does not apply when the NSSplitViewController
    /// is embedded as a plain view (not a real VC hierarchy). Set the initial
    /// split position once the window is available instead.
    private var didSetInitialSplit = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didSetInitialSplit else { return }
        didSetInitialSplit = true
        let split = splitController.splitView
        guard split.bounds.height > 0 else { return }
        split.setPosition(split.bounds.height * 2.0 / 3.0, ofDividerAt: 0)
    }

    private func setupViews() {
        // Top area pane.
        let topVC = NSViewController()
        topVC.view = topArea
        let topItem = NSSplitViewItem(viewController: topVC)
        topItem.minimumThickness = Self.topAreaMinHeight
        topItem.preferredThicknessFraction = 2.0 / 3.0
        splitController.addSplitViewItem(topItem)

        // Timeline pane.
        let timelineVC = NSViewController()
        timelineVC.view = timelineHost
        let timelineItem = NSSplitViewItem(viewController: timelineVC)
        timelineItem.minimumThickness = Self.timelineMinHeight
        timelineItem.preferredThicknessFraction = 1.0 / 3.0
        splitController.addSplitViewItem(timelineItem)

        // Access .view first: it triggers viewDidLoad, which is what populates
        // splitView.arrangedSubviews from splitViewItems. Reading .splitView
        // alone leaves arrangedSubviews empty (lazy load).
        _ = splitController.view

        // Vertical split: top area above timeline.
        let splitView = splitController.splitView
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Timeline state push (called by the SwiftUI shell)

    /// Update the backing store reference (active project may have changed).
    func updateStore(_ newStore: EditorStore) {
        timelineHost.updateStore(newStore)
    }

    func apply(timeline: EditorTimeline, selection: SelectionState) {
        timelineHost.apply(timeline: timeline, selection: selection)
    }

    /// 更新当前活动项目 ID（用于高亮项目行）。
    func updateActiveProject(id: UUID?) {
        topArea.updateActiveProject(id: id)
    }
}

#endif
