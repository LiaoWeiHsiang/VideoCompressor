import SwiftUI
import Photos
import AVFoundation

struct QueueItemThumbnail: View {
    let source: VideoSource
    @State private var fileImage: UIImage?

    var body: some View {
        Group {
            switch source {
            case .asset(let asset):
                VideoThumbnailView(asset: asset)
            case .file:
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let fileImage {
                            Image(uiImage: fileImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(.gray.opacity(0.2))
                                .overlay { Image(systemName: "video.fill").foregroundStyle(.secondary) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .task {
                        await loadFileThumbnail()
                    }
            }
        }
    }

    private func loadFileThumbnail() async {
        guard case .file(let video) = source else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
        generator.appliesPreferredTrackTransform = true
        if let cgImage = try? await generator.image(at: .zero).image {
            fileImage = UIImage(cgImage: cgImage)
        }
    }
}
