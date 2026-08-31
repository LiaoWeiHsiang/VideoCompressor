import SwiftUI
import Photos

struct VideoBrowserView: View {
    enum SortMode {
        case date
        case size
    }

    @StateObject private var store = VideoLibraryStore()
    @Environment(\.dismiss) private var dismiss
    var onSelect: ([PHAsset]) -> Void

    @State private var isMultiSelect = false
    @State private var selectedIDs: [String] = []
    @State private var sortMode: SortMode = .date

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMdEEEE")
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if store.authorizationDenied {
                    ContentUnavailableView(
                        "沒有相簿權限",
                        systemImage: "lock",
                        description: Text("請至「設定」開啟相簿存取權限")
                    )
                } else if store.isLoading {
                    ProgressView()
                } else if store.sections.isEmpty {
                    ContentUnavailableView("找不到影片", systemImage: "video.slash")
                } else {
                    ScrollView {
                        switch sortMode {
                        case .date:
                            dateGroupedGrid
                        case .size:
                            sizeSortedGrid
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if isMultiSelect {
                            confirmBar
                        }
                    }
                }
            }
            .navigationTitle("選取影片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("排序方式", selection: $sortMode) {
                            Text("依日期").tag(SortMode.date)
                            Text("依檔案大小").tag(SortMode.size)
                        }
                    } label: {
                        Label(sortMode == .date ? "依日期排序" : "依檔案大小排序", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMultiSelect ? "取消多選" : "多選") {
                        isMultiSelect.toggle()
                        if !isMultiSelect { selectedIDs.removeAll() }
                    }
                }
            }
        }
        .task {
            await store.loadIfNeeded()
        }
    }

    private var dateGroupedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
            ForEach(store.sections) { section in
                Section {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(section.assets, id: \.localIdentifier) { asset in
                            gridCell(for: asset)
                        }
                    }
                } header: {
                    sectionHeader(dayFormatter.string(from: section.date))
                }
            }
        }
        .padding(.bottom, isMultiSelect ? 72 : 0)
    }

    private var sizeSortedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            sectionHeader("依檔案大小排序（由大到小）")
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(store.assetsSortedBySize, id: \.localIdentifier) { asset in
                    gridCell(for: asset, badge: sizeText(for: asset))
                }
            }
        }
        .padding(.bottom, isMultiSelect ? 72 : 0)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }

    private func sizeText(for asset: PHAsset) -> String {
        guard let bytes = store.fileSizes[asset.localIdentifier] else { return "--" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func gridCell(for asset: PHAsset, badge: String? = nil) -> some View {
        let isSelected = selectedIDs.contains(asset.localIdentifier)

        return Button {
            if isMultiSelect {
                toggleSelection(for: asset)
            } else {
                onSelect([asset])
                dismiss()
            }
        } label: {
            VideoThumbnailView(asset: asset, badgeOverride: badge)
                .overlay(alignment: .topTrailing) {
                    if isMultiSelect {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, isSelected ? .blue : .black.opacity(0.4))
                            .padding(6)
                            .shadow(radius: 1)
                    }
                }
                .opacity(isMultiSelect && !isSelected ? 0.85 : 1)
        }
        .contextMenu {
            Button {
                onSelect([asset])
                dismiss()
            } label: {
                Label("選取這部影片", systemImage: "checkmark.circle")
            }
        } preview: {
            VideoPeekPreview(asset: asset)
        }
    }

    private var confirmBar: some View {
        Button {
            let assetsByID = Dictionary(uniqueKeysWithValues: store.allAssets.map { ($0.localIdentifier, $0) })
            let selectedAssets = selectedIDs.compactMap { assetsByID[$0] }
            onSelect(selectedAssets)
            dismiss()
        } label: {
            Text(selectedIDs.isEmpty ? "請選取影片" : "加入 \(selectedIDs.count) 部影片")
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedIDs.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .disabled(selectedIDs.isEmpty)
    }

    private func toggleSelection(for asset: PHAsset) {
        if let index = selectedIDs.firstIndex(of: asset.localIdentifier) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(asset.localIdentifier)
        }
    }
}
