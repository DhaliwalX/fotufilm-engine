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
/// Owns the vDSP allocation for as long as any convolution still references it.
final class FFTPlan: @unchecked Sendable {
    let log2N: vDSP_Length
    private let handle: FFTSetupD

    init(log2N: vDSP_Length) throws {
        guard let handle = vDSP_create_fftsetupD(log2N, FFTRadix(FFT_RADIX2)) else {
            throw TransportError.backend("failed to create Accelerate FFT setup")
        }
        self.log2N = log2N
        self.handle = handle
    }

    func transform(_ split: inout DSPDoubleSplitComplex, width: vDSP_Length,
                   height: vDSP_Length, direction: FFTDirection) {
        withExtendedLifetime(self) {
            vDSP_fft2d_zipD(handle, &split, 1, 0, width, height, direction)
        }
    }

    deinit { vDSP_destroy_fftsetupD(handle) }
}

final class FFTSetupCache: @unchecked Sendable {
    static let shared = FFTSetupCache()
    private let lock = NSLock()
    private var cached: FFTPlan?

    func setup(forLog2N log2N: vDSP_Length) throws -> FFTPlan {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.log2N >= log2N { return cached }
        let plan = try FFTPlan(log2N: max(log2N, 8))
        cached = plan
        return plan
    }
}

private final class FFTWorkspace: @unchecked Sendable {
    var real: [Double]
    var imag: [Double]
    var byteCount: Int { real.count * 2 * MemoryLayout<Double>.size }
    init(count: Int) {
        real = [Double](repeating: 0, count: count)
        imag = real
    }
}

private final class FFTWorkspacePool: @unchecked Sendable {
    static let shared = FFTWorkspacePool()
    private let lock = NSLock()
    private var pool: [FFTWorkspace] = []
    private var bytes = 0

    func acquire(count: Int) -> FFTWorkspace {
        lock.lock()
        if let index = pool.indices.filter({ pool[$0].real.count >= count })
            .min(by: { pool[$0].real.count < pool[$1].real.count }) {
            let result = pool.remove(at: index)
            bytes -= result.byteCount
            lock.unlock()
            return result
        }
        lock.unlock()
        return FFTWorkspace(count: count)
    }

    func release(_ workspace: FFTWorkspace) {
        lock.lock(); defer { lock.unlock() }
        if pool.count < 6 && bytes + workspace.byteCount <= 512 * 1024 * 1024 {
            pool.append(workspace)
            bytes += workspace.byteCount
        }
    }
}

private struct FFTStencilKey: Hashable {
    let width: Int
    let height: Int
    let weights: [Float]
}

private struct FFTStencilSpectrum {
    let real: [Double]
    let imag: [Double]
    var byteCount: Int { real.count * 2 * MemoryLayout<Double>.size }
}

private final class FFTStencilCache: @unchecked Sendable {
    static let shared = FFTStencilCache()
    private let lock = NSLock()
    private var entries: [(FFTStencilKey, FFTStencilSpectrum)] = []
    private var bytes = 0

    func spectrum(stencil: TransportStencil, width: Int, height: Int, plan: FFTPlan) -> FFTStencilSpectrum {
        let key = FFTStencilKey(width: width, height: height, weights: stencil.weights)
        lock.lock()
        if let index = entries.firstIndex(where: { $0.0 == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.1
        }
        lock.unlock()
        var real = [Double](repeating: 0, count: width * height)
        var imag = real
        let radius = stencil.radius, side = radius * 2 + 1
        // Keep the full complex spectrum: finite angular quadrature can leave small
        // asymmetries. Reverse offsets because the spatial reference evaluates correlation.
        for y in -radius...radius { for x in -radius...radius {
            real[((height - y) % height) * width + (width - x) % width] =
                Double(stencil.weights[(y + radius) * side + x + radius])
        } }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                plan.transform(&split, width: vDSP_Length(width.trailingZeroBitCount),
                    height: vDSP_Length(height.trailingZeroBitCount), direction: FFTDirection(FFT_FORWARD))
            }
        }
        lock.lock(); defer { lock.unlock() }
        // Another caller may have prepared the same spectrum while this one transformed it.
        if let existing = entries.first(where: { $0.0 == key }) { return existing.1 }
        let spectrum = FFTStencilSpectrum(real: real, imag: imag)
        let cost = spectrum.byteCount
        let limit = 512 * 1024 * 1024
        if cost <= limit {
            while bytes + cost > limit || entries.count >= 32 {
                bytes -= entries.removeFirst().1.byteCount
            }
            entries.append((key, spectrum)); bytes += cost
        }
        return spectrum
    }
}

private func nextPowerOfTwo(_ value: Int) throws -> Int {
    guard value > 0 && value <= (1 << 29) else {
        throw TransportError.unsupported("FFT transport dimensions exceed capacity")
    }
    var result = 1
    while result < value { result <<= 1 }
    return max(64, result)
}

