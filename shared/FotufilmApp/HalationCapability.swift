import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// Measures whether the device runs annular halation at 1080p30 using the production GPU schedule.
/// The result sets the default for `AppSettings.estimatedHalationEnabled`; the default remains off
/// until measurement and can be overridden in Advanced settings.
enum HalationCapability {
    /// Defaults to false until a measurement is stored.
    static var capableDefault: Bool { stored() ?? false }

    /// Whether a verdict exists yet, for anything that wants to show the measurement.
    static var measured: Bool { stored() != nil }

    private static let frameWidth = 1920
    private static let frameHeight = 1080
    private static let ceiling: TimeInterval = 1.0 / 30.0

    private static let warmupFrames = 2
    private static let timedFrames = 12

    /// Schedules the one-time probe a few seconds out, past app launch and — on a first camera
    /// launch — past the recording takeover's own timed run, so the two measurements do not
    /// contend for the GPU.
    static func probeSoon() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            probeIfNeeded()
        }
    }

    static func probeIfNeeded() {
        lock.lock()
        let due = stored() == nil && !probing
        if due { probing = true }
        lock.unlock()
        guard due else { return }
        // A hot device times slow and would store a verdict the cool device never earns back;
        // leave the run for a later launch.
        guard ProcessInfo.processInfo.thermalState == .nominal
            || ProcessInfo.processInfo.thermalState == .fair else {
            lock.lock(); probing = false; lock.unlock()
            return
        }
        let verdict = measure()
        lock.lock(); probing = false; lock.unlock()
        // Store only a changed default. Failed probes retry on the next launch. Updating through
        // AppSettings also posts `filmModelChanged` for active renders.
        if verdict == true {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppSettings.shared.adoptEstimatedHalationDefault()
                }
            }
        }
    }

    /// Times the annular develop and stores the verdict. Returns nil when the run could not be
    /// made (no Metal, no profiled stock installed), which stores nothing.
    @discardableResult
    static func measure() -> Bool? {
        guard let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        var options = FotufilmEngine.Options()
        options.useEstimatedHalationProfile = true
        // A stock the toggle actually changes: the annular path only builds where a spatial
        // profile exists, so a stock without one would time the legacy kernel and verdict the
        // wrong question.
        let installed = FilmStock.presetIDs.compactMap(FilmStock.named)
        guard let stock = installed.first(where: {
            !$0.isMonochrome
                && ($0.halationProfile != nil || $0.estimatedHalationProfile != nil)
        }) ?? installed.first(where: {
            $0.halationProfile != nil || $0.estimatedHalationProfile != nil
        }) else { return nil }

        guard HalideMetalFilmRenderer.canRender(
                width: frameWidth, height: frameHeight,
                stock: stock, options: options),
              let input = device.makeBuffer(length: frameWidth * frameHeight * 4,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: frameWidth * frameHeight * 4,
                                             options: .storageModeShared)
        else { return nil }
        fill(input)
        engine.prepare(stock: stock, options: options,
                       frameWidth: frameWidth, frameHeight: frameHeight)

        var best = TimeInterval.infinity
        for frame in 0..<(warmupFrames + timedFrames) {
            let start = Date()
            guard engine.processRGBA8(input: input, output: output,
                                      width: frameWidth, height: frameHeight,
                                      stock: stock, options: options,
                                      frameIndex: UInt64(frame)) else { return nil }
            if frame >= warmupFrames {
                best = min(best, Date().timeIntervalSince(start))
            }
        }
        guard best.isFinite else { return nil }
        let verdict = best <= ceiling
        remember(verdict, seconds: best)
        print(String(format: "HalationCapability: 1080p annular %.1f ms, %@",
                     best * 1000, verdict ? "on by default" : "off by default"))
        return verdict
    }

    // MARK: - Storage

    private static let lock = NSLock()
    nonisolated(unsafe) private static var probing = false

    private static let method = 1

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
        return "fotufilm.halation-capability.v\(method).\(build).\(buildFlavor)."
            + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func stored() -> Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }

    private static func remember(_ verdict: Bool, seconds: TimeInterval) {
        UserDefaults.standard.set(verdict, forKey: key)
        UserDefaults.standard.set(seconds, forKey: key + ".seconds")
    }

    private static func fill(_ buffer: MTLBuffer) {
        let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
        let spanX = max(frameWidth - 1, 1), spanY = max(frameHeight - 1, 1)
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let index = (y * frameWidth + x) * 4
                pixels[index] = UInt8((x * 255) / spanX)
                pixels[index + 1] = UInt8((y * 255) / spanY)
                pixels[index + 2] = UInt8(((x + y) * 255) / (spanX + spanY))
                pixels[index + 3] = 255
            }
        }
    }
}
