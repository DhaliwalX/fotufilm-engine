import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What a video develop looks like from the Lock Screen.
struct DevelopAttributes: Codable, Hashable {
    /// The film, named once.
    let stockName: String

    struct ContentState: Codable, Hashable {
        let frame: Int
        /// Not in the attributes, though it looks like it belongs there: the frame count is not
        /// known until the reader has opened the asset, and the activity goes up before that so the
        /// Lock Screen has something on it from the first moment.
        let totalFrames: Int
        /// 0…1.
        let fraction: Double
        /// True while the app is inactive and the Metal frame loop is parked.
        var isPaused = false
        /// Set once, at the end, so the activity's last frame appears as a
        /// finished thing rather than as 99%.
        var isFinished = false
    }
}

#if canImport(ActivityKit) && os(iOS)
extension DevelopAttributes: ActivityAttributes {}
#endif

/// The app's side: starts one activity per develop and ends it.
enum DevelopActivity {
    #if canImport(ActivityKit) && os(iOS)
    @available(iOS 16.2, *)
    private nonisolated(unsafe) static var current: Activity<DevelopAttributes>?

    /// The last update actually sent, and the frame count it carried.
    @MainActor private static var lastSent: Date = .distantPast
    @MainActor private static var lastFrames = 0
    @MainActor private static var lastFrame = 0
    @MainActor private static var lastFraction = 0.0
    @MainActor private static var isPaused = false

    @MainActor
    static func start(stockName: String) {
        guard #available(iOS 16.2, *),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        lastSent = .distantPast
        lastFrames = 0
        lastFrame = 0
        lastFraction = 0
        isPaused = false
        current = try? Activity.request(
            attributes: DevelopAttributes(stockName: stockName),
            content: .init(state: .init(frame: 0, totalFrames: 0, fraction: 0),
                           staleDate: nil))
    }

    @MainActor
    static func update(frame: Int, fraction: Double) {
        guard #available(iOS 16.2, *), let current else { return }
        if frame > lastFrames { lastFrames = frame }
        lastFrame = frame
        lastFraction = fraction
        let now = Date.now
        guard now.timeIntervalSince(lastSent) >= 2 else { return }
        lastSent = now
        let total = lastFrames
        Task {
            await current.update(.init(
                state: .init(frame: frame, totalFrames: total,
                             fraction: fraction, isPaused: isPaused),
                staleDate: now.addingTimeInterval(60)))
        }
    }

    @MainActor
    static func setPaused(_ paused: Bool) {
        guard #available(iOS 16.2, *), let current,
              isPaused != paused else { return }
        isPaused = paused
        let now = Date.now
        lastSent = now
        Task {
            await current.update(.init(
                state: .init(frame: lastFrame, totalFrames: lastFrames,
                             fraction: lastFraction, isPaused: paused),
                staleDate: paused ? nil : now.addingTimeInterval(60)))
        }
    }

    @MainActor
    static func note(totalFrames: Int) {
        lastFrames = max(lastFrames, totalFrames)
    }

    @MainActor
    static func finish(succeeded: Bool) {
        guard #available(iOS 16.2, *), let activity = current else { return }
        self.current = nil
        let total = lastFrames
        Task {
            await activity.end(
                .init(state: .init(frame: total, totalFrames: total,
                                   fraction: succeeded ? 1 : 0,
                                   isFinished: true),
                      staleDate: nil),
                dismissalPolicy: succeeded ? .after(.now + 8) : .immediate)
        }
    }

    @MainActor
    static func end() {
        guard #available(iOS 16.2, *), let activity = current else { return }
        self.current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    #else
    @MainActor static func start(stockName: String) {}
    @MainActor static func update(frame: Int, fraction: Double) {}
    @MainActor static func setPaused(_ paused: Bool) {}
    @MainActor static func note(totalFrames: Int) {}
    @MainActor static func finish(succeeded: Bool) {}
    @MainActor static func end() {}
    #endif
}
