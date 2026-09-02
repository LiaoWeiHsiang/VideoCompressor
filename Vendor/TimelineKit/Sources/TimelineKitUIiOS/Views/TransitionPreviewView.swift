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

    /// Half-window either side of the join. A second is long enough to read a dissolve and
    /// short enough to loop without becoming a distraction.
    private static let halfWindow = 0.5

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
        .frame(height: 132)
        .padding(.horizontal, 16)
        .task(id: revision) { await rebuild() }
        .onDisappear { teardown() }
    }

    @MainActor
    private func rebuild() async {
        teardown()
        isBuilding = true
        buildFailed = false

        guard let boundary = joinTime() else {
            isBuilding = false
            buildFailed = true
            return
        }

        do {
            let built = try await CompositionBuilder().build(from: store.timeline)
            let item = AVPlayerItem(asset: built.composition)
            if !built.composition.tracks(withMediaType: .video).isEmpty {
                item.videoComposition = built.videoComposition
            }
            // Muted: this is about seeing the cut, and a one-second loop of audio is
            // unpleasant.
            let queuePlayer = AVQueuePlayer(playerItem: item)
            queuePlayer.isMuted = true

            let start = CMTime(seconds: max(boundary - Self.halfWindow, 0), preferredTimescale: 600)
            let end = CMTime(seconds: min(boundary + Self.halfWindow,
                                          built.totalDuration.seconds), preferredTimescale: 600)
            item.forwardPlaybackEndTime = end

            looper = AVPlayerLooper(player: queuePlayer, templateItem: item,
                                    timeRange: CMTimeRange(start: start, end: end))
            await queuePlayer.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            queuePlayer.play()

            player = queuePlayer
            isBuilding = false
        } catch {
            isBuilding = false
            buildFailed = true
        }
    }

    /// Where the two clips meet, in composition time.
    private func joinTime() -> Double? {
        guard let segments = store.timeline.mainTrack?.segments else { return nil }
        guard let trailing = segments.first(where: { $0.id == context.trailingID }) else { return nil }
        return trailing.targetRange.start
    }

    @MainActor
    private func teardown() {
        (player as? AVQueuePlayer)?.pause()
        looper = nil
        player = nil
    }
}
#endif
