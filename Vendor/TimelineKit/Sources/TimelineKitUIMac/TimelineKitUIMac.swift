import Foundation
import SwiftUI
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
import TimelineKitUISharedViews

// MARK: - TimelineKitUIMac
//
// V8：macOS 编辑器壳（M7 正式交付）。
//
// 包含：
//   - ClipEditorView          — FCP 式四区编辑器壳（工具栏 + Browser/Viewer/
//                                Inspector + Timeline，NSSplitView 可拖拽分割）
//   - MacEditorShellView      — AppKit 根容器（垂直分割）
//   - MacEditorTopAreaView    — 上部水平三区（Browser | Viewer | Inspector）
//   - MacBrowserPanelView     — 素材区占位
//   - MacInspectorPanelView   — 检查器占位
//   - MacTimelineCanvasView   — AppKit 时间线画布（滚动/选中/scrub/缩放）
//   - MacTimelineCanvasHost   — 标签侧栏 + 滚动视图组合，SwiftUI 桥接
//   - MacTrackLabelSidebar    — 轨道标签侧栏（锁定/隐藏/静音开关）
//
// 顶部导航：标题 + 导入/导出按钮由 ClipEditorView 的 .toolbar 挂到系统
// unified titlebar（宿主设置 .windowToolbarStyle(.unified)）。

public let timelineKitUIMacVersion = "8.2.0"
