#if canImport(AppKit)
import AppKit
import CoreGraphics
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUISharedViews

// MARK: - MacTimelineCanvasView

/// AppKit timeline canvas for the macOS editor shell.
///
/// Mirrors the iOS `TrackCanvasView` interaction model with the minimal
/// interaction set:
///   - horizontal / vertical scrolling (NSScrollView)
///   - click to select / deselect segments
///   - ruler playhead drag to scrub (throttled + snap to segment edges)
///   - trackpad pinch zoom (NSScrollView magnification, anchored at playhead)
///   - playhead auto-centering while playing
///   - track label sidebar with lock / hide / mute toggles
///
/// Pure AppKit (NSView + CALayer + NSGestureRecognizer) so gesture fidelity
/// matches iOS's UIKit canvas.
@MainActor
final class MacTimelineCanvasView: NSView {

    // MARK: - Metrics

    static let rulerHeight: CGFloat    = 36
    static let trackHeight: CGFloat    = 50
    static let trackSpacing: CGFloat   = 3
    static let leftPadding: CGFloat    = 16
    static let rightPadding: CGFloat   = 32
    static let labelSidebarWidth: CGFloat = 136

    // MARK: - State

    private var timeline: EditorTimeline?
    private(set) var layout: TimelineTrackLayout = .empty
    private(set) var currentPixelsPerSecond: CGFloat = TimelineTrackLayout.defaultMinPPS

    private var rulerView: MacRulerView!
    private var trackRowViews: [UUID: MacTrackRowView] = [:]
    /// Internal for testing (playhead frame assertions).
    private(set) var playheadLayer: CALayer!

    // MARK: - Callbacks (wired by MacClipEditorViewController / shell)

    /// Called when the user taps a segment — shell writes to EditorStore.selection.
    var onSegmentTap: ((UUID) -> Void)?
    /// Called when the user taps empty canvas space (deselect).
    var onEmptyTap: (() -> Void)?
    /// Called when the user drags the playhead on the ruler (scrub).
    var onPlayheadScrub: ((Double) -> Void)?
    /// Called when scrub ends (e.g. to resume playback that was paused on scrub start).
    var onScrubEnded: (() -> Void)?
    /// Called when a media entry is dropped onto the canvas at a timeline time.
    var onDropMedia: ((LibraryMediaEntry, Double) -> Void)?
    /// Called when a label sidebar toggle is hit.
    var onToggleLock: ((UUID) -> Void)?
    var onToggleHidden: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupPlayhead()
        // 接收从媒体面板拖入的媒体条目（LibraryMediaEntry JSON）。
        registerForDraggedTypes([MacMediaPanelView.mediaDragType])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupPlayhead() {
        let layer = CALayer()
        layer.backgroundColor = NSColor.systemYellow.cgColor
        layer.frame = CGRect(x: 0, y: MacTimelineCanvasView.rulerHeight, width: 2, height: bounds.height - MacTimelineCanvasView.rulerHeight)
        layer.zPosition = 100
        self.layer?.addSublayer(layer)
        playheadLayer = layer
    }

    // MARK: - Configuration

    func configure(timeline: EditorTimeline, availableWidth: CGFloat) {
        self.timeline = timeline
        if currentPixelsPerSecond == TimelineTrackLayout.defaultMinPPS {
            currentPixelsPerSecond = TimelineTrackLayout.defaultPPS
        }
        applyLayout(timeline: timeline)
    }

    func zoom(to pixelsPerSecond: CGFloat, playheadTime: Double) {
        currentPixelsPerSecond = pixelsPerSecond
        guard let timeline else { return }
        applyLayout(timeline: timeline)
        updatePlayhead(time: playheadTime)
    }

    func relayoutSegments(timeline: EditorTimeline) {
        applyLayout(timeline: timeline)
    }

    func updatePlayhead(time: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = self.layout.x(for: time) - 1
        playheadLayer.frame = CGRect(
            x: x, y: MacTimelineCanvasView.rulerHeight,
            width: 2, height: max(bounds.height - MacTimelineCanvasView.rulerHeight, 0)
        )
        CATransaction.commit()
    }

    func updateSelection(ids: Set<UUID>) {
        for row in trackRowViews.values {
            row.updateSelection(ids: ids)
        }
    }

    /// Timeline time at a canvas X (delegates to shared TrackLayout).
    func time(at x: CGFloat) -> Double { layout.time(at: x) }

    /// Canvas X for a timeline time.
    func x(for time: Double) -> CGFloat { layout.x(for: time) }

    /// Hit-test a segment at a canvas point.
    func segmentID(at point: CGPoint) -> UUID? {
        for row in trackRowViews.values {
            let local = convert(point, to: row)
            if let sid = row.segmentID(at: local) { return sid }
        }
        return nil
    }

