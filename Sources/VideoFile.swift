import Photos
import AVFoundation
import Foundation

struct VideoFile: Equatable {
    let url: URL

    static func from(asset: PHAsset) async throws -> VideoFile {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(throwing: CompressionError.assetLoadFailed)
                    return
                }
                do {
                    let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: urlAsset.url, to: copy)
                    continuation.resume(returning: VideoFile(url: copy))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum FileSizeFormatter {
    static func string(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
