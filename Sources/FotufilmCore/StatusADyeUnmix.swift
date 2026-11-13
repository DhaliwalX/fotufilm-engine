import Foundation

/// Converts integral Status A record densities to nonnegative dye amounts.
/// Each iteration integrates the actual transmitted spectrum and its Jacobian.
/// Unreachable triples minimize squared density error on the dye gamut boundary;
/// they never require negative absorption. This is not a neutral-curve fit.
struct StatusADyeUnmix: Sendable {
    private typealias Rows = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    private let dye: [SIMD3<Float>]
    private let band: [SIMD3<Float>]
    private let zeroJacobian: Rows

    private static let log2Of10 = Float(log2(10.0))

    init(dyes: [[Float]]) {
        let packedDye = (0..<SpectralGrid.count).map { SIMD3(dyes[0][$0], dyes[1][$0], dyes[2][$0]) }
        let integrals = Densitometry.statusA.map { $0.reduce(0, +) }
        let packedBand = (0..<SpectralGrid.count).map { i in
            SIMD3(Densitometry.statusA[0][i] / integrals[0],
                  Densitometry.statusA[1][i] / integrals[1],
                  Densitometry.statusA[2][i] / integrals[2])
        }
        var m0 = SIMD3<Float>.zero
        var m1 = SIMD3<Float>.zero
        var m2 = SIMD3<Float>.zero
        for i in 0..<SpectralGrid.count {
            let d = packedDye[i], w = packedBand[i]
            m0 += d * w.x
            m1 += d * w.y
            m2 += d * w.z
        }
        self.dye = packedDye
        self.band = packedBand
        self.zeroJacobian = (m0, m1, m2)
    }

    private func measurement(_ amounts: SIMD3<Float>) -> (SIMD3<Float>, Rows) {
        if amounts == .zero { return (.zero, zeroJacobian) }
        var sum = SIMD3<Float>.zero
        var m0 = SIMD3<Float>.zero
        var m1 = SIMD3<Float>.zero
        var m2 = SIMD3<Float>.zero
        let scale = Self.log2Of10
        dye.withUnsafeBufferPointer { dyePtr in
            band.withUnsafeBufferPointer { bandPtr in
                for i in 0..<dyePtr.count {
                    let d = dyePtr[i]
                    let transmission = exp2(-(amounts.x * d.x + amounts.y * d.y + amounts.z * d.z) * scale)
                    let w = bandPtr[i] * transmission
                    sum += w
                    m0 += d * w.x
                    m1 += d * w.y
                    m2 += d * w.z
                }
            }
        }
        let sx = max(sum.x, 1e-20), sy = max(sum.y, 1e-20), sz = max(sum.z, 1e-20)
        return (
            SIMD3(-log10(sx), -log10(sy), -log10(sz)),
            (m0 / sx, m1 / sy, m2 / sz)
        )
    }

    func amounts(forStatusA target: SIMD3<Float>) -> SIMD3<Float> {
        if max(target.x, max(target.y, target.z)) <= 0 { return .zero }
        var amounts = SIMD3<Float>.zero
        var density = SIMD3<Float>.zero
        var jacobian = zeroJacobian
        for _ in 0..<24 {
            let residual = density - target
            if max(abs(residual.x), max(abs(residual.y), abs(residual.z))) < 1e-6 { break }
            let (j0, j1, j2) = jacobian
            let b = SIMD3(dot(j0, amounts) - residual.x,
                          dot(j1, amounts) - residual.y,
                          dot(j2, amounts) - residual.z)
            let reg: Float = 1e-7
            let c0 = SIMD3(j0.x, j1.x, j2.x)
            let c1 = SIMD3(j0.y, j1.y, j2.y)
            let c2 = SIMD3(j0.z, j1.z, j2.z)
            let n00 = dot(c0, c0) + reg, n01 = dot(c0, c1), n02 = dot(c0, c2)
            let n11 = dot(c1, c1) + reg, n12 = dot(c1, c2)
            let n22 = dot(c2, c2) + reg
            let rhs = SIMD3(dot(c0, b), dot(c1, b), dot(c2, b)) + reg * amounts

            let best: SIMD3<Float>
            if let full = solve3(n00: n00, n01: n01, n02: n02, n11: n11, n12: n12, n22: n22, rhs: rhs),
               full.x >= 0, full.y >= 0, full.z >= 0 {
                best = full
            } else {
                best = solveBoundary(j0: j0, j1: j1, j2: j2, b: b, amounts: amounts, reg: reg,
                                     n00: n00, n01: n01, n02: n02, n11: n11, n12: n12, n22: n22,
                                     rhs: rhs)
            }
            let step = best - amounts
            if max(abs(step.x), max(abs(step.y), abs(step.z))) < 2e-7 { break }
            var scale: Float = 1
            let error = dot(residual, residual)
            var accepted = false
            for _ in 0..<12 {
                let candidate = SIMD3(max(amounts.x + scale * step.x, 0),
                                      max(amounts.y + scale * step.y, 0),
                                      max(amounts.z + scale * step.z, 0))
                let (nextDensity, nextJacobian) = measurement(candidate)
                let next = nextDensity - target
                if dot(next, next) < error {
                    amounts = candidate
                    density = nextDensity
                    jacobian = nextJacobian
                    accepted = true
                    break
                }
                scale *= 0.5
            }
            if !accepted { break }
        }
        return amounts
    }

