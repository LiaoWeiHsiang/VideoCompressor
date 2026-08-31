#if canImport(AppKit)
import AppKit
import TimelineKitCore
import TimelineKitUIShared

// MARK: - MacTimelineCanvasHost

/// Composes the AppKit timeline area: label sidebar + scroll view + canvas.
///
/// Responsibilities (mirrors iOS ClipEditorViewController):
///   - owns the NSScrollView that wraps the canvas document view
///   - owns the track label sidebar and keeps it vertically synced
///   - wires canvas gestures to EditorStore
///   - exposes `apply(timeline:selection:)` driven by the SwiftUI shell
@MainActor
final class MacTimelineCanvasHost: NSView {

    // MARK: - Subviews

    private var store: EditorStore
    private let libraryStore: TimelineLibraryStore
    private var timeline: EditorTimeline
    private var selection: SelectionState

    private let scrollView = NSScrollView()
    private let canvas = MacTimelineCanvasView(frame: .zero)
    private let labelSidebar = MacTrackLabelSidebar(frame: .zero)

    private var didInitialLayout = false
    private var isSyncingScroll = false

    // Zoom state
    private var magnifyStartPPS: CGFloat = 0

    // Scrub state
    private var scrubWasPlaying = false
    private var lastScrubTime: CFTimeInterval = 0
    private let scrubThrottle: CFTimeInterval = 0.033

    // MARK: - Init

    init(store: EditorStore, libraryStore: TimelineLibraryStore) {
        self.store = store
        self.libraryStore = libraryStore
        self.timeline = store.timeline
        self.selection = store.selection
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        setupGestureCallbacks()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Label sidebar (left)
        labelSidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelSidebar)

        // Scroll view + canvas (right)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = NSColor(white: 0.08, alpha: 1)
        scrollView.documentView = canvas
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 6.0
        scrollView.minMagnification = 0.2
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            labelSidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelSidebar.topAnchor.constraint(equalTo: topAnchor),
            labelSidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelSidebar.widthAnchor.constraint(equalToConstant: MacTimelineCanvasView.labelSidebarWidth),

