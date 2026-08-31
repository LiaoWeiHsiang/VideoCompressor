#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitRender

/// V5 export-config-panel-spec §5.2：导出参数配置面板。
///
/// UI 沿用 `TTSConfigSheet` 风格（NavigationStack + Form + Section + segmented Picker）。
/// 4 个参数：分辨率 / 帧率 / 码率（三档）/ 智能 HDR。
///
/// 任一字段变更即时调 `store.mutateExportConfig` → 实时持久化（DraftStore.save 同步落盘）；
/// "完成"按钮仅 dismiss，不二次落盘。
struct ExportConfigSheet: View {

    let store: EditorStore
    var onDismiss: () -> Void

    /// 临时编辑态。`onAppear` 时由 `store.timeline.effectiveExportConfig` 初始化
    /// （新工程/旧草稿走 `default(for: canvas)` 派生；已设置过的工程走持久化值）。
    @State private var cfg: ExportConfig = .factoryDefault

    var body: some View {
        NavigationStack {
            Form {
                Section("解析度") {
                    Picker("解析度", selection: $cfg.resolution) {
                        ForEach(ExportConfig.Resolution.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.resolution) { _, new in
                        store.mutateExportConfig { $0.resolution = new }
                    }
                }

                Section("影格率") {
                    Picker("影格率", selection: $cfg.fps) {
                        ForEach(ExportConfig.FrameRate.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.fps) { _, new in
                        store.mutateExportConfig { $0.fps = new }
                    }
                }

                Section("位元速率") {
                    Picker("位元速率", selection: $cfg.bitrateTier) {
                        ForEach(ExportConfig.BitrateTier.allCases, id: \.self) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.bitrateTier) { _, new in
                        store.mutateExportConfig { $0.bitrateTier = new }
                    }
                }

                Section("高階") {
                    Toggle("智慧 HDR", isOn: $cfg.hdrEnabled)
                        .disabled(!isHDRAvailable)
                        .onChange(of: cfg.hdrEnabled) { _, new in
                            store.mutateExportConfig { $0.hdrEnabled = new }
                        }

                    Text(hdrFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("恢復預設", role: .destructive) {
                        store.resetExportConfigToDefault()
                        cfg = store.timeline.effectiveExportConfig    // 重新按 canvas 派生
                    }
                }

                Section("說明") {
                    Text("預設跟隨當前畫布尺寸與影格率自動匹配最接近檔位；可手動選擇更高/更低解析度。匯出配置隨工程儲存，下次開啟繼續沿用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("匯出規格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                cfg = store.timeline.effectiveExportConfig
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - HDR 能力检测（详见 render-pipeline-unification-spec.md §7 / §5）

    /// M3 阶段始终 false（HDR Toggle 禁用，文案显示"即将上线"）。
    /// M4 阶段切换为真实设备能力检测（参考 VideoExporter.canEncodeHDR）。
    private var isHDRAvailable: Bool {
        ExportEncodingProfile.canEncodeHDR()
    }

    private var hdrFootnote: String {
        if isHDRAvailable {
            return "開啟後自動依據原素材色彩動態轉譯生成 HDR 畫質影片"
        }
        return "智慧 HDR 即將上線"
    }
}

#endif
