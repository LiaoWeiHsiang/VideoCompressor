import SwiftUI

struct QueueRowView: View {
    @Binding var item: QueueItem
    let isCurrent: Bool
    let progress: Double
    /// Whether a "compress just this one" action can be offered right now — false while
    /// the queue is already busy, since compression runs one item at a time.
    var canCompressAlone: Bool = false
    var onCompressAlone: () -> Void = {}
    /// Tapping the thumbnail of a clip that hasn't been compressed yet opens the editor.
    var onEdit: () -> Void = {}

    @State private var showPreview = false
    @State private var showShareSheet = false
    @State private var saveConfirmation: String?
    @State private var saveError: String?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                // Before compression the thumbnail is the way into the editor; afterwards
                // there is nothing left to edit, so it previews the result instead.
                if item.status == .done {
                    showPreview = true
                } else {
                    onEdit()
                }
            } label: {
                QueueItemThumbnail(source: item.source)
                    .frame(width: 56, height: 56)
                    .overlay(alignment: .bottomTrailing) {
                        if item.status == .pending {
                            Image(systemName: "scissors")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(item.status == .loading || item.status == .compressing)

            VStack(alignment: .leading, spacing: 4) {
                statusView
                if let inputSizeText = item.inputSizeText {
                    Text(sizeSummary(inputSizeText: inputSizeText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let inputResolution = item.inputResolution {
                    Text(inputResolution)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let trimRange = item.trimRange {
                    Label(trimSummary(trimRange), systemImage: "scissors")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if item.status == .pending && canCompressAlone {
                Button {
                    onCompressAlone()
                } label: {
                    Label("只壓縮這部", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }

            if item.status == .done {
                Menu {
                    Button("儲存到相簿") { saveToPhotos() }
                    Button("分享 / 儲存到檔案") { showShareSheet = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            // Show what was produced, not what went in — the compressed copy is the thing
            // the user is deciding whether to keep.
            QueueItemPreviewSheet(
                source: item.outputURL.map { .file(VideoFile(url: $0)) } ?? item.source,
                trimRange: $item.trimRange,
                isEditable: false
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = item.outputURL {
                ShareSheet(items: [url])
            }
        }
        .alert("錯誤", isPresented: .constant(saveError != nil), actions: {
            Button("確定") { saveError = nil }
        }, message: {
            Text(saveError ?? "")
        })
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .pending:
            Text("等待中")
                .font(.callout)
        case .loading:
            Text("讀取中…")
                .font(.callout)
        case .compressing:
            if isCurrent {
                HStack {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                Text("等待中")
                    .font(.callout)
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完成")
            }
            .font(.callout)
            if let saveConfirmation {
                Text(saveConfirmation).font(.caption).foregroundStyle(.green)
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(item.errorMessage ?? "壓縮失敗")
            }
            .font(.callout)
        }
    }

    private func trimSummary(_ range: ClosedRange<Double>) -> String {
        func format(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "已剪輯 \(format(range.lowerBound))–\(format(range.upperBound))"
    }

    private func sizeSummary(inputSizeText: String) -> String {
        if let outputSizeText = item.outputSizeText {
            return "\(inputSizeText) → \(outputSizeText)"
        }
        return inputSizeText
    }

    private func saveToPhotos() {
        guard let url = item.outputURL else { return }
        Task {
            do {
                try await PhotoLibrarySaver.save(videoURL: url, creationDate: item.outputCreationDate, location: item.location)
                saveConfirmation = "已儲存到相簿"
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}
