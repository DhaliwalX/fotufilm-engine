import Foundation

/// Whether this device should run the live HDR viewfinder, or stay on the
/// 8-bit path it has always used.
enum HDRCapability {
    /// The most a develop may take and still leave the frame room for everything else in it: the
    /// HLG decode, the present pass, the capture pipeline and Core Image's composite.
    static let developCeiling = 0.022

    private static let judgeAfter = 60

    private static let settleFrames = 15

    private static let lock = NSLock()
    private static var seen = 0
    private static var best = TimeInterval.infinity
    private static var verdict: Bool?

    /// Whether the live HDR path should be taken right now.
    static var allowsLiveHDR: Bool {
        if let override { return override }
        lock.lock(); defer { lock.unlock() }
        if let verdict { return verdict }
        if let remembered = remembered() {
            verdict = remembered
            return remembered
        }
        return true
    }

    /// Hands one developed HDR viewfinder frame's cost to the judgement, and
    /// says whether the path should now change.
    static func observe(developSeconds: TimeInterval) -> Bool {
        if override != nil { return false }
        lock.lock(); defer { lock.unlock() }
        guard verdict == nil else { return false }
        seen += 1
        guard seen > settleFrames else { return false }
        best = min(best, developSeconds)
        guard seen >= judgeAfter + settleFrames else { return false }
        let passed = best <= developCeiling
        verdict = passed
        remember(passed)
        print(String(format: "HDRCapability: best %.2f ms over %d viewfinder "
                     + "frames, live HDR %@",
                     best * 1000, judgeAfter, passed ? "on" : "off"))
        return !passed
    }

    /// Clears the cached result and restarts measurement.
    static func reconsider() {
        UserDefaults.standard.removeObject(forKey: key)
        lock.lock()
        verdict = nil
        seen = 0
        best = .infinity
        lock.unlock()
    }

    /// The verdict if one has been reached, without reaching for one.
    static var settledVerdict: Bool? {
        if let override { return override }
        lock.lock(); defer { lock.unlock() }
        return verdict ?? remembered()
    }

    private static var override: Bool? {
        switch ProcessInfo.processInfo.environment["FOTUFILM_HDR_LIVE"] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    private static let method = 4

    private static var buildFlavor: String {
        #if DEBUG
        "debug"
        #else
        "optimized"
        #endif
    }

    private static var key: String {
        let build = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "fotufilm.hdr-live.v\(method).\(build).\(buildFlavor)."
            + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func remembered() -> Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }

    private static func remember(_ passed: Bool) {
        UserDefaults.standard.set(passed, forKey: key)
    }
}
