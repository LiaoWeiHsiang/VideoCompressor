# VideoCompressor

An iOS app that shrinks videos before you archive or upload them, without silently
degrading what makes the file worth keeping — its shooting date, its GPS location, or its
resolution.

Built for a specific workflow: action-camera footage lands in Photos, gets compressed on
the phone, and goes up to a self-hosted [Immich](https://immich.app) server. The UI is in
Traditional Chinese.

## What it does

- **Picks videos from your library** with a date-grouped grid, or sorted largest-first so
  the clips actually costing you storage are easy to find. Long-press previews a clip.
- **Queues several videos** and compresses them one after another, with per-item progress
  and a "compress just this one" action.
- **Trims** each clip with a two-handle slider that scrubs the preview as you drag.
- **Re-encodes to HEVC** at one of three quality levels, capped at 1080p.
- **Saves back to Photos** or shares out, keeping the original shooting date and location.
- **Accepts videos from the share sheet** of other apps.

## Why the output is actually smaller

Two decisions do most of the work, both of which came from fixing real bugs:

**The bitrate ceiling follows the source.** `AVAssetExportSession`'s built-in presets
target a fixed bitrate regardless of the input, so compressing an already-efficient clip
can produce a *larger* file than the original. Instead the target is
`min(preset bitrate, source bitrate × 0.85)`, so the output is always meaningfully smaller
than what went in.

**The cap is enforced, not suggested.** `AVVideoAverageBitRateKey` alone is a soft target
that the encoder overshoots on complex footage. `kVTCompressionPropertyKey_DataRateLimits`
sets a hard ceiling that it cannot exceed.

Encoding runs through `AVAssetReader`/`AVAssetWriter` rather than `AVAssetExportSession`,
which is what makes that level of control possible.

## Preserving dates and location

A compressed copy keeps the original clip's creation date and GPS coordinates, so it stays
in the right place on a timeline instead of jumping to "today".

This is less automatic than it sounds. Cameras disagree about where the shooting time
lives: iPhone footage carries a `com.apple.quicktime.creationdate` metadata item, while
some action cameras (Insta360 among them) record it *only* in the movie header — and
`AVAssetWriter` always stamps that header with the time of encoding. Copying the source's
metadata items is therefore not enough; the date is read via `AVAsset.creationDate`, which
resolves both, and then written explicitly.

Output files are named after when the footage was shot, e.g. `202608151140_compressed.mp4`.

A setting chooses whether the copy keeps the original date or is stamped with the current
time. Location is preserved either way.

## Requirements

- iOS 18+ device (iPhone), Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An Apple Developer account. A free one works; see the caveat below.

## Building

The Xcode project is generated from `project.yml` and is not committed.

```sh
cp .env.example .env      # then put your Apple Team ID in it
./scripts/build.sh            # build
./scripts/build.sh --install  # build, install and launch on a connected iPhone
./scripts/build.sh --test     # run the test suite on the device
```

`DEVELOPMENT_TEAM` is read from the environment so that no personal Team ID is committed.

> **Free-account caveat:** apps signed with a free Apple developer account stop launching
> after 7 days and must be reinstalled — that is Apple's limit on free provisioning, not
> something the app can work around. `./scripts/build.sh --install` makes that a
> one-command chore. A paid account raises it to a year.

## Tests

The suite runs on a physical device (it exercises the hardware video encoder) and covers
the behaviours that regressed before: that output is smaller than input, that the bitrate
ceiling is honoured, that trim ranges apply, and that dates and location survive — including
the case where the source has no date metadata item at all.

```sh
./scripts/build.sh --test
```

`MetadataDiagnosticTests` is a diagnostic rather than an assertion suite: it surveys videos
in the library and prints what metadata each actually carries, which is how the date
handling above was worked out. It skips cleanly without photo access.

## Layout

```
Sources/            app code
  VideoCompressor.swift    the encoder — bitrate policy and the reader/writer pipeline
  VideoBrowserView.swift   library picker (date grouping, size sort, peek preview)
  QueueRowView.swift       one row of the compression queue
ShareExtension/     receives videos shared from other apps
Tests/              device tests + synthetic fixture generator
scripts/build.sh    generate, build, install
```

## License

MIT — see [LICENSE](LICENSE).
