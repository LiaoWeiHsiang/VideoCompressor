import SwiftUI
import UIKit
import Photos
import AVFoundation
import TimelineKitCore
import TimelineKitRender

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.editMode) private var editMode
    @State private var showBrowser = false
    @State private var queue: [QueueItem] = []
    @State private var preset: CompressionPreset = .medium
    @State private var dateMode: DateMode = .now
    @State private var errorMessage: String?
    @State private var isProcessingQueue = false
    @State private var currentProcessingID: UUID?
    @State private var isImportingSelection = false
    @State private var isSavingAll = false
    @State private var saveAllConfirmation: String?
    @State private var isPreparingEditor = false
    @State private var editorSession: EditorSession?

    @StateObject private var compressor = VideoCompressor()

    private var doneItems: [QueueItem] { queue.filter { $0.status == .done } }
    private var hasPendingItems: Bool { queue.contains { $0.status == .pending } }
    private var editedItemCount: Int {
        queue.filter { $0.status == .pending && $0.editedTimeline != nil }.count
    }
    private var hasEditedItems: Bool { editedItemCount > 0 }

    private var startButtonTitle: String {
        if isProcessingQueue { return hasEditedItems ? "處理中…" : "壓縮中…" }
        return hasEditedItems ? "開始剪輯／壓縮" : "開始壓縮"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("選擇影片") {
                    Button {
                        showBrowser = true
                    } label: {
                        if isImportingSelection {
                            HStack {
                                ProgressView()
                                Text("載入中…")
                            }
                        } else {
                            Label(queue.isEmpty ? "選取影片" : "加入更多影片", systemImage: "video.badge.plus")
                        }
                    }
                    .disabled(isImportingSelection || isProcessingQueue)
                }

                if !queue.isEmpty {
                    Section {
                        ForEach($queue) { $item in
                            QueueRowView(
                                item: $item,
                                isCurrent: item.id == currentProcessingID,
                                progress: compressor.progress,
                                canCompressAlone: !isProcessingQueue,
                                onCompressAlone: { [id = item.id] in
                                    Task { await processQueue(onlyItemID: id) }
                                },
                                onEdit: { [id = item.id] in
                                    Task { await openEditor(itemID: id) }
                                }
                            )
                        }
                        .onDelete(perform: removeItems)
                    } header: {
                        Text("壓縮佇列（\(queue.count)）")
                    } footer: {
                        if isPreparingEditor {
                            HStack {
                                ProgressView()
                                Text("準備剪輯…")
                            }
                        } else {
                            Text("點縮圖可單獨剪輯這一部：分割、裁剪、字幕、調色、動畫都在裡面。要和別的影片接在一起，用剪輯畫面裡的 ＋ 加入。剪輯只會記下設定不會馬上輸出，等全部調整完再按下方按鈕一次處理。三個壓縮選項都維持原始畫面（最高 1080p），只差在檔案大小與畫質的取捨。")
                        }
                    }

                    Section {
                        Picker("壓縮程度", selection: $preset) {
                            ForEach(CompressionPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.inline)
                        .disabled(isProcessingQueue)
                    }

                    Section {
                        Picker("時間資訊", selection: $dateMode) {
                            ForEach(DateMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .disabled(isProcessingQueue)
                    } footer: {
                        Text("決定壓縮後影片的拍攝日期。選「與原始影片相同」會保留原本的拍攝時間，在相簿中仍排在原來的位置；選「使用壓縮當下時間」則會排到相簿最新的地方。位置資訊一律保留。")
                    }

                    Section {
                        Button {
                            Task { await processQueue() }
                        } label: {
                            Text(startButtonTitle)
                        }
                        .disabled(isProcessingQueue || !hasPendingItems)
                    } footer: {
                        if hasEditedItems && !isProcessingQueue {
                            Text("有 \(editedItemCount) 部影片已設定剪輯，會在這一輪依序套用後壓縮。")
                        }
                    }

                    if !doneItems.isEmpty {
                        Section {
                            Button {
                                Task { await saveAllToPhotos() }
                            } label: {
                                if isSavingAll {
                                    HStack {
                                        ProgressView()
                                        Text("儲存中…")
                                    }
                                } else {
                                    Text("全部儲存到相簿")
                                }
                            }
                            .disabled(isSavingAll)

                            if let saveAllConfirmation {
                                Text(saveAllConfirmation).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("影片壓縮")
            .toolbar {
                if !queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode?.wrappedValue.isEditing == true ? "完成" : "編輯") {
                            withAnimation {
                                editMode?.wrappedValue = editMode?.wrappedValue.isEditing == true ? .inactive : .active
                            }
                        }
                    }
                }
            }
            .alert("錯誤", isPresented: .constant(errorMessage != nil), actions: {
                Button("確定") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .sheet(isPresented: $showBrowser) {
                VideoBrowserView { assets in
                    addToQueue(assets: assets)
                }
            }
            .fullScreenCover(item: $editorSession) { session in
                EditorScreen(
                    clips: session.clips,
                    existingTimeline: session.existingTimeline
                ) { timeline in
                    saveEdit(timeline, for: session.targetItemID, sourceURL: session.clips.first?.url)
                }
            }
            .onOpenURL { url in
                importSharedVideo(from: url)
            }
            .onAppear {
                checkInboxForPendingVideo()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkInboxForPendingVideo()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                checkInboxForPendingVideo()
            }
        }
    }

    private func removeItems(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
    }

    private func addToQueue(assets: [PHAsset]) {
        let existingIDs = Set(queue.compactMap { $0.asset?.localIdentifier })
        let newAssets = assets.filter { !existingIDs.contains($0.localIdentifier) }
        queue.append(contentsOf: newAssets.map { QueueItem(source: .asset($0)) })
    }

    private static let appGroupID = "group.com.weihsiangliao.VideoCompressor"

    private func importSharedVideo(from url: URL) {
        guard url.scheme == "videocompressor", url.host == "import" else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let fileName = components.queryItems?.first(where: { $0.name == "file" })?.value
        else { return }
        importFromInbox(fileName: fileName)
    }

    /// The Share Extension can't reliably force iOS to switch to this app after saving a
    /// shared video (extensionContext.open frequently reports failure when invoked from a
    /// system app's share sheet). As a fallback, check for anything the extension left
    /// behind every time this view becomes active, so the video is ready the moment the
    /// user manually switches back to the app.
    private func checkInboxForPendingVideo() {
        guard !isProcessingQueue else { return }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return }

        let inboxURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), !files.isEmpty else { return }

        for file in files.sorted(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) {
            importFromInbox(fileName: file.lastPathComponent)
        }
    }

    private func importFromInbox(fileName: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            errorMessage = "無法存取共享儲存空間"
            return
        }

        let sourceURL = containerURL.appendingPathComponent("Inbox").appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        do {
            let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: sourceURL, to: localURL)
            try? FileManager.default.removeItem(at: sourceURL)
            queue.append(QueueItem(source: .file(VideoFile(url: localURL))))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens the editor on the tapped clip alone.
    ///
    /// Each queued clip stays its own piece of work: they were queued to be compressed
    /// separately, and joining them the moment the editor opens would silently turn several
    /// videos into one. To combine clips deliberately, add them from inside the editor with
    /// its + button — which also puts a transition point between them.
    ///
    /// The clip has to be resolved to a local file first: TimelineKit reads off disk, and a
    /// PHAsset still in iCloud has no file until it has been downloaded — which is why this
    /// shows a spinner rather than opening instantly. A clip already edited reuses the file
    /// its timeline was built against, since a timeline refers to its clips by path.
    private func openEditor(itemID: UUID) async {
        guard let item = queue.first(where: { $0.id == itemID }) else { return }
        isPreparingEditor = true
        defer { isPreparingEditor = false }

        do {
            let url: URL
            if let existing = item.editedSourceURL,
               FileManager.default.fileExists(atPath: existing.path) {
                url = existing
            } else {
                switch item.source {
                case .asset(let asset):
                    url = try await VideoFile.from(asset: asset).url
                case .file(let video):
                    url = video.url
                }
            }
            editorSession = EditorSession(
                targetItemID: itemID,
                clips: [.init(url: url, shotAt: item.creationDate, location: item.location)],
                existingTimeline: item.editedTimeline
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Records the edit against its queue item without rendering anything.
    ///
    /// Encoding is deferred to the batch run so the user can line every clip up first
    /// rather than waiting through an export each time they leave the editor.
    private func saveEdit(_ timeline: EditorTimeline, for itemID: UUID, sourceURL: URL?) {
        guard let index = queue.firstIndex(where: { $0.id == itemID }) else { return }
        queue[index].editedTimeline = timeline
        queue[index].editedSourceURL = sourceURL
    }

    /// Compresses every pending item, or just one when `onlyItemID` is given.
    private func processQueue(onlyItemID: UUID? = nil) async {
        isProcessingQueue = true
        UIApplication.shared.isIdleTimerDisabled = true

        // Ask iOS for extra time to keep compressing if the user backgrounds the app or
        // locks the screen. This isn't unlimited — the OS still suspends us once the
        // grant runs out (typically well under a minute to a few minutes) — but it covers
        // most clips instead of stopping the instant the app leaves the foreground.
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoCompression") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }

        defer {
            isProcessingQueue = false
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        for index in queue.indices {
            guard queue[index].status == .pending else { continue }
            let itemID = queue[index].id
            if let onlyItemID, itemID != onlyItemID { continue }
            currentProcessingID = itemID

            queue[index].status = .loading
            let inputURL: URL
            do {
                switch queue[index].source {
                case .asset(let asset):
                    let video = try await VideoFile.from(asset: asset)
                    inputURL = video.url
                case .file(let video):
                    inputURL = video.url
                }
            } catch {
                queue[index].status = .failed
                queue[index].errorMessage = error.localizedDescription
                continue
            }

            queue[index].inputSizeText = FileSizeFormatter.string(for: inputURL)
            queue[index].inputResolution = await VideoMetadata.resolutionString(for: inputURL)
            queue[index].status = .compressing

            let timeRange: CMTimeRange? = queue[index].trimRange.map {
                CMTimeRange(
                    start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: $0.upperBound, preferredTimescale: 600)
                )
            }

            do {
                let result: URL
                if let timeline = queue[index].editedTimeline {
                    // An edited clip has to be rendered before it can be encoded. It still
                    // goes through the same compressor, so the bitrate ceiling and the
                    // creation-date handling apply exactly as they do to a plain file.
                    let built = try await CompositionBuilder().build(
                        from: timeline,
                        renderSubtitles: true
                    )
                    result = try await compressor.compress(
                        source: .composition(
                            built.composition,
                            videoComposition: built.videoComposition,
                            audioMix: built.audioMix,
                            // Date the edit by the clip it came from, not by the moment it
                            // was rendered. `.now` restamping still wins when chosen.
                            shotAt: dateMode == .now ? nil : queue[index].creationDate
                        ),
                        preset: preset,
                        dateMode: dateMode
                    )
                } else {
                    result = try await compressor.compress(
                        inputURL: inputURL,
                        preset: preset,
                        timeRange: timeRange,
                        dateMode: dateMode
                    )
                }
                queue[index].outputURL = result
                queue[index].outputSizeText = FileSizeFormatter.string(for: result)
                queue[index].outputResolution = await VideoMetadata.resolutionString(for: result)
                queue[index].outputCreationDate = dateMode == .now ? Date() : queue[index].creationDate
                queue[index].status = .done
            } catch {
                queue[index].status = .failed
                queue[index].errorMessage = error.localizedDescription
            }
        }

        currentProcessingID = nil
    }

    private func saveAllToPhotos() async {
        isSavingAll = true
        saveAllConfirmation = nil

        var successCount = 0
        var failureCount = 0
        for item in queue where item.status == .done {
            guard let url = item.outputURL else { continue }
            do {
                try await PhotoLibrarySaver.save(videoURL: url, creationDate: item.outputCreationDate, location: item.location)
                successCount += 1
            } catch {
                failureCount += 1
            }
        }

        isSavingAll = false
        if failureCount == 0 {
            saveAllConfirmation = "已儲存 \(successCount) 部影片到相簿"
        } else {
            saveAllConfirmation = "已儲存 \(successCount) 部，\(failureCount) 部失敗"
        }
    }
}

#Preview {
    ContentView()
}
