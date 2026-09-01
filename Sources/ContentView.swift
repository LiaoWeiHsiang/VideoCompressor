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
    @State private var settings = CompressionSettings()
    @State private var targetSizeMB: Double = 25
    @State private var useTargetSize = false
    @State private var dateMode: DateMode = .now
    @State private var errorMessage: String?
    @State private var isProcessingQueue = false
    @State private var currentProcessingID: UUID?
    @State private var isImportingSelection = false
    @State private var isSavingAll = false
    @State private var saveAllConfirmation: String?
    @State private var isPreparingEditor = false
    @State private var editorSession: EditorSession?
    @State private var hasRestoredQueue = false
    @State private var showImmichSettings = false
    @State private var uploadToImmich = false
    @State private var isUploading = false
    @State private var uploadSummary: String?

    @StateObject private var compressor = VideoCompressor()

    private var doneItems: [QueueItem] { queue.filter { $0.status == .done } }
    private var hasPendingItems: Bool { queue.contains { $0.status == .pending } }
    private var editedItemCount: Int {
        queue.filter { $0.status == .pending && $0.editedTimeline != nil }.count
    }
    private var hasEditedItems: Bool { editedItemCount > 0 }

    /// The settings as chosen, with the target-size toggle folded in. Kept separate from
    /// `settings` so switching the toggle off restores the preset the user had picked
    /// rather than discarding it.
    private var effectiveSettings: CompressionSettings {
        var resolved = settings
        if useTargetSize { resolved.quality = .targetSize(megabytes: targetSizeMB) }
        return resolved
    }

    private var presetBinding: Binding<CompressionPreset> {
        Binding(
            get: {
                if case .preset(let preset) = settings.quality { return preset }
                return .medium
            },
            set: { settings.quality = .preset($0) }
        )
    }

    /// Total predicted output for everything still queued, so the effect of a setting is
    /// visible before committing to a run that takes minutes.
    private var estimateSummary: String? {
        let pending = queue.filter { $0.status == .pending }
        guard !pending.isEmpty else { return nil }

        var total: Int64 = 0
        var limited = false
        var known = 0
        for item in pending {
            guard let duration = item.sourceDurationSeconds,
                  let bitrate = item.sourceBitrate,
                  let estimate = CompressionEstimator.estimate(
                    settings: effectiveSettings, durationSeconds: duration, sourceBitrate: bitrate)
            else { continue }
            total += estimate.bytes
            limited = limited || estimate.limitedBySource
            known += 1
        }
        guard known > 0 else { return nil }

        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let scope = known == pending.count ? "" : "（\(known)/\(pending.count) 部）"
        let caveat = limited ? "。部分影片受原始畫質限制，設定再高也不會更大" : ""
        return "預估輸出約 \(size)\(scope)\(caveat)"
    }

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
                    .accessibilityIdentifier("selectVideos")
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
                        Toggle("指定檔案大小", isOn: $useTargetSize)
                            .disabled(isProcessingQueue)

                        if useTargetSize {
                            HStack {
                                Text("目標大小")
                                Spacer()
                                Text("\(Int(targetSizeMB)) MB").foregroundStyle(.secondary)
                            }
                            Slider(value: $targetSizeMB, in: 5...500, step: 5)
                                .disabled(isProcessingQueue)
                        } else {
                            Picker("壓縮程度", selection: presetBinding) {
                                ForEach(CompressionPreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .pickerStyle(.inline)
                            .disabled(isProcessingQueue)
                        }
                    } header: {
                        Text("畫質")
                    } footer: {
                        if let summary = estimateSummary {
                            Text(summary)
                        }
                    }

                    Section("尺寸與影格") {
                        Picker("解析度上限", selection: $settings.resolution) {
                            ForEach(CompressionSettings.Resolution.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .disabled(isProcessingQueue)

                        Picker("影格率上限", selection: $settings.frameRateCap) {
                            ForEach(CompressionSettings.FrameRateCap.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .disabled(isProcessingQueue)

                        Toggle("保留聲音", isOn: $settings.includeAudio)
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
                        .accessibilityIdentifier("startProcessing")
                        .disabled(isProcessingQueue || !hasPendingItems)
                    } footer: {
                        if hasEditedItems && !isProcessingQueue {
                            Text("有 \(editedItemCount) 部影片已設定剪輯，會在這一輪依序套用後壓縮。")
                        }
                    }

                    Section {
                        Toggle("壓縮後上傳 Immich", isOn: $uploadToImmich)
                            .disabled(isProcessingQueue || !ImmichCredentialStore.isConfigured)
                        Button("Immich 伺服器設定…") { showImmichSettings = true }
                            .disabled(isProcessingQueue)
                    } header: {
                        Text("上傳")
                    } footer: {
                        Text(ImmichCredentialStore.isConfigured
                             ? "上傳時會沿用影片的拍攝日期，在 Immich 的時間軸上排在正確的位置。"
                             : "尚未設定伺服器。先填好網址與 API 金鑰才能開啟上傳。")
                    }

                    if !doneItems.isEmpty {
                        Section {
                            Button {
                                Task { await uploadAllToImmich() }
                            } label: {
                                if isUploading {
                                    HStack { ProgressView(); Text("上傳中…") }
                                } else {
                                    Text("全部上傳到 Immich")
                                }
                            }
                            .disabled(isUploading || !ImmichCredentialStore.isConfigured)

                            if let uploadSummary {
                                Text(uploadSummary).foregroundStyle(.secondary).font(.callout)
                            }
                        }

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
                            .accessibilityIdentifier("saveAllToPhotos")
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
            .sheet(isPresented: $showImmichSettings) {
                ImmichSettingsView()
            }
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
                restoreQueueIfNeeded()
                checkInboxForPendingVideo()
            }
            // Persist on every queue change rather than only on background: iOS can
            // terminate a suspended app without warning, and the whole point of saving an
            // edit instead of rendering it is that it survives until the user is ready.
            .onChange(of: queue) { _, updated in
                guard !isProcessingQueue else { return }
                QueueStore.save(updated)
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

    /// Restores the pending queue saved by a previous launch.
    ///
    /// Guarded so returning from the share sheet or the editor — both of which re-run
    /// `onAppear` — cannot duplicate what is already on screen.
    private func restoreQueueIfNeeded() {
        guard !hasRestoredQueue else { return }
        hasRestoredQueue = true

        // UI tests need a known starting point; the queue is otherwise carried over from
        // whatever the previous test left behind.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-queue") {
            QueueStore.save([])
            return
        }
        let restored = QueueStore.load()
        guard !restored.isEmpty else { return }
        let existing = Set(queue.map(\.id))
        queue.append(contentsOf: restored.filter { !existing.contains($0.id) })
    }

    private func addToQueue(assets: [PHAsset]) {
        let existingIDs = Set(queue.compactMap { $0.asset?.localIdentifier })
        let newAssets = assets.filter { !existingIDs.contains($0.localIdentifier) }
        let added = newAssets.map { QueueItem(source: .asset($0)) }
        queue.append(contentsOf: added)

        // Duration and bitrate drive the size estimate. PHAsset knows the duration
        // immediately; the bitrate needs the file, so it is filled in behind the scenes and
        // the estimate simply appears once it lands.
        for (item, asset) in zip(added, newAssets) {
            Task { await loadSourceStats(itemID: item.id, asset: asset) }
        }
    }

    /// Reads what the estimate needs without blocking the list.
    ///
    /// Estimating from `PHAsset` alone is not possible: it reports pixel dimensions and
    /// duration but not bitrate, and bitrate is what decides the output size.
    private func loadSourceStats(itemID: UUID, asset: PHAsset) async {
        guard let video = try? await VideoFile.from(asset: asset),
              let stats = await VideoMetadata.stats(for: video.url)
        else { return }
        try? FileManager.default.removeItem(at: video.url)

        if let index = queue.firstIndex(where: { $0.id == itemID }) {
            queue[index].sourceDurationSeconds = stats.durationSeconds
            queue[index].sourceBitrate = stats.bitrate
        }
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
            let item = QueueItem(source: .file(VideoFile(url: localURL)))
            queue.append(item)
            Task {
                guard let stats = await VideoMetadata.stats(for: localURL),
                      let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
                queue[index].sourceDurationSeconds = stats.durationSeconds
                queue[index].sourceBitrate = stats.bitrate
            }
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
            var itemTimer = StageTimer("queueItem")
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

            itemTimer.mark("fetchSource")
            queue[index].inputSizeText = FileSizeFormatter.string(for: inputURL)
            queue[index].inputResolution = await VideoMetadata.resolutionString(for: inputURL)
            itemTimer.mark("inspect")
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
                    itemTimer.mark("buildComposition")
                    result = try await compressor.compress(
                        source: .composition(
                            built.composition,
                            videoComposition: built.videoComposition,
                            audioMix: built.audioMix,
                            // Date the edit by the clip it came from, not by the moment it
                            // was rendered. `.now` restamping still wins when chosen.
                            shotAt: dateMode == .now ? nil : queue[index].creationDate
                        ),
                        settings: effectiveSettings,
                        dateMode: dateMode
                    )
                } else {
                    result = try await compressor.compress(
                        source: .file(inputURL, timeRange: timeRange),
                        settings: effectiveSettings,
                        dateMode: dateMode
                    )
                }
                itemTimer.mark("compress")
                if uploadToImmich, let credentials = ImmichCredentialStore.credentials {
                    // Uploading as each clip lands rather than at the end means a long run
                    // is already partly on the server if it is interrupted.
                    let client = ImmichClient(credentials: credentials)
                    do {
                        _ = try await client.upload(
                            fileURL: result,
                            createdAt: dateMode == .now ? Date() : (queue[index].creationDate ?? Date()),
                            filename: result.lastPathComponent
                        )
                    } catch {
                        queue[index].errorMessage = "上傳失敗：\(error.localizedDescription)"
                    }
                }
                itemTimer.report(extra: ["edited": queue[index].editedTimeline != nil ? "yes" : "no"])
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

    /// Uploads every finished clip.
    ///
    /// Each is dated by its own shooting time rather than by now, so Immich files it on the
    /// day it was filmed. Failures are counted rather than aborting the run: one clip the
    /// server rejects should not strand the rest.
    private func uploadAllToImmich() async {
        guard let credentials = ImmichCredentialStore.credentials else {
            errorMessage = "尚未設定 Immich 伺服器"
            return
        }
        isUploading = true
        uploadSummary = nil
        defer { isUploading = false }

        let client = ImmichClient(credentials: credentials)
        var uploaded = 0
        var duplicates = 0
        var failures: [String] = []

        for item in queue where item.status == .done {
            guard let url = item.outputURL else { continue }
            do {
                let outcome = try await client.upload(
                    fileURL: url,
                    createdAt: item.outputCreationDate ?? item.creationDate ?? Date(),
                    filename: url.lastPathComponent
                )
                switch outcome {
                case .created:   uploaded += 1
                case .duplicate: duplicates += 1
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        var parts: [String] = []
        if uploaded > 0 { parts.append("已上傳 \(uploaded) 部") }
        if duplicates > 0 { parts.append("\(duplicates) 部伺服器已有") }
        if !failures.isEmpty { parts.append("\(failures.count) 部失敗") }
        uploadSummary = parts.isEmpty ? "沒有可上傳的影片" : parts.joined(separator: "，")
        if let first = failures.first { errorMessage = first }
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
