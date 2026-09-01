import Foundation
import os

/// Records how long each stage of a run took.
///
/// Written because "compressing feels slow" is not something you can act on: the time
/// could be going to fetching the clip out of Photos, to setting up the reader, or to the
/// encode itself, and those have completely different fixes. Guessing wrong means
/// optimising something that was never the bottleneck.
///
/// Cheap enough to leave on in release builds — a handful of `Date()` reads per clip —
/// and the log is the only way to see where time goes on a real clip on a real phone.
struct StageTimer {
    private let label: String
    private let started = Date()
    private var marks: [(stage: String, at: Date)] = []

    init(_ label: String) {
        self.label = label
    }

    mutating func mark(_ stage: String) {
        marks.append((stage, Date()))
    }

    /// Emits one line per stage plus a total, as elapsed seconds and as a share of the run.
    func report(extra: [String: String] = [:]) {
        let total = Date().timeIntervalSince(started)
        guard total > 0 else { return }

        var previous = started
        var lines: [String] = []
        for mark in marks {
            let elapsed = mark.at.timeIntervalSince(previous)
            lines.append(String(format: "%@=%.2fs(%.0f%%)", mark.stage, elapsed, elapsed / total * 100))
            previous = mark.at
        }
        let suffix = extra.isEmpty ? "" : " " + extra.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")

        Logger(subsystem: "com.weihsiangliao.VideoCompressor", category: "timing")
            .info("TIMING \(label, privacy: .public) total=\(String(format: "%.2f", total), privacy: .public)s \(lines.joined(separator: " "), privacy: .public)\(suffix, privacy: .public)")
        print("TIMING \(label) total=\(String(format: "%.2f", total))s \(lines.joined(separator: " "))\(suffix)")
    }
}
