import SwiftUI
import Photos
import AVKit

struct VideoPeekPreview: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Rectangle()
                    .fill(.black)
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .frame(
            width: 280,
            height: 280 * CGFloat(asset.pixelHeight) / CGFloat(max(asset.pixelWidth, 1))
        )
        .task {
            await loadPlayerItem()
        }
        .onDisappear {
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
        }
    }

    private func loadPlayerItem() async {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = true

        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }

        guard let item else { return }
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            newPlayer.seek(to: .zero)
            newPlayer.play()
        }
        player = newPlayer
        newPlayer.play()
    }
}
