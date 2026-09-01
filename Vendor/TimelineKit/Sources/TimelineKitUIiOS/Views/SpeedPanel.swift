#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared

/// LOCAL PATCH (see VENDORED.md #13). Per-segment playback speed for video.
///
/// Upstream carries `EditorSegment.speed` but applies it to audio only, and its one speed
/// control is a disabled stub, so there was no way to slow down or speed up a clip.
struct SpeedPanel: View {
    let segmentID: UUID
    let store: EditorStore
    var onDismiss: (() -> Void)? = nil

    /// Halving and doubling either side of normal, which is what the presets in editors
    /// people already use offer.
    private static let choices: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

    private var current: Double {
        store.timeline.segment(id: segmentID).map { min(max($0.speed, 0.25), 4.0) } ?? 1.0
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("片段速度")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if let segment = store.timeline.segment(id: segmentID) {
                    // Show what it costs: changing speed changes how much timeline the clip
                    // occupies, which is the part that surprises people.
                    Text(String(format: "%.1f 秒", segment.targetRange.duration))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
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

            HStack(spacing: 10) {
                ForEach(Self.choices, id: \.self) { choice in
                    let isActive = abs(current - choice) < 1e-3
                    Button {
                        store.setVideoSpeed(segmentID: segmentID, speed: choice)
                    } label: {
                        Text(choice == 1.0 ? "原速" : String(format: "%g×", choice))
                            .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isActive ? Color.yellow : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.13))
        .overlay(alignment: .top) { Divider().background(Color.white.opacity(0.08)) }
    }
}
#endif
