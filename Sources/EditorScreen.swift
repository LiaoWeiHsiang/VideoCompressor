import SwiftUI
import AVFoundation
import CoreLocation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
import TimelineKitUIiOS

/// A prepared set of clips, ready to open the editor with. Identifiable so it can drive
/// `fullScreenCover(item:)` — presenting only once the clips have actually been resolved
/// to local files, which for iCloud videos can take a while.
struct EditorSession: Identifiable {
    let id = UUID()
    /// The queue item being edited; its saved edit is updated on the way out.
    let targetItemID: UUID
    let clips: [EditorScreen.EditorClip]
    /// The edit this item already had, so reopening resumes where it left off.
    let existingTimeline: EditorTimeline?
}

/// Hosts TimelineKit's editor.
///
/// Nothing is encoded here. The editor records *what* the video should contain and hands
/// that timeline back; every clip in the queue is then rendered and compressed together
/// when the user starts the run. Encoding stays with this app's own pipeline either way,
/// because TimelineKit's exporter has neither the source-relative bitrate ceiling nor the
/// creation-date handling that this app exists to provide — see
/// `Vendor/TimelineKit/VENDORED.md`.
struct EditorScreen: View {
    /// Clips to open the timeline with, in order, already resolved to local files.
    let clips: [EditorClip]
    /// Resumed edit, if this clip has been edited before.
    let existingTimeline: EditorTimeline?
    /// Called with the finished timeline when the user taps 完成.
    let onSave: (EditorTimeline) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store: EditorStore?

    /// One source clip on the timeline, plus the provenance the encoder needs later. A
    /// composition carries no metadata of its own, so date and location have to be
    /// remembered by the queue rather than read back off the edit.
    struct EditorClip {
        let url: URL
        let shotAt: Date?
        let location: CLLocation?
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    ClipEditorView(store: store, onRequestExport: { timeline in
                        onSave(timeline)
                        dismiss()
                    })
                } else {
                    ProgressView("載入中…")
                }
            }
        }
        .task { await loadTimeline() }
    }

    /// Longest side the finished video may reach, matching the compressor's own cap so the
    /// editor never renders detail the encoder is about to throw away.
    static let maxLongEdge: CGFloat = 1920
    static let maxShortEdge: CGFloat = 1080

    @MainActor
    private func loadTimeline() async {
        guard store == nil else { return }

        if let existingTimeline {
            store = EditorStore(timeline: existingTimeline)
            return
        }

        let canvas = await Self.canvas(matching: clips.first?.url)
        let newStore = EditorStore(timeline: EditorTimeline(canvas: canvas))
        for clip in clips {
            guard let duration = try? await AVURLAsset(url: clip.url).load(.duration),
                  duration.isNumeric, duration.seconds > 0 else { continue }
            _ = newStore.addVisualSegment(localURL: clip.url, nativeDuration: duration.seconds)
        }
        store = newStore
    }

    /// Builds a canvas matching the clip itself, so an untouched edit comes out looking
    /// exactly like the original.
    ///
    /// TimelineKit's presets are four fixed shapes at 720, which would both downscale the
    /// footage and crop anything that is not 16:9, 9:16, 1:1 or 3:4 — an 18:9 phone clip
    /// would lose its edges before the user had made a single edit. Taking the clip's own
    /// display size and frame rate means no default change at all.
    ///
    /// `naturalSize` describes how the frames are *stored*, which for phone footage is
    /// almost always landscape regardless of how the phone was held — the rotation lives in
    /// `preferredTransform`. Reading naturalSize alone calls every portrait clip landscape.
    static func canvas(matching url: URL?) async -> EditorCanvas {
        let fallback = EditorCanvas.Preset.landscape_16_9.canvas
        guard let url,
              let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return fallback }

        // Applying the transform uses only its rotation/scale part, which is what swaps the
        // axes; the sign depends on the rotation direction, hence abs().
        let displayed = size.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width > 0, height > 0 else { return fallback }

        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        let scale = min(1, min(maxLongEdge / longEdge, maxShortEdge / shortEdge))

        // Odd dimensions are not encodable in 4:2:0 chroma, so round down to even.
        func even(_ value: CGFloat) -> Int {
            let scaled = Int((value * scale).rounded(.down))
            return scaled % 2 == 0 ? scaled : scaled - 1
        }

        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30
        let fps = frameRate > 0 ? Int(frameRate.rounded()) : 30

        return EditorCanvas(width: max(even(width), 2), height: max(even(height), 2), fps: fps)
    }
}
