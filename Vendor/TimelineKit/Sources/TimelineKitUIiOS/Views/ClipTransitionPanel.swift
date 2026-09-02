#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared

/// LOCAL PATCH (see VENDORED.md #20). 轉場 and 動畫 merged into one tool.
///
/// They were separate categories in the toolbar, and the distinction — a transition joins
/// two clips, an animation plays at one clip's own edges — was not visible from the names.
/// Both answer the same question, "how does this clip begin and end", so they are one
/// panel now.
///
/// The junction is still only offered when there is a next clip to join to: an animation
/// works on a lone clip, a transition cannot.
struct ClipTransitionPanel: View {
    let segmentID: UUID
    let store: EditorStore
    var onDismiss: (() -> Void)? = nil

    private var segment: EditorSegment? { store.timeline.segment(id: segmentID) }

    /// The clip after this one, if any — what a junction transition would join to.
    private var nextSegment: EditorSegment? {
        let ordered = (store.timeline.mainTrack?.segments ?? [])
            .sorted { $0.targetRange.start < $1.targetRange.start }
        guard let index = ordered.firstIndex(where: { $0.id == segmentID }),
              index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }

    private var existingTransition: EditorTransition? {
        guard let next = nextSegment else { return nil }
        return store.timeline.transitions.first {
            $0.leadingSegmentID == segmentID && $0.trailingSegmentID == next.id
        }
    }

    private struct Choice: Identifiable {
        let id: String
        let name: String
        let icon: String
        let semantic: AnimationSemantic?
    }

    private static let entrance: [Choice] = [
        .init(id: "none",     name: "無",      icon: "xmark.circle",          semantic: nil),
        .init(id: "fadeIn",   name: "漸顯",    icon: "sun.horizon",           semantic: .fadeIn),
        .init(id: "slideInL", name: "向右滑入", icon: "arrow.right.to.line",   semantic: .slideInLeft),
        .init(id: "slideInR", name: "向左滑入", icon: "arrow.left.to.line",    semantic: .slideInRight),
        .init(id: "zoomIn",   name: "放大",    icon: "plus.magnifyingglass",  semantic: .zoomIn)
    ]

    private static let exit: [Choice] = [
        .init(id: "none",      name: "無",      icon: "xmark.circle",          semantic: nil),
        .init(id: "fadeOut",   name: "漸隱",    icon: "moon",                  semantic: .fadeOut),
        .init(id: "slideOutL", name: "向右退出", icon: "arrow.right.to.line",   semantic: .slideOutLeft),
        .init(id: "slideOutR", name: "向左退出", icon: "arrow.left.to.line",    semantic: .slideOutRight),
        .init(id: "zoomOut",   name: "縮小",    icon: "minus.magnifyingglass", semantic: .zoomOut)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("這段的開頭與結尾")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }

            row("入場", choices: Self.entrance, timing: .in,
                current: segment?.inAnimation?.semantic)
            row("出場", choices: Self.exit, timing: .out,
                current: segment?.outAnimation?.semantic)

            Divider().background(Color.white.opacity(0.1))

            if nextSegment != nil {
                Button {
                    // The junction has its own sheet, with the looping preview.
                    if let next = nextSegment {
                        store.selection.editingTransitionContext = TransitionEditContext(
                            leadingID: segmentID,
                            trailingID: next.id,
                            existingTransition: existingTransition
                        )
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.left.and.right.square")
                        Text(existingTransition == nil ? "與下一段的接點…" : "接點效果…")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            } else {
                // Said plainly, because the reason is not obvious from the timeline: a
                // transition needs something to transition *to*.
                Text("這是最後一段，沒有可以銜接的下一段影片。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.13))
        .overlay(alignment: .top) { Divider().background(Color.white.opacity(0.08)) }
    }

    @ViewBuilder
    private func row(
        _ label: String,
        choices: [Choice],
        timing: AnimationTiming,
        current: AnimationSemantic?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(choices) { choice in
                        let isActive = choice.semantic == current
                        Button {
                            if let semantic = choice.semantic {
                                store.setClipAnimation(
                                    segmentID: segmentID,
                                    animation: ClipAnimation(semantic: semantic,
                                                             timing: timing,
                                                             duration: 0.5)
                                )
                            } else {
                                store.removeClipAnimation(segmentID: segmentID, timing: timing)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: choice.icon)
                                    .font(.system(size: 17))
                                    .frame(width: 42, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isActive ? Color.yellow.opacity(0.9)
                                                           : Color.white.opacity(0.1))
                                    )
                                    .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.85))
                                Text(choice.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
#endif
