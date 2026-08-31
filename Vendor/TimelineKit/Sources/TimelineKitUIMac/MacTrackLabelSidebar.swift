#if canImport(AppKit)
import AppKit
import TimelineKitCore

// MARK: - MacTrackLabelSidebar

/// Track label sidebar shown to the left of the timeline canvas (剪映/FCP style).
///
/// One row per track: kind color swatch + label + lock/hide/mute toggle buttons.
/// Vertically synced with the canvas scroll view by the shell
/// (MacTimelineCanvasHost), mirroring the iOS TrackLabelsView pattern.
@MainActor
final class MacTrackLabelSidebar: NSView {

    // MARK: - Callbacks

    var onToggleLock: ((UUID) -> Void)?
    var onToggleHidden: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var onAddTrack: ((EditorTrack.Kind) -> Void)?

    // MARK: - State

    private var rows: [UUID: MacTrackLabelRow] = [:]

    static let rowHeight: CGFloat = MacTimelineCanvasView.trackHeight
    static let rowSpacing: CGFloat = MacTimelineCanvasView.trackSpacing
    static let rulerHeight: CGFloat = MacTimelineCanvasView.rulerHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tracks: [EditorTrack]) {
        let sorted = tracks.sorted { $0.zPosition < $1.zPosition }

        var y = Self.rulerHeight
        for track in sorted {
            let row: MacTrackLabelRow
            if let existing = rows[track.id] {
                row = existing
            } else {
                row = MacTrackLabelRow(track: track)
                row.onToggleLock = { [weak self] id in self?.onToggleLock?(id) }
                row.onToggleHidden = { [weak self] id in self?.onToggleHidden?(id) }
                row.onToggleMute = { [weak self] id in self?.onToggleMute?(id) }
                addSubview(row)
                rows[track.id] = row
            }
            row.configure(track: track)
            row.frame = NSRect(
                x: 0, y: y,
                width: bounds.width,
                height: Self.rowHeight
            )
            y += Self.rowHeight + Self.rowSpacing
        }

        // Remove stale rows
        let activeIDs = Set(sorted.map(\.id))
        for (id, row) in rows where !activeIDs.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
    }

    /// Keep the label rows aligned with the canvas vertical offset.
    func applyContentOffsetY(_ offsetY: CGFloat) {
        // Rows live in a coordinate space whose origin is the scroll content
        // origin; shifting bounds origin is the cheapest sync mechanism.
        bounds.origin.y = offsetY
    }
}

// MARK: - MacTrackLabelRow

@MainActor
final class MacTrackLabelRow: NSView {

    var onToggleLock: ((UUID) -> Void)?
    var onToggleHidden: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?

    private var track: EditorTrack
    private let swatch = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let lockButton = NSButton()
    private let eyeButton = NSButton()
    private let muteButton = NSButton()

    init(track: EditorTrack) {
        self.track = track
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.cornerRadius = 3

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(swatch)

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .white.withAlphaComponent(0.7)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        for (btn, action) in [
            (lockButton, #selector(lockTapped)),
            (eyeButton, #selector(eyeTapped)),
            (muteButton, #selector(muteTapped))
        ] {
            btn.isBordered = false
            btn.target = self
            btn.action = action
            btn.font = .systemFont(ofSize: 11)
            btn.contentTintColor = .white.withAlphaComponent(0.55)
            btn.translatesAutoresizingMaskIntoConstraints = false
            addSubview(btn)
        }

        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 60),

            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.trailingAnchor.constraint(equalTo: muteButton.leadingAnchor, constant: -4),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockButton.trailingAnchor.constraint(equalTo: eyeButton.leadingAnchor, constant: -4),
            lockButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(track: EditorTrack) {
        self.track = track
        titleLabel.stringValue = track.label
        swatch.layer?.backgroundColor = Self.kindColor(for: track.kind).cgColor

        lockButton.image = NSImage(systemSymbolName: track.isLocked ? "lock.fill" : "lock.open", accessibilityDescription: "锁定")
        eyeButton.image = NSImage(systemSymbolName: track.isHidden ? "eye.slash" : "eye", accessibilityDescription: "隐藏")
        muteButton.image = NSImage(systemSymbolName: track.isMuted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: "静音")

        lockButton.contentTintColor = track.isLocked ? .systemYellow : .white.withAlphaComponent(0.55)
        eyeButton.contentTintColor = track.isHidden ? .systemOrange : .white.withAlphaComponent(0.55)
        muteButton.contentTintColor = track.isMuted ? .systemOrange : .white.withAlphaComponent(0.55)

        // Main track: hide is not allowed (mirrors iOS rule).
        eyeButton.isEnabled = !track.isMainTrack
    }

    @objc private func lockTapped() { onToggleLock?(track.id) }
    @objc private func eyeTapped() { onToggleHidden?(track.id) }
    @objc private func muteTapped() { onToggleMute?(track.id) }

    private static func kindColor(for kind: EditorTrack.Kind) -> NSColor {
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
