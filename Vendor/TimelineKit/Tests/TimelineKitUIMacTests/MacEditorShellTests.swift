#if canImport(AppKit)
import XCTest
import AppKit
import TimelineKitCore
import TimelineKitUIShared
@testable import TimelineKitUIMac

/// Structure smoke tests for the FCP-style four-zone macOS editor shell.
///
/// Verifies the UI-structure milestone: shell creates, all zones exist with the
/// correct pane types, and split min thicknesses are configured.
@MainActor
final class MacEditorShellTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> EditorStore {
        let canvas = EditorCanvas(width: 720, height: 1280, fps: 30)
        let timeline = EditorTimeline(canvas: canvas)
        return EditorStore(timeline: timeline)
    }

    private func makeShell() -> MacEditorShellView {
        MacEditorShellView(
            store: makeStore(),
            libraryStore: TimelineLibraryStore(),
            compositionPlayer: nil,
            timelinePreviewView: nil
        )
    }

    /// The vertical split (top area + timeline) hosted by the shell.
    /// NSSplitViewController.view is a wrapper NSView containing the NSSplitView
    /// as its child — search both levels.
    private func verticalSplit(_ shell: MacEditorShellView) -> NSSplitView? {
        if let direct = shell.subviews.first(where: { $0 is NSSplitView }) as? NSSplitView {
            return direct
        }
        return shell.subviews
            .flatMap { $0.subviews }
            .first { $0 is NSSplitView } as? NSSplitView
    }

    /// The horizontal split (Browser | Viewer | Inspector) inside the top area.
    /// NSSplitViewController wraps pane views in _NSSplitViewItemViewWrapper —
    /// search through the wrapper layers.
    private func horizontalSplit(_ shell: MacEditorShellView) -> NSSplitView? {
        guard let topArea = findTopArea(in: shell) else { return nil }
        if let direct = topArea.subviews.first(where: { $0 is NSSplitView }) as? NSSplitView {
            return direct
        }
        // Top area itself hosts a NSSplitViewController wrapper → NSSplitView.
        return topArea.subviews
            .flatMap { $0.subviews }
            .first { $0 is NSSplitView } as? NSSplitView
    }

    /// Locate the MacEditorTopAreaView through the vertical split's wrapper chain.
    private func findTopArea(in shell: MacEditorShellView) -> MacEditorTopAreaView? {
        guard let split = verticalSplit(shell) else { return nil }
        for pane in split.arrangedSubviews {
            if let top = pane as? MacEditorTopAreaView { return top }
            if let top = pane.subviews.first as? MacEditorTopAreaView { return top }
            if let top = pane.subviews.flatMap({ $0.subviews }).first as? MacEditorTopAreaView {
                return top
            }
        }
        return nil
    }

    // MARK: - Shell structure

    func testShellCreatesFourZones() throws {
        let shell = makeShell()
        let window = layoutInWindow(shell, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }

        // Toolbar is now the system unified titlebar (no in-content toolbar view).
        // The shell should start directly with the vertical split as its only subview.
        XCTAssertTrue(shell.subviews.allSatisfy { !($0 is NSButton) && !($0 is NSTextField) }, "shell should not host content toolbar controls")

        // Vertical split has two panes: top area + timeline.
        let split = verticalSplit(shell)
        XCTAssertNotNil(split, "missing vertical split view")
        XCTAssertEqual(split?.arrangedSubviews.count, 2, "expected top + timeline panes")

        // Top pane is the three-zone area (possibly wrapped by NSSplitViewItem).
        XCTAssertNotNil(findTopArea(in: shell), "top pane should contain MacEditorTopAreaView")

        // Horizontal split inside the top area has three panes.
        let hSplit = horizontalSplit(shell)
        XCTAssertNotNil(hSplit, "missing horizontal split view")
        XCTAssertEqual(hSplit?.arrangedSubviews.count, 3, "expected Browser | Viewer | Inspector")
    }

    func testAllZonesPresentWithCorrectTypes() throws {
        let shell = makeShell()
        let window = layoutInWindow(shell, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }

        let split = verticalSplit(shell)
        XCTAssertEqual(split?.isVertical ?? true, false, "shell split should be vertical")

        let hSplit = horizontalSplit(shell)
        XCTAssertEqual(hSplit?.isVertical ?? false, true, "top split should be horizontal")

        // Find the actual pane views inside the NSSplitViewItem wrappers.
        let panes = hSplit?.arrangedSubviews ?? []
        XCTAssertEqual(panes.count, 3)
        let containsBrowser = panes.contains { pane in
            pane is MacBrowserPanelView
                || pane.subviews.contains { $0 is MacBrowserPanelView }
                || pane.subviews.flatMap { $0.subviews }.contains { $0 is MacBrowserPanelView }
        }
        let containsInspector = panes.contains { pane in
            pane is MacInspectorPanelView
                || pane.subviews.contains { $0 is MacInspectorPanelView }
                || pane.subviews.flatMap { $0.subviews }.contains { $0 is MacInspectorPanelView }
        }
        XCTAssertTrue(containsBrowser, "Browser pane missing")
        XCTAssertTrue(containsInspector, "Inspector pane missing")
    }

    // MARK: - Real-window layout

    /// Drive a real layout pass through a window so NSSplitViewController
    /// actually arranges its panes (arrangedSubviews is lazy without one).
    private func layoutInWindow(_ view: NSView, size: NSSize) -> NSWindow {
        // Ensure AppKit is initialized (XCTest on macOS may not have done so).
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        // Preferred thickness fractions only apply once the window is visible
        // and the split view gets a real layout pass.
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            view.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return window
    }

    func testRealWindowLaysOutAllZones() throws {
        let shell = makeShell()
        let window = layoutInWindow(shell, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }

        guard let split = verticalSplit(shell) else {
            XCTFail("missing vertical split")
            return
        }
        // With a window, arrangedSubviews must be populated and sized.
        XCTAssertEqual(split.arrangedSubviews.count, 2, "expected 2 vertical panes")

        let topArea = split.arrangedSubviews[0]
        let timeline = split.arrangedSubviews[1]
        XCTAssertGreaterThan(topArea.frame.height, 100, "top area should have height")
        XCTAssertGreaterThan(timeline.frame.height, 100, "timeline should have height")

        // Horizontal three-pane split inside top area.
        guard let hSplit = horizontalSplit(shell) else {
            XCTFail("missing horizontal split")
            return
        }
        XCTAssertEqual(hSplit.arrangedSubviews.count, 3, "expected 3 horizontal panes")
        for (name, pane) in zip(["Browser", "Viewer", "Inspector"], hSplit.arrangedSubviews) {
            XCTAssertGreaterThan(pane.frame.width, 50, "\(name) should have width")
        }
    }

    // MARK: - Min thickness configuration

    func testVerticalSplitMinThicknessConfigured() throws {
        let shell = makeShell()
        let window = layoutInWindow(shell, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }

        let split = verticalSplit(shell)

        // NSSplitViewController drives the split; its splitViewItems carry the
        // minimum thickness. Verify via the public constants.
        XCTAssertEqual(MacEditorShellView.topAreaMinHeight, 240)
        XCTAssertEqual(MacEditorShellView.timelineMinHeight, 140)

        // Both panes must be present.
        XCTAssertEqual(split?.arrangedSubviews.count ?? 0, 2)
    }

    func testHorizontalSplitMinThicknessConfigured() throws {
        XCTAssertEqual(MacEditorTopAreaView.browserMinWidth, 160)
        XCTAssertEqual(MacEditorTopAreaView.viewerMinWidth, 320)
        XCTAssertEqual(MacEditorTopAreaView.inspectorMinWidth, 200)
    }
}

#endif