    // MARK: - Layout

    private func applyLayout(timeline: EditorTimeline) {
        let fitted = TimelineTrackLayout.fittedPPS(
            duration: timeline.duration,
            availableWidth: bounds.width
        )
        let pps = min(max(fitted, TimelineTrackLayout.defaultMinPPS), TimelineTrackLayout.defaultMaxPPS)
        currentPixelsPerSecond = pps
        layout = TimelineTrackLayout(
            duration: timeline.duration,
            pixelsPerSecond: pps
        )

        let sortedTracks = timeline.tracks.sorted { $0.zPosition < $1.zPosition }
        let totalHeight = MacTimelineCanvasView.rulerHeight
            + CGFloat(sortedTracks.count) * (MacTimelineCanvasView.trackHeight + MacTimelineCanvasView.trackSpacing)

        // setFrameSize (not frame assignment) so NSScrollView receives the
        // document-view frame-changed notification and recomputes its clip view.
        setFrameSize(NSSize(
            width: layout.totalWidth + MacTimelineCanvasView.rightPadding,
            height: totalHeight
        ))

        // Ruler
        if rulerView == nil {
            rulerView = MacRulerView()
            rulerView.frame = NSRect(x: 0, y: 0, width: frame.width, height: MacTimelineCanvasView.rulerHeight)
            addSubview(rulerView)
        }
        rulerView.frame.size.width = frame.width
        rulerView.configure(layout: layout)

        // Track rows
        var y = MacTimelineCanvasView.rulerHeight
        for track in sortedTracks {
            let row: MacTrackRowView
            if let existing = trackRowViews[track.id] {
                row = existing
            } else {
                row = MacTrackRowView(track: track, layout: layout)
                row.onSegmentTap = { [weak self] segID in self?.onSegmentTap?(segID) }
                row.onToggleLock = { [weak self] id in self?.onToggleLock?(id) }
                row.onToggleHidden = { [weak self] id in self?.onToggleHidden?(id) }
                row.onToggleMute = { [weak self] id in self?.onToggleMute?(id) }
                addSubview(row)
                trackRowViews[track.id] = row
            }
            row.configure(track: track, layout: layout)
            row.frame = NSRect(
                x: 0, y: y,
                width: frame.width,
                height: MacTimelineCanvasView.trackHeight
            )
            y += MacTimelineCanvasView.trackHeight + MacTimelineCanvasView.trackSpacing
        }

        // Remove stale rows
        let activeIDs = Set(sortedTracks.map(\.id))
        for (id, row) in trackRowViews where !activeIDs.contains(id) {
            row.removeFromSuperview()
            trackRowViews[id] = nil
        }

        // Force a repaint: layer-backed views don't auto-redraw on subview/frame
        // changes unless asked.
        needsDisplay = true
    }

    // MARK: - Mouse events (click select)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let segID = segmentID(at: point) {
            onSegmentTap?(segID)
        } else {
            onEmptyTap?()
        }
    }
}

// MARK: - NSDraggingDestination (media drop into track)

// NSView already conforms to NSDraggingDestination; NSView's own
// draggingEntered/performDragOperation are overridden here.
extension MacTimelineCanvasView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Only accept our media-entry pasteboard type.
        guard sender.draggingPasteboard.availableType(from: [MacMediaPanelView.mediaDragType]) != nil else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let data = pb.data(forType: MacMediaPanelView.mediaDragType),
              let entry = try? JSONDecoder().decode(LibraryMediaEntry.self, from: data) else {
            return false
        }
        // Drop position → timeline time (x is in canvas coordinates).
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let time = self.time(at: dropPoint.x)
        onDropMedia?(entry, max(0, time))
        return true
    }
}

// MARK: - MacRulerView

@MainActor
final class MacRulerView: NSView {
    private var layout: TimelineTrackLayout = .empty
    /// Called while the user drags on the ruler (scrub); value is timeline seconds.
    var onScrub: ((Double) -> Void)?
    /// Called when the drag ends.
    var onScrubEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handlePan(_ gr: NSPanGestureRecognizer) {
        switch gr.state {
        case .began, .changed:
            let x = gr.location(in: self).x
            onScrub?(layout.time(at: x))
        case .ended, .cancelled:
            onScrubEnded?()
        default:
            break
        }
    }

