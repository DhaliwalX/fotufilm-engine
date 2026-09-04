import Foundation

/// Where a frame's time went, for the phone.
///
/// The Halide kernels are parallel and the Swift that wraps them is not, so a stage's share of a
/// frame is not something the total can be reasoned back to — the answer has to be measured at
/// the boundary. `FOTUFILM_STAGE_TIMING=1` makes each `processDisplayP38` print its own breakdown;
/// unset — every shipping run — the calls fold away to nothing.
///
/// Deliberately cheap rather than precise: one clock read per stage, printed on the thread that
/// did the work, no accumulation across frames.
public struct StageTiming {
    public static let isEnabled =
        ProcessInfo.processInfo.environment["FOTUFILM_STAGE_TIMING"] == "1"

    private var start = DispatchTime.now()
    private var marks: [(String, Double)] = []

    public init() {}

    /// Closes the stage that ended here and opens the next.
    public mutating func mark(_ name: String) {
        guard Self.isEnabled else { return }
        let now = DispatchTime.now()
        let ms = Double(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        marks.append((name, ms))
        start = now
    }

    public func report(_ label: String) {
        guard Self.isEnabled else { return }
        let total = marks.reduce(0) { $0 + $1.1 }
        var line = "[fotufilm] \(label) \(String(format: "%.1f", total)) ms:"
        for (name, ms) in marks {
            line += String(format: " %@ %.1f (%.0f%%)", name, ms,
                           total > 0 ? ms / total * 100 : 0)
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
