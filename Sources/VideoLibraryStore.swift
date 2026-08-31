import Photos
import Foundation

@MainActor
final class VideoLibraryStore: ObservableObject {
    struct DaySection: Identifiable {
        let id: Date
        let date: Date
        let assets: [PHAsset]
    }

    @Published var sections: [DaySection] = []
    @Published var fileSizes: [String: Int64] = [:]
    @Published var authorizationDenied = false
    @Published var isLoading = false

    var allAssets: [PHAsset] {
        sections.flatMap { $0.assets }
    }

    var assetsSortedBySize: [PHAsset] {
        allAssets.sorted { fileSizes[$0.localIdentifier, default: 0] > fileSizes[$1.localIdentifier, default: 0] }
    }

    func loadIfNeeded() async {
        guard sections.isEmpty, !isLoading, !authorizationDenied else { return }
        isLoading = true
        defer { isLoading = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            authorizationDenied = true
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var grouped: [Date: [PHAsset]] = [:]
        var order: [Date] = []
        var sizes: [String: Int64] = [:]
        let calendar = Calendar.current

        result.enumerateObjects { asset, _, _ in
            let day = calendar.startOfDay(for: asset.creationDate ?? .distantPast)
            if grouped[day] == nil {
                grouped[day] = []
                order.append(day)
            }
            grouped[day]?.append(asset)

            let resources = PHAssetResource.assetResources(for: asset)
            let resource = resources.first(where: { $0.type == .video }) ?? resources.first
            if let resource, let size = resource.value(forKey: "fileSize") as? Int64 {
                sizes[asset.localIdentifier] = size
            }
        }

        sections = order.map { DaySection(id: $0, date: $0, assets: grouped[$0] ?? []) }
        fileSizes = sizes
    }
}
