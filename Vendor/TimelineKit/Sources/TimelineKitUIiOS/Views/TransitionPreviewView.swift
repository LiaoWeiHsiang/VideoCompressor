#if canImport(UIKit)
import SwiftUI
import AVFoundation
import AVKit
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

/// LOCAL PATCH (see VENDORED.md #16). A looping one-second preview of the join, shown
/// while choosing a transition.
///
/// Picking from a grid of names is guesswork otherwise: the only way to see what "溶解"
/// does to *these two clips* was to export. This plays the real composition — the same
/// `CompositionBuilder` output the encoder consumes — so what is shown is what gets
/// written, rather than a mock-up that could drift from it.
struct TransitionPreviewView: View {
    let store: EditorStore
    let context: TransitionEditContext
    /// Bumped by the sheet whenever the chosen preset or duration changes, so the preview
    /// rebuilds without needing to diff the timeline itself.
    let revision: Int

    @State private var player: AVPlayer?
    @State private var looper: Any?
    @State private var isBuilding = true
    @State private var buildFailed = false

    /// Half-window either side of the join.
    ///
    /// A second total was too brief to read what an effect does — especially a wipe or a
    /// push, where most of the motion is at the edges — and five made the loop drag. Each
    /// side contributes up to this much; a clip shorter than that contributes what it has.
    private static let halfWindow = 1.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)

            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)      // it loops on its own; taps belong to the grid
            } else if isBuilding {
                ProgressView().tint(.white)
            } else if buildFailed {
                Text("無法預覽這個接點")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        // Kept modest: the sheet also has to fit the preset grid and the duration slider,
        // and a preview that crowds them out defeats the point of previewing while you
        // choose.
        .frame(height: 116)
        .padding(.horizontal, 16)
        .task(id: revision) { await rebuild() }
        .onDisappear { teardown() }
    }

    @MainActor
    private func rebuild() async {
        teardown()
        isBuilding = true
        buildFailed = false

        // Tapping through the grid cancels and restarts this; a short pause lets a run of
        // taps coalesce into one build instead of queueing a build per tap.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }

        guard let (timeline, boundary) = previewTimeline() else {
            isBuilding = false
            buildFailed = true
            return
        }

        do {
            let built = try await CompositionBuilder().build(from: timeline)
            guard !built.composition.tracks(withMediaType: .video).isEmpty else {
                isBuilding = false
                buildFailed = true
                return
            }

            // The window must be a real, non-empty range inside the composition. A join at
            // the very start or end, or a timeline shorter than the window, would otherwise
            // produce an invalid CMTimeRange.
            let total = built.totalDuration.seconds
            let startSeconds = max(boundary - Self.halfWindow, 0)
            let endSeconds = min(boundary + Self.halfWindow, total)
            guard total > 0, endSeconds - startSeconds > 0.05 else {
                isBuilding = false
                buildFailed = true
                return
            }
            let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let end = CMTime(seconds: endSeconds, preferredTimescale: 600)

            let template = AVPlayerItem(asset: built.composition)
            template.videoComposition = built.videoComposition

            // AVPlayerLooper requires a template that is NOT already enqueued — it makes
            // and cycles its own copies. Handing it an item the player already holds (which
            // `AVQueuePlayer(playerItem:)` would do) is misuse, and it crashes.
            let queuePlayer = AVQueuePlayer()
            // Muted: the point is seeing the cut, and a one-second loop of audio grates.
            queuePlayer.isMuted = true

            looper = AVPlayerLooper(player: queuePlayer, templateItem: template,
                                    timeRange: CMTimeRange(start: start, end: end))
            queuePlayer.play()

            player = queuePlayer
            isBuilding = false
        } catch {
            isBuilding = false
            buildFailed = true
        }
    }

    /// A two-clip timeline covering just the join, plus where the join falls in it.
    ///
    /// Building the whole timeline was both slow — every tap on a preset rebuilt every
    /// clip — and unnecessary: only the second either side of the cut is ever shown.
    ///
    /// Each side keeps the footage nearest the join, and the leading clip's in-point moves
    /// forward by exactly what was trimmed, so its *out*-point is unchanged. That matters:
    /// the cross-fade is built from footage lying outside the in/out points (VENDORED.md
    /// #8), so a preview that altered how much spare exists would show a different
    /// transition than the export.
    private func previewTimeline() -> (EditorTimeline, Double)? {
        var timeline = store.timeline
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.isMainTrack }) else { return nil }

        let ordered = timeline.tracks[trackIndex].segments
            .sorted { $0.targetRange.start < $1.targetRange.start }
        guard var leading = ordered.first(where: { $0.id == context.leadingID }),
              var trailing = ordered.first(where: { $0.id == context.trailingID })
        else { return nil }

        let window = Self.halfWindow * 2      // a second of each side

        let leadingKept = min(leading.targetRange.duration, window)
        let dropped = leading.targetRange.duration - leadingKept
        if var source = leading.sourceRange {
            // Move the in-point forward by what was dropped, in source seconds.
            source.start += dropped * min(max(leading.speed, 0.25), 4.0)
            leading.sourceRange = source
        }
        leading.targetRange = TimeRange(start: 0, duration: leadingKept)

        let trailingKept = min(trailing.targetRange.duration, window)
        trailing.targetRange = TimeRange(start: leadingKept, duration: trailingKept)

        // Only the two clips, and only the transition that joins them: everything else is
        // cost with nothing to show.
        var track = timeline.tracks[trackIndex]
        track.segments = [leading, trailing]
        timeline.tracks = [track]
        timeline.transitions = timeline.transitions.filter {
            $0.leadingSegmentID == leading.id && $0.trailingSegmentID == trailing.id
        }
        return (timeline, leadingKept)
    }

    @MainActor
    private func teardown() {
        (player as? AVQueuePlayer)?.pause()
        looper = nil
        player = nil
    }
}
#endif
