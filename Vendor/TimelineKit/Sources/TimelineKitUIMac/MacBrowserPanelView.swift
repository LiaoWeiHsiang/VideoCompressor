#if canImport(AppKit)
import AppKit
import Observation
import TimelineKitUIShared

// MARK: - MacBrowserPanelView

/// Browser panel (FCP style): an NSSplitViewController with a draggable divider
/// between the left resource-library sidebar and the right media panel.
///
/// - Left (`MacLibrarySidebarView`): library name / smart selections / events.
/// - Right (`MacMediaPanelView`): media grouped by capture date.
/// - The middle divider is draggable via NSSplitView.
@MainActor
final class MacBrowserPanelView: NSView {

    // MARK: - Callbacks (forwarded to child views)

    var onCreateOrOpenLibrary: (() -> Void)?
    var onImportMedia: (() -> Void)?
    var onMediaSelected: ((LibraryMediaEntry) -> Void)?
    var onCreateProject: (() -> Void)?
    var onSelectProject: ((UUID) -> Void)?
    /// 当前活动项目 ID（mediaPanel 用于高亮项目行）。
    var activeProjectID: UUID? { didSet { mediaPanel.activeProjectID = activeProjectID; mediaPanel.refresh() } }

    // MARK: - Subviews

    private let libraryStore: TimelineLibraryStore
    private let splitController = NSSplitViewController()
    private let sidebar: MacLibrarySidebarView
    private let mediaPanel: MacMediaPanelView

    static let sidebarMinWidth: CGFloat = 160

    // MARK: - Init

    init(libraryStore: TimelineLibraryStore) {
        self.libraryStore = libraryStore
        self.sidebar = MacLibrarySidebarView(frame: .zero)
        self.mediaPanel = MacMediaPanelView(libraryStore: libraryStore)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        setupViews()
        refresh()
        startObserving()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        sidebar.onCreateOrOpenLibrary = { [weak self] in self?.onCreateOrOpenLibrary?() }
        sidebar.onImportMedia = { [weak self] in self?.onImportMedia?() }
        sidebar.onCreateProject = { [weak self] in self?.onCreateProject?() }
        mediaPanel.onMediaSelected = { [weak self] entry in self?.onMediaSelected?(entry) }
        mediaPanel.onSelectProject = { [weak self] id in self?.onSelectProject?(id) }

        // Left sidebar pane.
        let sidebarVC = NSViewController()
        sidebarVC.view = sidebar
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = Self.sidebarMinWidth
        sidebarItem.preferredThicknessFraction = 0.28
        splitController.addSplitViewItem(sidebarItem)

        // Right media panel pane.
        let mediaVC = NSViewController()
        mediaVC.view = mediaPanel
        let mediaItem = NSSplitViewItem(viewController: mediaVC)
        mediaItem.minimumThickness = 220
        splitController.addSplitViewItem(mediaItem)

        _ = splitController.view
        let splitView = splitController.splitView
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Store observation (AppKit view → @Observable store)

    private var observesStore = false

    private func startObserving() {
        guard !observesStore else { return }
        observesStore = true
        observeLoop()
    }

    private func observeLoop() {
        withObservationTracking {
            _ = libraryStore.library
            _ = libraryStore.mediaEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observesStore else { return }
                self.refresh()
                self.observeLoop()
            }
        }
    }

    /// Refresh the sidebar + media panel from the library store state.
    func refresh() {
        sidebar.setLibraryName(libraryStore.library?.name)
        sidebar.setProjects(libraryStore.projects)
        mediaPanel.refresh()
    }
}

#endif


