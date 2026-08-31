#if canImport(AppKit)
import AppKit
import AVFoundation
import SwiftUI
import TimelineKitUIShared
import TimelineKitUISharedViews

// MARK: - MacEditorTopAreaView

/// Top area of the macOS editor shell: Browser | Viewer | Inspector (horizontal
/// split, FCP style).
///
/// NSSplitViewController + NSSplitViewItem provide the initial proportions
/// (`preferredThicknessFraction`) and min pane widths (`minimumThickness`)
/// natively — no manual divider math, no setPosition timing issues.
@MainActor
final class MacEditorTopAreaView: NSView {

    // MARK: - Minimum pane widths

    static let browserMinWidth: CGFloat   = 160
    static let viewerMinWidth: CGFloat    = 320
    static let inspectorMinWidth: CGFloat = 200

    // MARK: - Subviews

    private let splitController = NSSplitViewController()
    private let browserView: MacBrowserPanelView
    private let viewerHost = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private let inspectorView = MacInspectorPanelView(frame: .zero)

    private let store: EditorStore
    private let compositionPlayer: AVPlayer?
    private let timelinePreviewView: TimelinePreviewView?

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
        self.compositionPlayer = compositionPlayer
        self.timelinePreviewView = timelinePreviewView
        self.browserView = MacBrowserPanelView(libraryStore: libraryStore)
        super.init(frame: .zero)
        browserView.onImportMedia = onImportMedia
        browserView.onCreateOrOpenLibrary = onCreateOrOpenLibrary
        browserView.onCreateProject = onCreateProject
        browserView.onSelectProject = onSelectProject
        browserView.activeProjectID = activeProjectID
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 更新当前活动项目 ID（browserView 高亮对应项目行）。
    func updateActiveProject(id: UUID?) {
        browserView.activeProjectID = id
    }

    /// preferredThicknessFraction does not apply when the NSSplitViewController
    /// is embedded as a plain view (not a real VC hierarchy). Set the initial
    /// divider positions once the window is available instead.
    private var didSetInitialSplit = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didSetInitialSplit else { return }
        didSetInitialSplit = true
        let split = splitController.splitView
        let width = split.bounds.width
        guard width > 0 else { return }
        // Browser 1/4 : Viewer 1/2 : Inspector 1/4.
        split.setPosition(width * 0.25, ofDividerAt: 0)
        split.setPosition(width * 0.75, ofDividerAt: 1)
    }

    private func setupViews() {
        // Viewer content: shared SwiftUI preview + playback controls.
        let preview = EditorPreviewView(
            store: store,
            compositionPlayer: compositionPlayer,
            timelinePreviewView: timelinePreviewView
        )
        let viewerContent = VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 8)
            EditorControlBar(store: store)
                .frame(height: 52)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // NSHostingView 默认透明背景，显式设深色与 AppKit 区域一致。
        .background(Color(white: 0.08))
        viewerHost.rootView = AnyView(viewerContent)

        // Browser pane.
        let browserVC = NSViewController()
        browserVC.view = browserView
        let browserItem = NSSplitViewItem(viewController: browserVC)
        browserItem.minimumThickness = Self.browserMinWidth
        browserItem.preferredThicknessFraction = 0.25
        splitController.addSplitViewItem(browserItem)

        // Viewer pane.
        let viewerVC = NSViewController()
        viewerVC.view = viewerHost
        let viewerItem = NSSplitViewItem(viewController: viewerVC)
        viewerItem.minimumThickness = Self.viewerMinWidth
        viewerItem.preferredThicknessFraction = 0.5
        splitController.addSplitViewItem(viewerItem)

        // Inspector pane.
        let inspectorVC = NSViewController()
        inspectorVC.view = inspectorView
        let inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        inspectorItem.minimumThickness = Self.inspectorMinWidth
        inspectorItem.preferredThicknessFraction = 0.25
        splitController.addSplitViewItem(inspectorItem)

        // Access .view first: it triggers viewDidLoad, which is what populates
        // splitView.arrangedSubviews from splitViewItems. Reading .splitView
        // alone leaves arrangedSubviews empty (lazy load).
        _ = splitController.view

        // Horizontal split: Browser | Viewer | Inspector.
        let splitView = splitController.splitView
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
}

#endif

