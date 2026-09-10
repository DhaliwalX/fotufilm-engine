import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Evaluates the continuous Optical Transfer Function (OTF) corresponding to a 2D isotropic
/// radial kernel composed of concentric rings:
///   OTF(nu) = sum_i m_i * J0(2 * pi * nu * r_i / pitch)
/// where nu is the spatial frequency in cycles/pixel.
public struct ContinuousBesselOTF: Sendable {
    public let table: [Float]
    public let sampleCount: Int
    public let nuMax: Float
    private let invDeltaNu: Float

    public init(kernel: TransportRadialKernel, pixelPitchMM: Double, sampleCount: Int = 2048, nuMax: Float = 0.75) {
        precondition(sampleCount >= 2, "sampleCount must be at least 2")
        precondition(nuMax > 0, "nuMax must be positive")
        precondition(pixelPitchMM > 0, "pixelPitchMM must be positive")

        self.sampleCount = sampleCount
        self.nuMax = nuMax
        let deltaNu = nuMax / Float(sampleCount - 1)
        self.invDeltaNu = 1.0 / deltaNu

        var lut = [Float](repeating: 0, count: sampleCount)
        lut[0] = 1.0 // Strictly conserve energy at DC (OTF(0) == 1.0)

        let radii = kernel.radiusMM
        let masses = kernel.mass
        let twoPiOverPitch = 2.0 * Double.pi / pixelPitchMM

        for k in 1..<sampleCount {
            let nu = Double(k) * Double(deltaNu)
            var otfVal: Double = 0.0
            for i in 0..<radii.count {
                let arg = twoPiOverPitch * nu * radii[i]
                #if canImport(Darwin)
                otfVal += masses[i] * Darwin.j0(arg)
                #elseif canImport(Glibc)
                otfVal += masses[i] * Glibc.j0(arg)
                #else
                otfVal += masses[i] * j0(arg)
                #endif
            }
            lut[k] = Float(otfVal)
        }
        self.table = lut
    }

    @inline(__always)
    public func sample(nu: Float) -> Float {
        if nu <= 0 {
            return 1.0
        }
        let pos = nu * invDeltaNu
        let idx = Int(pos)
        if idx >= sampleCount - 1 {
            return table[sampleCount - 1]
        }
        let frac = pos - Float(idx)
        return table[idx] * (1.0 - frac) + table[idx + 1] * frac
    }
}

#if canImport(Accelerate)
final class FFTWorkspace: @unchecked Sendable {
    var real: [Float]
    var imag: [Float]
    init(count: Int) {
        self.real = [Float](repeating: 0, count: count)
        self.imag = [Float](repeating: 0, count: count)
    }
}

final class FFTWorkspacePool: @unchecked Sendable {
    static let shared = FFTWorkspacePool()
    private let lock = NSLock()
    private var pool: [FFTWorkspace] = []

    func acquire(count: Int) -> FFTWorkspace {
        lock.lock()
        defer { lock.unlock() }
        if let idx = pool.firstIndex(where: { $0.real.count >= count }) {
            return pool.remove(at: idx)
        }
        return FFTWorkspace(count: count)
    }

    func release(_ ws: FFTWorkspace) {
        lock.lock()
        defer { lock.unlock() }
        if pool.count < 6 {
            pool.append(ws)
        }
    }
}

final class FFTSetupCache: @unchecked Sendable {
    static let shared = FFTSetupCache()
    private let lock = NSLock()
    private var maxLog2: vDSP_Length = 0
    private var cachedSetup: FFTSetup?

    func setup(forLog2N log2N: vDSP_Length) -> FFTSetup? {
        lock.lock()
        defer { lock.unlock() }
        if let setup = cachedSetup, maxLog2 >= log2N {
            return setup
        }
        if let old = cachedSetup {
            vDSP_destroy_fftsetup(old)
            cachedSetup = nil
        }
        let allocLog = max(log2N, 13)
        if let newSetup = vDSP_create_fftsetup(allocLog, FFTRadix(FFT_RADIX2)) {
            cachedSetup = newSetup
            maxLog2 = allocLog
            return newSetup
        }
        return nil
    }

