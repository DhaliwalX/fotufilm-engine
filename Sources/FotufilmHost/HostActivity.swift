import Foundation

/// Keeps the process at full speed through a long export. A host whose window is in the
/// background, or whose screen locks, is otherwise napped by the system: timers coalesce, its
/// threads drop to the efficiency cores, and a movie export measured three to four times slower
/// in every stage, CPU and GPU alike.
enum HostActivity {
    static func during<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                             reason: reason)
        defer { ProcessInfo.processInfo.endActivity(activity) }
        #endif
        return try body()
    }
}
