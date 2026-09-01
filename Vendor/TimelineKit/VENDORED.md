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

7. `Sources/TimelineKitUIiOS/Views/EditorBottomToolbar.swift` — the 轉場 and 調節 secondary
   panels rendered an inert icon of the category, and 動畫 fell through to `EmptyView()`, so
   with nothing selected the panel opened blank. All three now say where the tool actually
   lives (select a segment; tap the badge between two clips).

8. `Sources/TimelineKitRender/Rendering/CompositionBuilder.swift` — transitions could not
   be exported **at all**. Two separate faults:

   *Invalid instructions.* Each segment's body instruction spanned its whole duration and
   a transition instruction was appended straddling the boundary, so the three overlapped:

       0.00..4.00 [A]      3.75..4.25 [A,B]      4.00..7.00 [B]

   `AVVideoComposition` requires disjoint, ascending instructions, so the entire
   composition was rejected with `AVErrorInvalidVideoComposition` (-11841). The bodies are
   now trimmed back to hand the window to the transition.

   *Nothing to blend.* Each segment was inserted for exactly its own duration, so the two
   clips never coexist and a cross-fade had no second image. Upstream's own comments call
   this path "best-effort only" and say it "shows a hard cut" — the blending lives in the
   preview runtime, not in what gets exported.

   Fixed by widening each side of the boundary into footage outside its in/out points
   (`spareHead` / `spareTail`), which is the only source of overlap that does not shift the
   timeline — `buildAudio` inserts main-track audio at raw `targetRange.start`, so
   compressing the video timeline (the usual way to do transitions) would desynchronise
   audio. Consequence worth knowing: **a transition needs trimmed clips.** Two untrimmed
   clips have no spare footage, so the window collapses to zero and the join degrades to a
   hard cut rather than dissolving against black.

9. Source rotation is applied wherever frames are rendered by hand. New file
   `Sources/TimelineKitRender/Rendering/SourceOrientation.swift`, used from
   `VideoFrameProvider.frame(for:at:)` and `UnifiedCompositor.startRequest`, with the
   orientation carried on `UnifiedCompositorInstruction` and populated by
   `CompositionBuilder`.

   A track's rotation lives in `preferredTransform`, not in its frames — phone portrait
   footage is stored landscape and flagged to be turned 90°. Only the AVFoundation
   layer-instruction path applies that for you, which is the path used for an export with
   no effects. The live preview (`VideoLayerComposer` → `VideoFrameProvider`) and the
   effects path (`UnifiedCompositor`, via `request.sourceFrame(byTrackID:)`) both receive
   frames as stored and fitted them to the canvas sideways, so a portrait clip showed as a
   cropped middle strip of a rotated picture.

   The rotation must **not** be multiplied into a `CIImage` directly: `preferredTransform`
   is expressed in a top-left origin space and Core Image uses bottom-left, so the matrix
   turns the picture the wrong way or mirrors it. Map to `CGImagePropertyOrientation` and
   use `CIImage.oriented(_:)`, which is defined in display terms; then re-anchor the extent
   to the origin, since `fitTransform` reads only its width and height.

   In a transition the two clips alternate between trackA and trackB, so foreground and
   background orientations follow the same even/odd rule as `fgAdj` / `bgAdj`.

   **`VideoFrameProviderProtocol` has two implementations**, and they are used by different
   screens: `ExportFrameProvider` (an `AVAssetReaderTrackOutput`) and `PreviewFrameProvider`
   (an `AVPlayerItemVideoOutput`, installed by `CompositionCoordinator` — this is what the
   editor shows). Patching and testing only the first one produced a green suite while the
   preview stayed broken on device. Anything touching frame content must change both.

10. `Sources/TimelineKitUIShared/EditorStore.swift` — `addVisualSegment` inserts after the
    clip under the playhead instead of appending to the end of the main track, rippling
    later segments along, and drops any transition whose join the insertion splits.

    The playhead then follows the new clip. Without that, adding several clips in a row
    puts each one after the *same* earlier clip, so they end up in reverse order — and the
    user never sees what they just added.

11. `Sources/TimelineKitCore/TimelineDocument.swift` — added `updateMaterialURL`, which
    repoints a material at a different file **without** pushing an undo entry. Swapping a
    placeholder for the full-quality copy of the same footage is not a user edit; recording
    it would let undo step back to the lower-quality file and would push real edits out of
    the bounded undo history.

12. `Sources/TimelineKitUIiOS/Views/ClipEditorView.swift` and `SegmentReplacePanel.swift` —
    adding a clip paid for the whole file twice: `loadTransferable` had PhotosUI export the
    asset, and `VideoTransferable` then copied that export. Now Photos is asked for its
    fastest available version (`deliveryMode: .fastFormat`), the clip goes on the timeline
    immediately, and the full-quality copy is fetched behind it and swapped in via #11.

    The quick URL belongs to Photos and is only dependable while its request is alive, so a
    copy this app owns is still made — just not while the user waits. The remaining
    `VideoTransferable` path (used when there is no `itemIdentifier`) now moves rather than
    copies where it can, which is instant when PhotosUI staged the file in this app's own
    container.

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
