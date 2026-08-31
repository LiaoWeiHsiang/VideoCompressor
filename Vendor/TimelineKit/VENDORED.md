# Vendored TimelineKit

Upstream: https://github.com/tuxi/TimelineKit  (MIT)
Vendored from commit: 5c5f77578087866e2c00d6b9f74f160c26e798c8
Vendored on: 2026-08-31

## Why vendored instead of an SPM dependency

The full editor UI is only reachable through `ClipEditorView`; every feature panel
(`TextEditPanel`, `ColorAdjustmentPanel`, `TransitionEditSheet`, `AnimationPickerSheet`,
`EditorBottomToolbar`) is `internal`, so the feature set cannot be composed from outside
the package. Using it therefore means accepting its export path, which we must change.

## Local patches (keep this list current — it is the merge checklist)

1. `Sources/TimelineKitRender/Rendering/ExportEncodingProfile.swift`
   Upstream encodes 1080p and below as **H.264** with only `AVVideoAverageBitRateKey`
   (5–12 Mbps) and no hard cap, so output can exceed the source. Replaced with HEVC +
   source-adaptive ceiling + `kVTCompressionPropertyKey_DataRateLimits`, matching
   VideoCompressor's engine.

2. `Sources/TimelineKitUIiOS/Views/ExportResultView.swift`
   Upstream unconditionally calls `saveToPhotoLibrary` before handing the file back.
   Removed so the host app decides the destination (Photos / Immich / both).

3. Simplified Chinese UI strings → Traditional Chinese.

4. `Sources/TimelineKitUIiOS/Views/ClipEditorView.swift`
   Added an optional `onRequestExport: ((EditorTimeline) -> Void)?`. Upstream's export
   button pushes `ExportResultView`, which encodes through `VideoExporter`; this app needs
   the *timeline* back so it can render it through its own reader/writer pipeline and keep
   the bitrate ceiling and creation-date handling. Falls through to upstream behaviour when
   the closure is nil.

## Gotchas found while integrating (not patches — call sites must handle these)

- **Canvas presets are all 720-based** (`EditorCanvas.Preset` → 1280×720 etc.), so
  `CompositionBuilder.build(from:)` without an explicit `renderSize` exports 720p. Pass
  `renderSize` — `EditorScreen.exportShortSide` does. Covered by
  `testEditedOutputStaysAt1080p`.
- **`renderSubtitles` defaults to `false`**, because during live preview the SwiftUI
  overlays are the source of truth. Exporting without it silently drops every subtitle and
  text segment the user added.
- **`animationTool` and `customVideoCompositorClass` are mutually exclusive**, and
  `animationTool` only works with `AVAssetExportSession` — it cannot be read through
  `AVAssetReaderVideoCompositionOutput`. `CompositionBuilder` already routes around this
  by forcing the unified-compositor path whenever there are overlay segments, so the
  reader path stays usable. Worth re-checking after any upstream merge.

## Updating from upstream

    git clone https://github.com/tuxi/TimelineKit /tmp/tlk
    cd /tmp/tlk && git diff 5c5f77578087866e2c00d6b9f74f160c26e798c8..HEAD -- Sources/ > /tmp/tlk.patch
    # re-apply the three patches above by hand after merging