    private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private func solve3(n00: Float, n01: Float, n02: Float,
                        n11: Float, n12: Float, n22: Float,
                        rhs: SIMD3<Float>) -> SIMD3<Float>? {
        guard n00 > 1e-10 else { return nil }
        let f10 = n01 / n00
        let f20 = n02 / n00
        let a11 = n11 - f10 * n01
        let a12 = n12 - f10 * n02
        let b1 = rhs.y - f10 * rhs.x
        guard a11 > 1e-10 else { return nil }
        let f21 = a12 / a11
        let a22 = n22 - f20 * n02 - f21 * a12
        guard a22 > 1e-10 else { return nil }
        let z = (rhs.z - f20 * rhs.x - f21 * b1) / a22
        let y = (b1 - a12 * z) / a11
        let x = (rhs.x - n01 * y - n02 * z) / n00
        return SIMD3(x, y, z)
    }

    private func solve2(a00: Float, a01: Float, a11: Float, b0: Float, b1: Float) -> (Float, Float)? {
        let det = a00 * a11 - a01 * a01
        guard det > 1e-12, a00 > 1e-10 else { return nil }
        return ((a11 * b0 - a01 * b1) / det, (a00 * b1 - a01 * b0) / det)
    }

    private func solveBoundary(j0: SIMD3<Float>, j1: SIMD3<Float>, j2: SIMD3<Float>,
                               b: SIMD3<Float>, amounts: SIMD3<Float>, reg: Float,
                               n00: Float, n01: Float, n02: Float,
                               n11: Float, n12: Float, n22: Float,
                               rhs: SIMD3<Float>) -> SIMD3<Float> {
        var best = SIMD3<Float>.zero
        var bestError = dot(b, b) + reg * dot(amounts, amounts)
        func consider(_ candidate: SIMD3<Float>) {
            guard candidate.x >= 0, candidate.y >= 0, candidate.z >= 0 else { return }
            let error = SIMD3(dot(j0, candidate) - b.x,
                              dot(j1, candidate) - b.y,
                              dot(j2, candidate) - b.z)
            let d = candidate - amounts
            let score = dot(error, error) + reg * dot(d, d)
            if score < bestError { bestError = score; best = candidate }
        }
        if n00 > 1e-10 { consider(SIMD3(rhs.x / n00, 0, 0)) }
        if n11 > 1e-10 { consider(SIMD3(0, rhs.y / n11, 0)) }
        if n22 > 1e-10 { consider(SIMD3(0, 0, rhs.z / n22)) }
        if let (x, y) = solve2(a00: n00, a01: n01, a11: n11, b0: rhs.x, b1: rhs.y) {
            consider(SIMD3(x, y, 0))
        }
        if let (x, z) = solve2(a00: n00, a01: n02, a11: n22, b0: rhs.x, b1: rhs.z) {
            consider(SIMD3(x, 0, z))
        }
        if let (y, z) = solve2(a00: n11, a01: n12, a11: n22, b0: rhs.y, b1: rhs.z) {
            consider(SIMD3(0, y, z))
        }
        return best
    }
}
