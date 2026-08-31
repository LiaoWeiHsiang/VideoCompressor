import SwiftUI

struct VideoTrimSliderView: View {
    let duration: Double
    @Binding var startTime: Double
    @Binding var endTime: Double
    var onScrub: (Double) -> Void = { _ in }

    private let trackHeight: CGFloat = 44
    private let handleTouchWidth: CGFloat = 44
    private let minimumSelectionSeconds: Double = 0.3

    // Captured once when each drag begins, so we can compute the new value from
    // `translation` (delta from the gesture's start point) instead of `location`
    // (position relative to the view's *current* frame). The handle repositions itself
    // as the value changes, which would otherwise corrupt `location` mid-drag — the
    // view sliding out from under the finger cancels out the reported movement.
    @State private var startTimeAtDragBegin: Double?
    @State private var endTimeAtDragBegin: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let startX = position(for: startTime, width: width)
            let endX = position(for: endTime, width: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: max(endX - startX, 4), height: trackHeight)
                    .offset(x: startX)

                handle(x: startX, height: trackHeight, identifier: "trimStartHandle") { translationWidth in
                    if startTimeAtDragBegin == nil { startTimeAtDragBegin = startTime }
                    let deltaSeconds = Double(translationWidth / width) * duration
                    let candidate = (startTimeAtDragBegin ?? startTime) + deltaSeconds
                    startTime = min(max(candidate, 0), endTime - minimumSelectionSeconds)
                    onScrub(startTime)
                } onEnd: {
                    startTimeAtDragBegin = nil
                }

                handle(x: endX, height: trackHeight, identifier: "trimEndHandle") { translationWidth in
                    if endTimeAtDragBegin == nil { endTimeAtDragBegin = endTime }
                    let deltaSeconds = Double(translationWidth / width) * duration
                    let candidate = (endTimeAtDragBegin ?? endTime) + deltaSeconds
                    endTime = max(min(candidate, duration), startTime + minimumSelectionSeconds)
                    onScrub(endTime)
                } onEnd: {
                    endTimeAtDragBegin = nil
                }
            }
        }
        .frame(height: trackHeight)
    }

    private func handle(
        x: CGFloat,
        height: CGFloat,
        identifier: String,
        onDrag: @escaping (CGFloat) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        // The visible capsule is thin, but real fingers need a much bigger target to
        // reliably grab it — widen the draggable hit area without changing how it looks.
        Capsule()
            .fill(Color.yellow)
            .frame(width: 10, height: height)
            .shadow(radius: 1)
            .frame(width: handleTouchWidth, height: max(height, handleTouchWidth))
            .contentShape(Rectangle())
            .position(x: x, y: height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        onEnd()
                    }
            )
            .accessibilityIdentifier(identifier)
    }

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }
}
