import Foundation

/// Applies the illuminant-aware delta from a resolved dual-illuminant camera profile.
/// Frames remain bit-identical when the camera, scene temperature, or significant correction is
/// unavailable. Anchor solves are cached per profile.
public enum CameraProfileCorrection {
    /// Retained as an anchor constant for clients that display the old daylight threshold. It no
    /// longer gates correction: full-float ingest can preserve even sub-code-value profile deltas.
    public static let skipKelvin: Float = 5500

    /// Only numerical solve residue is skipped. Quantizing this decision to an output code depth
    /// discards information before the film and makes the result depend on the eventual delivery.
    public static let minimumDeviation: Float = 1e-12

    /// Everything the ingest needs to apply and to say what it did.
    public struct Resolved: Sendable {
        public let profileID: String
        /// The scene's correlated colour temperature the matrix was blended for, in kelvin.
        public let cct: Float
        public let matrix: [SIMD3<Float>]
        /// Largest elementwise distance from identity — the observable size of the correction.
        public let maxDeviation: Float
    }

    /// Kill switch for A/B harnesses: any value disables resolution entirely, so an off run is
    /// bit-identical to a build without the wiring. Read through `getenv` rather than
    /// `ProcessInfo`'s cached snapshot so an in-process harness (the test suite) can flip the
    /// switch with `setenv` and observe both sides.
    public static var isDisabled: Bool {
        getenv("FOTUFILM_PROFILE_OFF") != nil
    }

    /// The two anchor solves per profile are the expensive half of the scheme; they are pure
    /// functions of the profile, so one cache entry serves every frame and every temperature.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var anchors: [String: DualIlluminantMatrices] = [:]

    /// The correction a decoded frame still needs, or nil when there is nothing to apply:
    /// no resolvable profile, no scene temperature, or an exactly identity matrix.
    public static func resolve(camera: CameraIdentity?,
                               sceneKelvin: Float?) -> Resolved? {
        guard !isDisabled,
              let sceneKelvin, sceneKelvin > 0,
              let profile = CameraSpectralProfileStore.resolve(camera) else { return nil }
        let pair: DualIlluminantMatrices
        lock.lock()
        if let held = anchors[profile.id] {
            pair = held
            lock.unlock()
        } else {
            lock.unlock()
            let solved = profile.dualIlluminantMatrices()
            lock.lock()
            anchors[profile.id] = solved
            lock.unlock()
            pair = solved
        }
        let matrix = pair.correction(cct: sceneKelvin)
        let deviation = DualIlluminantMatrices.maxDeviationFromIdentity(matrix)
        guard deviation > minimumDeviation else { return nil }
        return Resolved(profileID: profile.id, cct: sceneKelvin,
                        matrix: matrix, maxDeviation: deviation)
    }

    /// Left-multiplies a row-major camera-to-working matrix by the resolved correction:
    /// `corrected = correction(cct) × base`. Returns the same array when no correction applies.
    /// Correction rows sum to one, preserving the base matrix's white mapping.
    public static func composedGamut(base: [Float],
                                     camera: CameraIdentity?,
                                     cct: Float?) -> [Float] {
        precondition(base.count == 9)
        guard let resolved = resolve(camera: camera, sceneKelvin: cct) else { return base }
        trace(resolved)
        var composed = [Float](repeating: 0, count: 9)
        for row in 0..<3 {
            let c = resolved.matrix[row]
            for column in 0..<3 {
                composed[row * 3 + column] = c.x * base[column]
                    + c.y * base[3 + column]
                    + c.z * base[6 + column]
            }
        }
        return composed
    }

    /// One 3×3 pass over interleaved scene-linear RGBA floats. Alpha is transport, not light,
    /// and passes through untouched.
    public static func apply(_ matrix: [SIMD3<Float>], toRGBA pixels: inout [Float]) {
        precondition(matrix.count == 3)
        precondition(pixels.count.isMultiple(of: 4))
        let r0 = matrix[0], r1 = matrix[1], r2 = matrix[2]
        pixels.withUnsafeMutableBufferPointer { buffer in
            for base in stride(from: 0, to: buffer.count, by: 4) {
                let v = SIMD3(buffer[base], buffer[base + 1], buffer[base + 2])
                buffer[base] = (r0 * v).sum()
                buffer[base + 1] = (r1 * v).sum()
                buffer[base + 2] = (r2 * v).sum()
            }
        }
    }

    /// The same pass over a caller-owned scene buffer, corrected in place right after the linear
    /// working-space samples are laid down.
#if !arch(x86_64)
    public static func apply(_ matrix: [SIMD3<Float>],
                             toRGBA pixels: UnsafeMutableBufferPointer<Float>) {
        precondition(matrix.count == 3)
        precondition(pixels.count.isMultiple(of: 4))
        let r0 = matrix[0], r1 = matrix[1], r2 = matrix[2]
        for base in stride(from: 0, to: pixels.count, by: 4) {
            let v = SIMD3(pixels[base], pixels[base + 1], pixels[base + 2])
            pixels[base] = (r0 * v).sum()
            pixels[base + 1] = (r1 * v).sum()
            pixels[base + 2] = (r2 * v).sum()
        }
    }

#endif

    /// Says what the ingest did, gated the way the other FOTUFILM_ diagnostics are: set
    /// FOTUFILM_PROFILE_TRACE to see one line per corrected decode.
    public static func trace(_ resolved: Resolved) {
        guard ProcessInfo.processInfo.environment["FOTUFILM_PROFILE_TRACE"] != nil else {
            return
        }
        print(String(format: "fotufilm profile: %@ at %.0f K, max deviation %.4f",
                     resolved.profileID, resolved.cct, resolved.maxDeviation))
    }
}