            scrollView.leadingAnchor.constraint(equalTo: labelSidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Vertical scroll sync: label sidebar follows the canvas scroll.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupGestureCallbacks() {
        canvas.onSegmentTap = { [weak self] segID in
            guard let self else { return }
            self.selection.selectOnly(segID)
            self.store.selection = self.selection
        }
        canvas.onEmptyTap = { [weak self] in
            guard let self else { return }
            self.selection.deselect()
            self.store.selection = self.selection
        }
        canvas.onPlayheadScrub = { [weak self] time in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastScrubTime >= self.scrubThrottle else { return }
            self.lastScrubTime = now
            self.store.seek(to: time)
        }
        canvas.onScrubEnded = { [weak self] in
            guard let self else { return }
            self.lastScrubTime = 0
        }
        // Drop a media entry from the Browser onto the canvas → insert into main track.
        canvas.onDropMedia = { [weak self] entry, time in
            guard let self else { return }
            guard let url = self.libraryStore.library?.mediaFileURL(for: entry) else { return }
            switch entry.kind {
            case .video, .image:
                _ = self.store.addVisualSegment(localURL: url, nativeDuration: entry.kind == .video ? entry.duration : nil)
            case .audio:
                _ = self.store.addAudioSegment(localURL: url, nativeDuration: entry.duration ?? 0)
            case .other:
                break
            }
        }
        labelSidebar.onToggleLock = { [weak self] id in
            guard let self, let t = self.store.timeline.track(id: id) else { return }
            self.store.setTrackLocked(id: id, isLocked: !t.isLocked)
        }
        labelSidebar.onToggleHidden = { [weak self] id in
            guard let self, let t = self.store.timeline.track(id: id), !t.isMainTrack else { return }
            self.store.setTrackHidden(id: id, isHidden: !t.isHidden)
        }
        labelSidebar.onToggleMute = { [weak self] id in
            guard let self, let t = self.store.timeline.track(id: id) else { return }
            self.store.muteTrack(id: id, isMuted: !t.isMuted)
        }
    }

    // MARK: - Public API (called from SwiftUI representable)

    /// Update the backing EditorStore reference (e.g. when the active project
    /// changes and a NEW EditorStore is created). Without this, drag/drop and
    /// click handlers keep mutating the OLD store — changes would not appear in
    /// the timeline that the new project is displaying.
    func updateStore(_ newStore: EditorStore) {
        self.store = newStore
        self.timeline = newStore.timeline
        self.selection = newStore.selection
    }

    func apply(timeline: EditorTimeline, selection: SelectionState) {
        let structural = hasStructuralChange(from: self.timeline, to: timeline)

        self.timeline = timeline
        self.selection = selection

        if structural {
            canvas.configure(timeline: timeline, availableWidth: scrollView.contentView.bounds.width)
            labelSidebar.configure(tracks: timeline.tracks)
        } else {
            canvas.relayoutSegments(timeline: timeline)
        }
        canvas.updatePlayhead(time: selection.playheadTime)
        canvas.updateSelection(ids: selection.selectedSegmentIDs)

        // Auto-scroll during playback: keep playhead centered.
        if store.isPlaying {
            scrollToPlayhead(time: selection.playheadTime, animated: false)
        }

        // Keep label sidebar track list current even on non-structural changes
        // (lock/hide/mute toggles).
        labelSidebar.configure(tracks: timeline.tracks)
        syncLabelScrollOffset()

        // The document view (canvas) frame / content changed; tell the scroll
        // view to recompute its clip region and repaint so newly added rows and
        // segment blocks actually become visible.
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func hasStructuralChange(from old: EditorTimeline, to new: EditorTimeline) -> Bool {
        guard old.tracks.count == new.tracks.count else { return true }
        for (o, n) in zip(old.tracks, new.tracks) {
            guard o.id == n.id, o.segments.count == n.segments.count else { return true }
            if zip(o.segments, n.segments).contains(where: { $0.id != $1.id }) { return true }
        }
        return false
    }

    // MARK: - Scroll sync

    @objc private func scrollViewDidScroll(_ note: Notification) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        labelSidebar.applyContentOffsetY(scrollView.contentView.bounds.origin.y)
        isSyncingScroll = false
    }

    private func syncLabelScrollOffset() {
        isSyncingScroll = true
        labelSidebar.applyContentOffsetY(scrollView.contentView.bounds.origin.y)
        isSyncingScroll = false
    }

    /// Scroll so `time` is at horizontal center.
    private func scrollToPlayhead(time: Double, animated: Bool) {
        let targetX = canvas.x(for: time) - scrollView.contentView.bounds.width / 2
        let minX: CGFloat = 0
        let maxX = max(minX, canvas.frame.width - scrollView.contentView.bounds.width)
        let clamped = min(max(targetX, minX), maxX)
        scrollView.contentView.scroll(to: NSPoint(x: clamped, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Magnification (pinch zoom)

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        switch event.phase {
        case .began:
            magnifyStartPPS = canvas.currentPixelsPerSecond
        case .changed:
            let newPPS = magnifyStartPPS * (1 + event.magnification)
            let playheadTime = selection.playheadTime
            canvas.zoom(to: newPPS, playheadTime: playheadTime)
            // Keep playhead centered-ish after content width changes.
            scrollToPlayhead(time: playheadTime, animated: false)
        default:
            break
        }
    }
}

// MARK: - NSViewRepresentable bridge

import SwiftUI

/// SwiftUI bridge for the AppKit timeline area.
struct MacTimelineRepresentable: NSViewRepresentable {
    let store: EditorStore
    let libraryStore: TimelineLibraryStore

    func makeNSView(context: Context) -> MacTimelineCanvasHost {
        MacTimelineCanvasHost(store: store, libraryStore: libraryStore)
    }

    func updateNSView(_ nsView: MacTimelineCanvasHost, context: Context) {
        nsView.apply(timeline: store.timeline, selection: store.selection)
    }
}

#endif