    deinit {
        if let s = cachedSetup {
            vDSP_destroy_fftsetup(s)
        }
    }
}

@inline(__always)
private func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    var p = 1
    while p < value {
        p &<<= 1
    }
    return p
}
#endif

public enum LayeredTransportFFT {
    public static func convolve(image: ImageBuffer, kernel: TransportRadialKernel, pixelPitchMM: Double) throws -> ImageBuffer {
        guard image.width > 0 && image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount && $0.allSatisfy(\.isFinite) }) else {
            throw TransportError.invalid("invalid image or planes")
        }
        guard pixelPitchMM.isFinite && pixelPitchMM > 0 else {
            throw TransportError.invalid("invalid pixel pitch")
        }
        #if canImport(Accelerate)
        var output = ImageBuffer(width: image.width, height: image.height)
        try convolve(component: image, kernel: kernel, pixelPitchMM: pixelPitchMM, into: &output)
        return output
        #else
        throw TransportError.unsupported("FFT transport backend requires Apple Accelerate framework")
        #endif
    }

    public static func convolve(component: ImageBuffer, kernel: TransportRadialKernel, pixelPitchMM: Double, into exposure: inout ImageBuffer) throws {
        guard component.width > 0 && component.height > 0, component.planes.count == 3,
              component.planes.allSatisfy({ $0.count == component.pixelCount && $0.allSatisfy(\.isFinite) }),
              exposure.width == component.width && exposure.height == component.height,
              exposure.planes.count == 3,
              exposure.planes.allSatisfy({ $0.count == exposure.pixelCount }) else {
            throw TransportError.invalid("invalid component or exposure dimensions")
        }
        guard pixelPitchMM.isFinite && pixelPitchMM > 0 else {
            throw TransportError.invalid("invalid pixel pitch")
        }

        #if canImport(Accelerate)
        let W = component.width
        let H = component.height

        let rMax = kernel.radiusMM.last ?? 0.0
        let rPad = max(16, Int(ceil(rMax / pixelPitchMM)) + 16)

        let minPadW = W + 2 * rPad
        let minPadH = H + 2 * rPad

        let W_pad = max(64, nextPowerOfTwo(minPadW))
        let H_pad = max(64, nextPowerOfTwo(minPadH))
        let paddedCount = W_pad * H_pad

        let log2W = vDSP_Length(W_pad.trailingZeroBitCount)
        let log2H = vDSP_Length(H_pad.trailingZeroBitCount)

        guard let setup = FFTSetupCache.shared.setup(forLog2N: max(log2W, log2H)) else {
            throw TransportError.backend("failed to create Accelerate FFT setup")
        }

        let besselOTF = ContinuousBesselOTF(kernel: kernel, pixelPitchMM: pixelPitchMM)

        // Precompute 2D OTF grid
        let halfW = W_pad / 2
        let halfH = H_pad / 2
        let invW = 1.0 / Float(W_pad)
        let invH = 1.0 / Float(H_pad)
        var otf = [Float](repeating: 0, count: paddedCount)

        for y in 0..<H_pad {
            let ky = Float(y <= halfH ? y : y - H_pad)
            let nuy = ky * invH
            let nuy2 = nuy * nuy
            let rowOffset = y * W_pad
            for x in 0..<W_pad {
                let kx = Float(x <= halfW ? x : x - W_pad)
                let nux = kx * invW
                let nu = sqrt(nux * nux + nuy2)
                otf[rowOffset + x] = besselOTF.sample(nu: nu)
            }
        }
        otf[0] = 1.0 // Strictly conserve energy at DC

        let workspaces = (0..<3).map { _ in FFTWorkspacePool.shared.acquire(count: paddedCount) }
        defer {
            for ws in workspaces {
                FFTWorkspacePool.shared.release(ws)
            }
        }

        let inputPlanes = component.planes
        let expPlanes = exposure.planes

        var plane0 = expPlanes[0]
        var plane1 = expPlanes[1]
        var plane2 = expPlanes[2]

        plane0.withUnsafeMutableBufferPointer { p0 in
            plane1.withUnsafeMutableBufferPointer { p1 in
                plane2.withUnsafeMutableBufferPointer { p2 in
                    let exposurePointers = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!]

                    DispatchQueue.concurrentPerform(iterations: 3) { c in
                        let ws = workspaces[c]
                        let src = inputPlanes[c]
                        let expPtr = exposurePointers[c]

                        ws.real.withUnsafeMutableBufferPointer { rBuf in
                            ws.imag.withUnsafeMutableBufferPointer { iBuf in
                                let rPtr = rBuf.baseAddress!
                                let iPtr = iBuf.baseAddress!

                                // Zero out imaginary plane
                                vDSP_vclr(iPtr, 1, vDSP_Length(paddedCount))

                                // Edge-replicated padding into rPtr
                                src.withUnsafeBufferPointer { sBuf in
                                    let sPtr = sBuf.baseAddress!

                                    // Interior rows y in 0..<H
                                    for y in 0..<H {
                                        let sRow = y * W
                                        let dRow = (y + rPad) * W_pad
                                        let firstVal = sPtr[sRow]
                                        let lastVal = sPtr[sRow + W - 1]

                                        // Left clamp
                                        for x in 0..<rPad {
                                            rPtr[dRow + x] = firstVal
                                        }
                                        // Center copy
                                        memcpy(rPtr + dRow + rPad, sPtr + sRow, W * MemoryLayout<Float>.size)
                                        // Right clamp
                                        for x in (rPad + W)..<W_pad {
                                            rPtr[dRow + x] = lastVal
                                        }
                                    }

                                    // Top replicated rows
                                    let firstPaddedRow = rPtr + rPad * W_pad
                                    for y in 0..<rPad {
                                        memcpy(rPtr + y * W_pad, firstPaddedRow, W_pad * MemoryLayout<Float>.size)
                                    }

                                    // Bottom replicated rows
                                    let lastPaddedRow = rPtr + (rPad + H - 1) * W_pad
                                    for y in (rPad + H)..<H_pad {
                                        memcpy(rPtr + y * W_pad, lastPaddedRow, W_pad * MemoryLayout<Float>.size)
                                    }
                                }

                                // Forward 2D FFT
                                var split = DSPSplitComplex(realp: rPtr, imagp: iPtr)
                                vDSP_fft2d_zip(setup, &split, 1, 0, log2W, log2H, FFTDirection(FFT_FORWARD))

                                // Pointwise spectral multiplication with purely real isotropic OTF
                                otf.withUnsafeBufferPointer { otfBuf in
                                    let otfPtr = otfBuf.baseAddress!
                                    vDSP_vmul(rPtr, 1, otfPtr, 1, rPtr, 1, vDSP_Length(paddedCount))
                                    vDSP_vmul(iPtr, 1, otfPtr, 1, iPtr, 1, vDSP_Length(paddedCount))
                                }

                                // Inverse 2D FFT
                                vDSP_fft2d_zip(setup, &split, 1, 0, log2W, log2H, FFTDirection(FFT_INVERSE))

                                // Scale factor: 1.0 / Float(W_pad * H_pad)
                                var scale = 1.0 / Float(paddedCount)
                                vDSP_vsmul(rPtr, 1, &scale, rPtr, 1, vDSP_Length(paddedCount))

                                // Crop and accumulate into exposure
                                for y in 0..<H {
                                    let srcRow = (y + rPad) * W_pad + rPad
                                    let dstRow = y * W
                                    vDSP_vadd(expPtr + dstRow, 1, rPtr + srcRow, 1, expPtr + dstRow, 1, vDSP_Length(W))
                                }
                            }
                        }
                    }
                }
            }
        }

        exposure.planes = [plane0, plane1, plane2]
        #else
        throw TransportError.unsupported("FFT transport backend requires Apple Accelerate framework")
        #endif
    }
}
