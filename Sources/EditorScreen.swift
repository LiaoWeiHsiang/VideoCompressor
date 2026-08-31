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
    let clips: [EditorScreen.EditorClip]
}

/// Hosts TimelineKit's editor and routes its output through this app's encoder.
///
/// The editor is only allowed to decide *what* the video contains. How it is encoded stays
/// here, because TimelineKit's own exporter has neither the source-relative bitrate ceiling
/// nor the creation-date handling that this app exists to provide — see
/// `Vendor/TimelineKit/VENDORED.md`.
struct EditorScreen: View {
    /// Clips to open the timeline with, in order, already resolved to local files.
    let clips: [EditorClip]
    /// Bitrate ceiling to encode the finished edit at.
    let preset: CompressionPreset
    let dateMode: DateMode
    /// Called with the compressed result once the user exports.
    let onFinished: (EditedResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var compressor = VideoCompressor()
    @State private var store: EditorStore?
    @State private var isExporting = false
    @State private var errorMessage: String?

    /// One source clip on the timeline, plus the provenance the encoder needs. A
    /// composition carries no metadata of its own, so date and location have to be
    /// remembered here rather than read back off the edit.
    struct EditorClip {
        let url: URL
        let shotAt: Date?
        let location: CLLocation?
    }

    struct EditedResult {
        let outputURL: URL
        let shotAt: Date?
        let location: CLLocation?
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    ClipEditorView(store: store, onRequestExport: { timeline in
                        Task { await export(timeline) }
                    })
                } else {
                    ProgressView("載入中…")
                }
            }
            .overlay {
                if isExporting {
                    exportOverlay
                }
            }
        }
        .task { await loadTimeline() }
        .alert("錯誤", isPresented: .constant(errorMessage != nil)) {
            Button("確定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isExporting)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: compressor.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("壓縮中 \(Int(compressor.progress * 100))%")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("請保持螢幕亮著,不要切換 App")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// Short side to render the finished edit at.
    ///
    /// TimelineKit's canvas presets are all 720-based, so leaving this to the default
    /// would quietly export 720p — this app's whole point is to shrink files *without*
    /// dropping below 1080p, and that loss would be invisible until someone compared the
    /// result to the original. The compressor's own 1080p cap still applies on top.
    static let exportShortSide: CGFloat = 1080

    @MainActor
    private func loadTimeline() async {
        guard store == nil else { return }

        let canvas = await Self.canvasMatchingFirstClip(clips)
        let newStore = EditorStore(timeline: EditorTimeline(canvas: canvas))
        for clip in clips {
            guard let duration = try? await AVURLAsset(url: clip.url).load(.duration),
                  duration.isNumeric, duration.seconds > 0 else { continue }
            _ = newStore.addVisualSegment(localURL: clip.url, nativeDuration: duration.seconds)
        }
        store = newStore
    }

    /// Picks the canvas shape from the footage rather than defaulting to landscape, so a
    /// clip shot in portrait is not pillarboxed into black bars before it is even edited.
    private static func canvasMatchingFirstClip(_ clips: [EditorClip]) async -> EditorCanvas {
        guard let first = clips.first,
              let track = try? await AVURLAsset(url: first.url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return EditorCanvas.Preset.landscape_16_9.canvas }

        // naturalSize ignores rotation; applying the transform gives what the viewer sees.
        let displayed = size.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width > 0, height > 0 else { return EditorCanvas.Preset.landscape_16_9.canvas }

        let ratio = width / height
        if ratio > 1.15 { return EditorCanvas.Preset.landscape_16_9.canvas }
        if ratio < 0.87 { return EditorCanvas.Preset.portrait_9_16.canvas }
        return EditorCanvas.Preset.square_1_1.canvas
    }

    @MainActor
    private func export(_ timeline: EditorTimeline) async {
        isExporting = true
        defer { isExporting = false }

        do {
            let built = try await CompositionBuilder().build(
                from: timeline,
                renderSubtitles: true,
                renderSize: CGSize(width: Self.exportShortSide * 16 / 9, height: Self.exportShortSide)
            )
            let outputURL = try await compressor.compress(
                source: .composition(
                    built.composition,
                    videoComposition: built.videoComposition,
                    audioMix: built.audioMix,
                    // Date the edit by its first clip: an edit assembled from one shoot
                    // belongs at that point on a timeline, not at the moment it was
                    // rendered. `.now` restamping is still honoured by the encoder.
                    shotAt: dateMode == .now ? nil : clips.first?.shotAt
                ),
                preset: preset,
                dateMode: dateMode
            )
            onFinished(
                EditedResult(
                    outputURL: outputURL,
                    shotAt: dateMode == .now ? Date() : clips.first?.shotAt,
                    location: clips.first?.location
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