private struct CubicTap {
    let indices: SIMD4<Int32>
    let weights: SIMD4<Float>
    init(pixel: Int, stride: Int, extent: Int) {
        let position = (Float(pixel) + 0.5) / Float(stride) - 0.5
        let base = Int(floor(position)), f = position - floor(position)
        let g = 1 - f, f2 = f * f, f3 = f2 * f
        indices = SIMD4(((-1)...2).map { Int32(min(max(base + $0, 0), extent - 1)) })
        weights = SIMD4(g*g*g, 3*f3-6*f2+4, -3*f3+3*f2+3*f+1, f3) / 6
    }
}
#endif

/// FFT convolution of the same positive pixel-integrated bands as CPU and Metal.
/// The continuous Bessel OTF is useful for analysis, but sampling it at the FFT
/// frequencies is not a positive discrete convolution of pixel-cell exposures.
public enum LayeredTransportFFT {
    public static func convolve(image: ImageBuffer, kernel: TransportRadialKernel,
                                pixelPitchMM: Double) throws -> ImageBuffer {
        guard image.width > 0 && image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount && $0.allSatisfy(\.isFinite) }) else {
            throw TransportError.invalid("invalid image or planes")
        }
        var output = ImageBuffer(width: image.width, height: image.height)
        try convolve(component: image, kernel: kernel, pixelPitchMM: pixelPitchMM, into: &output)
        return output
    }

    public static func convolve(component: ImageBuffer, kernel: TransportRadialKernel,
                                pixelPitchMM: Double, into exposure: inout ImageBuffer) throws {
        guard component.width > 0 && component.height > 0, component.planes.count == 3,
              component.planes.allSatisfy({ $0.count == component.pixelCount && $0.allSatisfy(\.isFinite) }),
              exposure.width == component.width && exposure.height == component.height,
              exposure.planes.count == 3,
              exposure.planes.allSatisfy({ $0.count == component.pixelCount && $0.allSatisfy(\.isFinite) }) else {
            throw TransportError.invalid("invalid component or exposure dimensions")
        }
        guard pixelPitchMM.isFinite && pixelPitchMM > 0 else {
            throw TransportError.invalid("invalid pixel pitch")
        }
        #if canImport(Accelerate)
        for band in try kernel.stencils(pixelPitchMM: pixelPitchMM) where band.weight > 0 {
            try accumulate(component, band: band, into: &exposure)
        }
        #else
        throw TransportError.unsupported("FFT transport backend requires Apple Accelerate framework")
        #endif
    }

    #if canImport(Accelerate)
    private static func accumulate(_ component: ImageBuffer, band: TransportWeightedStencil,
                                   into exposure: inout ImageBuffer) throws {
        let w = component.width, h = component.height
        let stencil = band.stencil, stride = stencil.stride, pad = stencil.radius
        let gw = (w + stride - 1) / stride, gh = (h + stride - 1) / stride
        let fw = try nextPowerOfTwo(gw + 2 * pad), fh = try nextPowerOfTwo(gh + 2 * pad)
        guard fw <= Int.max / fh, fw * fh <= (1 << 28) else {
            throw TransportError.unsupported("FFT transport workspace exceeds capacity")
        }
        let count = fw * fh
        let logW = vDSP_Length(fw.trailingZeroBitCount), logH = vDSP_Length(fh.trailingZeroBitCount)
        let plan = try FFTSetupCache.shared.setup(forLog2N: max(logW, logH))
        let spectrum = FFTStencilCache.shared.spectrum(stencil: stencil, width: fw, height: fh, plan: plan)
        let xtaps = stride == 1 ? [] : (0..<w).map { CubicTap(pixel: $0, stride: stride, extent: gw) }
        let ytaps = stride == 1 ? [] : (0..<h).map { CubicTap(pixel: $0, stride: stride, extent: gh) }
        var r = exposure.planes[0], g = exposure.planes[1], b = exposure.planes[2]
        r.withUnsafeMutableBufferPointer { rp in
            g.withUnsafeMutableBufferPointer { gp in
                b.withUnsafeMutableBufferPointer { bp in
                    let destinations = [rp.baseAddress!, gp.baseAddress!, bp.baseAddress!]
                    DispatchQueue.concurrentPerform(iterations: 3) { channel in
                        let source = component.planes[channel], destination = destinations[channel]
                        source.withUnsafeBufferPointer { src in
                            let input = src.baseAddress!
                            var minimum: Float = 0, maximum: Float = 0
                            vDSP_minv(input, 1, &minimum, vDSP_Length(source.count))
                            vDSP_maxv(input, 1, &maximum, vDSP_Length(source.count))
                            if minimum == maximum {
                                var contribution = minimum * band.weight
                                vDSP_vsadd(destination, 1, &contribution, destination, 1, vDSP_Length(source.count))
                                return
                            }
                            let workspace = FFTWorkspacePool.shared.acquire(count: count)
                            defer { FFTWorkspacePool.shared.release(workspace) }
                            workspace.real.withUnsafeMutableBufferPointer { real in
                                workspace.imag.withUnsafeMutableBufferPointer { imag in
                                    let data = real.baseAddress!, imaginary = imag.baseAddress!
                                    vDSP_vclrD(imaginary, 1, vDSP_Length(count))
                                    // Area reduction matches the reference, including partial edge cells.
                                    for y in 0..<gh {
                                        let row = (y + pad) * fw + pad
                                        if stride == 1 {
                                            vDSP_vspdp(input + y*w, 1, data + row, 1, vDSP_Length(w))
                                        } else {
                                            for x in 0..<gw {
                                                var sum: Float = 0
                                                for dy in 0..<stride { for dx in 0..<stride {
                                                    sum += input[min(y*stride+dy,h-1)*w+min(x*stride+dx,w-1)]
                                                } }
                                                data[row+x] = Double(sum / Float(stride*stride))
                                            }
                                        }
                                        var left = data[row], right = data[row+gw-1]
                                        vDSP_vfillD(&left, data + row - pad, 1, vDSP_Length(pad))
                                        vDSP_vfillD(&right, data + row + gw, 1, vDSP_Length(fw-pad-gw))
                                    }
                                    for y in 0..<pad {
                                        memcpy(data+y*fw, data+pad*fw, fw*MemoryLayout<Double>.size)
                                    }
                                    for y in (pad+gh)..<fh {
                                        memcpy(data+y*fw, data+(pad+gh-1)*fw, fw*MemoryLayout<Double>.size)
                                    }
                                    var split = DSPDoubleSplitComplex(realp: data, imagp: imaginary)
                                    plan.transform(&split, width: logW, height: logH, direction: FFTDirection(FFT_FORWARD))
                                    spectrum.real.withUnsafeBufferPointer { kr in
                                        spectrum.imag.withUnsafeBufferPointer { ki in
                                            var transfer = DSPDoubleSplitComplex(realp: UnsafeMutablePointer(mutating: kr.baseAddress!),
                                                imagp: UnsafeMutablePointer(mutating: ki.baseAddress!))
                                            vDSP_zvmulD(&split, 1, &transfer, 1, &split, 1, vDSP_Length(count), 1)
                                        }
                                    }
                                    plan.transform(&split, width: logW, height: logH, direction: FFTDirection(FFT_INVERSE))
                                    var scale = 1 / Double(count)
                                    // Double precision keeps bright HDR highlights from introducing
                                    // global roundoff noise into near-black exposure. Convert only
                                    // the cropped result back to the reference's float representation.
                                    var coarse = [Float](repeating: 0, count: gw*gh)
                                    coarse.withUnsafeMutableBufferPointer { grid in
                                        for y in 0..<gh {
                                            let row = data + (y+pad)*fw + pad
                                            vDSP_vsmulD(row, 1, &scale, row, 1, vDSP_Length(gw))
                                            vDSP_vdpsp(row, 1, grid.baseAddress!+y*gw, 1, vDSP_Length(gw))
                                        }
                                        // Positive normalized convolution stays within the source range.
                                        vDSP_vclip(grid.baseAddress!, 1, &minimum, &maximum,
                                            grid.baseAddress!, 1, vDSP_Length(gw*gh))
                                    }
                                    var weight = band.weight
                                    if stride == 1 {
                                        coarse.withUnsafeBufferPointer { grid in
                                            for y in 0..<h {
                                                vDSP_vsma(grid.baseAddress!+y*gw, 1, &weight,
                                                    destination+y*w, 1, destination+y*w, 1, vDSP_Length(w))
                                            }
                                        }
                                    } else {
                                        // Separable B-spline reconstruction avoids repeating 16 taps per pixel.
                                        var horizontal = [Float](repeating: 0, count: w*gh)
                                        for y in 0..<gh { for x in 0..<w {
                                            let tap = xtaps[x], row = y*gw
                                            var value: Float = 0
                                            for k in 0..<4 { value += tap.weights[k]*coarse[row+Int(tap.indices[k])] }
                                            horizontal[y*w+x] = value
                                        } }
                                        horizontal.withUnsafeBufferPointer { rows in
                                            for y in 0..<h {
                                                let tap = ytaps[y]
                                                for k in 0..<4 {
                                                    var coefficient = weight*tap.weights[k]
                                                    vDSP_vsma(rows.baseAddress!+Int(tap.indices[k])*w, 1, &coefficient,
                                                        destination+y*w, 1, destination+y*w, 1, vDSP_Length(w))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        exposure.planes = [r, g, b]
    }
    #endif
}