    func configure(layout: TimelineTrackLayout) {
        self.layout = layout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let tickColor  = NSColor.white.withAlphaComponent(0.3)
        let labelColor = NSColor.white.withAlphaComponent(0.6)
        let minorInterval = tickInterval(pixelsPerSecond: layout.pixelsPerSecond)
        let majorInterval = minorInterval * 5

        var t: Double = 0
        while t <= layout.duration + minorInterval {
            let x = layout.x(for: t)
            let isMajor = t.truncatingRemainder(dividingBy: majorInterval) < minorInterval * 0.5
            let tickH: CGFloat = isMajor ? 14 : 7

            tickColor.setFill()
            NSBezierPath(rect: NSRect(x: x - 0.5, y: bounds.height - tickH, width: 1, height: tickH)).fill()

            if isMajor {
                let label = formatTime(t)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: labelColor
                ]
                (label as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: attrs)
            }
            t += minorInterval
        }
    }

    private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60]
        for c in candidates {
            if CGFloat(c) * pixelsPerSecond >= 30 { return c }
        }
        return 60
    }

    private func formatTime(_ s: Double) -> String {
        let m   = Int(s) / 60
        let sec = Int(s) % 60
        let ms  = Int((s - Double(Int(s))) * 10)
        if s < 10 { return String(format: "%d:%02d.%d", m, sec, ms) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - MacTrackRowView

@MainActor
final class MacTrackRowView: NSView {
    private var track: EditorTrack
    private var layout: TimelineTrackLayout
    /// Internal for testing (segment block count assertions).
    private(set) var segmentViews: [UUID: MacSegmentBlockView] = [:]

    var onSegmentTap: ((UUID) -> Void)?
    var onToggleLock: ((UUID) -> Void)?
    var onToggleHidden: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?

    init(track: EditorTrack, layout: TimelineTrackLayout) {
        self.track = track
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        layer?.cornerRadius = 4
        buildSegments()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(track: EditorTrack, layout: TimelineTrackLayout) {
        self.track = track
        self.layout = layout
        relayoutSegments()
        updateTrackHeader()
    }

    func relayoutSegments() {
        let blockH = MacTimelineCanvasView.trackHeight - 8

        // Ensure a block exists for every current segment, removing stale ones.
        var validIDs = Set<UUID>()
        for seg in track.segments {
            validIDs.insert(seg.id)
            if segmentViews[seg.id] == nil {
                let block = MacSegmentBlockView(segment: seg, track: track, layout: layout)
                block.onTap = { [weak self] in self?.onSegmentTap?(seg.id) }
                addSubview(block)
                segmentViews[seg.id] = block
            }
        }
        // Remove blocks for segments that no longer exist.
        for (id, block) in segmentViews where !validIDs.contains(id) {
            block.removeFromSuperview()
            segmentViews[id] = nil
        }

        // Reposition all current blocks.
        for seg in track.segments {
            if let block = segmentViews[seg.id] {
                block.layout = layout
                block.frame = NSRect(
                    x: layout.x(for: seg.targetRange.start),
                    y: 4,
                    width: max(layout.width(for: seg.targetRange.duration), 16),
                    height: blockH
                )
            }
        }
        updateTrackHeader()
        needsDisplay = true
    }

    private func buildSegments() {
        for seg in track.segments {
            let block = MacSegmentBlockView(segment: seg, track: track, layout: layout)
            block.onTap = { [weak self] in self?.onSegmentTap?(seg.id) }
            addSubview(block)
            segmentViews[seg.id] = block
        }
    }

    func updateSelection(ids: Set<UUID>) {
        for (id, block) in segmentViews {
            block.isSelected = ids.contains(id)
        }
    }

    func segmentID(at point: CGPoint) -> UUID? {
        for (id, block) in segmentViews {
            if block.frame.contains(point) { return id }
        }
        return nil
    }

    private func updateTrackHeader() {
        // macOS shell: track header lives in the label sidebar (MacTrackLabelSidebar).
        // This method kept as a hook for future inline header affordances.
    }
}

// MARK: - MacSegmentBlockView

@MainActor
final class MacSegmentBlockView: NSView {
    private let segment: EditorSegment
    private let trackKind: EditorTrack.Kind
    var layout: TimelineTrackLayout

    private let kindColor: NSColor
    /// Text label for the segment (emoji / short text).
    private let label = NSTextField(labelWithString: "")

    var isSelected: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    var onTap: (() -> Void)?

    init(segment: EditorSegment, track: EditorTrack, layout: TimelineTrackLayout) {
        self.segment = segment
        self.trackKind = track.kind
        self.layout = layout
        self.kindColor = Self.blockColor(for: track.kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.systemYellow.cgColor

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        let bg = isSelected ? kindColor : kindColor.withAlphaComponent(0.55)
        layer?.backgroundColor = bg.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    private static func blockColor(for kind: EditorTrack.Kind) -> NSColor {
        switch kind {
        case .video:      return .systemPurple
        case .overlay:    return .systemOrange
        case .text:       return .systemGreen
        case .subtitle:   return .systemBlue
        case .audio:      return .systemTeal
        case .adjustment: return .systemYellow
        }
    }
}

#endif
