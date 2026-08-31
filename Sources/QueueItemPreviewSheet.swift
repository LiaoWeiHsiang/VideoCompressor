import SwiftUI
import Photos
import AVKit

struct QueueItemPreviewSheet: View {
    let source: VideoSource
    @Binding var trimRange: ClosedRange<Double>?
    var isEditable: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)

                if duration > 0 && isEditable {
                    VStack(spacing: 8) {
                        VideoTrimSliderView(duration: duration, startTime: $startTime, endTime: $endTime) { scrubTime in
                            seek(to: scrubTime)
                        }
                        .padding(.horizontal)

                        HStack {
                            Text(timeString(startTime))
                            Spacer()
                            Text("已選取 \(timeString(endTime - startTime))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(timeString(endTime))
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal)

                        if isFullRange {
                            Text("未剪輯，將壓縮整部影片")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("重設為完整影片") {
                                startTime = 0
                                endTime = duration
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle(isEditable ? "預覽與剪輯" : "預覽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditable {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("套用") {
                            trimRange = isFullRange ? nil : startTime...endTime
                            dismiss()
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("關閉") { dismiss() }
                    }
                }
            }
        }
        .task {
            await loadPlayer()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var isFullRange: Bool {
        startTime <= 0.05 && endTime >= duration - 0.05
    }

    private func timeString(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func loadPlayer() async {
        switch source {
        case .file(let video):
            player = AVPlayer(url: video.url)
            duration = (try? await AVURLAsset(url: video.url).load(.duration).seconds) ?? 0
        case .asset(let asset):
            duration = asset.duration
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            let item: AVPlayerItem? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    continuation.resume(returning: item)
                }
            }
            if let item {
                player = AVPlayer(playerItem: item)
            }
        }

        if let existing = trimRange {
            startTime = existing.lowerBound
            endTime = existing.upperBound
        } else {
            startTime = 0
            endTime = duration
        }
    }
}
