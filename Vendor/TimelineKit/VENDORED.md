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

3. Simplified Chinese UI strings → Traditional Chinese (Taiwan), 364 strings across 35
   files. Converted mechanically with `opencc -c s2twp`, applied to **string literals
   only** — comments are left in Simplified on purpose, so the diff against upstream stays
   readable and future merges remain tractable.

   `s2twp` mistranslates several terms in this context; these were corrected by hand and
   must be re-checked after any upstream merge:

   | s2twp produced | corrected to | why |
   |---|---|---|
   | 引數 | 參數 | 引數 is "argument"; the string means "parameters" |
   | 型別 | 類型 | 型別 is a programming data type, not a UI category |
   | 分離音影片 | 分離音訊 | 音视频 became nonsense word-by-word |
   | 應用 | 套用 | 應用 reads as "application"; "apply" is 套用 |
   | 文本 | 文字 | mainland term |
   | 幀率 | 影格率 | mainland term |

   To redo after a merge: `../../scripts/to_traditional.py Vendor/TimelineKit/Sources`
   (needs `brew install opencc`), then re-apply the table above.

4. `Sources/TimelineKitUIiOS/Views/ClipEditorView.swift`
   Added an optional `onRequestExport: ((EditorTimeline) -> Void)?`. Upstream's export
   button pushes `ExportResultView`, which encodes through `VideoExporter`; this app needs
   the *timeline* back so it can render it through its own reader/writer pipeline and keep
   the bitrate ceiling and creation-date handling. Falls through to upstream behaviour when
   the closure is nil.

5. Timeline zoom down to a single frame. Four separate limits each capped precision, and
   raising only some of them would have changed nothing:

   | File | Was | Now |
   |---|---|---|
   | `TrackCanvasView.maxPixelsPerSecond` | 600 | 4000 |
   | `TimelineTrackLayout.defaultMaxPPS` (mirrors it) | 600 | 4000 |
   | `RulerView.tickInterval` finest tick | 0.1s | one frame (`1/canvas.fps`) |
   | `freeDragSnap` threshold floor | 0.1s | 0.002s |
   | segment `minDuration` | 0.2s | 0.034s (~1 frame) |

   Zoom-**out** was capped the same way: `minPixelsPerSecond` / `defaultMinPPS` of 20 pt/s
   made a 10-minute clip 12,000 pt wide, and since `fittedPPS` clamps to that same floor,
   a long clip could not be fitted on open either. Both are now 0.1 pt/s — an hour of
   footage on one screen — with the ruler's ladder extended to 120/300/600/1800/3600s and
   labels switching to `h:mm:ss` past an hour.

   `configure` used to detect "not configured yet" by comparing `currentPixelsPerSecond`
   against `minPixelsPerSecond`. That is a zoom level the user can now actually reach, at
   which point reconfiguring would yank their view back to the fitted zoom, so it was
   replaced with an explicit `hasChosenInitialZoom` flag.

   `RulerView` now takes `fps` in `configure` so ticks land on real frame boundaries. The
   candidate list mixes frame multiples with the seconds ladder and is **sorted**, since
   the two interleave differently per frame rate; `0.1` stays in the ladder so no frame
   rate loses resolution anywhere. Tick labels gained adaptive decimals — a fixed one
   decimal repeats itself below 0.1s.

6. `Sources/TimelineKitUIiOS/Views/ClipEditorViewController.swift` — pinch zoom anchors on
   the playhead instead of the midpoint between the fingers. This timeline pins the
   playhead to screen centre and scrubs by scrolling underneath it (the `剪映` paradigm its
   own comments describe), so anchoring anywhere else leaves screen centre — and the
   previewed frame — on a different time after the pinch.

   Upstream's anchor was also miscomputed: `location(in: scrollView)` is already in content
   coordinates, because a scroll view's `bounds.origin` *is* its `contentOffset`. Adding
   `contentOffset.x` to it counted the scroll position twice, so the anchor drifted further
   the further along the timeline the user had scrolled.

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
