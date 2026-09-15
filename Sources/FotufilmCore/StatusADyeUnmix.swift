import Foundation

/// Converts integral Status A record densities to nonnegative dye amounts.
/// Each iteration integrates the actual transmitted spectrum and its Jacobian.
/// Unreachable triples minimize squared density error on the dye gamut boundary;
/// they never require negative absorption. This is not a neutral-curve fit.
struct StatusADyeUnmix: Sendable {
    private let dye: [SIMD3<Float>]
    private let band: [SIMD3<Float>]

    init(dyes: [[Float]]) {
        dye = (0..<SpectralGrid.count).map { SIMD3(dyes[0][$0], dyes[1][$0], dyes[2][$0]) }
        let integrals = Densitometry.statusA.map { $0.reduce(0, +) }
        band = (0..<SpectralGrid.count).map { i in
            SIMD3(Densitometry.statusA[0][i] / integrals[0],
                  Densitometry.statusA[1][i] / integrals[1],
                  Densitometry.statusA[2][i] / integrals[2])
        }
    }

    private func measurement(_ amounts: SIMD3<Float>) -> (SIMD3<Float>, [SIMD3<Float>]) {
        var sum = SIMD3<Float>.zero
        var moments = [SIMD3<Float>](repeating: .zero, count: 3)
        for i in dye.indices {
            let transmission = exp2(-dot(amounts, dye[i]) * Float(log2(10.0)))
            let weight = band[i] * transmission
            sum += weight
            for channel in 0..<3 { moments[channel] += dye[i] * weight[channel] }
        }
        var density = SIMD3<Float>.zero
        for channel in 0..<3 {
            let energy = max(sum[channel], 1e-20)
            density[channel] = -log10(energy)
            moments[channel] /= energy
        }
        return (density, moments)
    }

    func amounts(forStatusA target: SIMD3<Float>) -> SIMD3<Float> {
        var amounts = SIMD3<Float>.zero
        for _ in 0..<24 {
            let (density, jacobian) = measurement(amounts)
            let residual = density - target
            if max(abs(residual.x), abs(residual.y), abs(residual.z)) < 1e-6 { break }
            // Linearized nonnegative least squares. Enumerate the eight active
            // sets of three dyes, including clear film, rather than clipping an
            // unconstrained answer after it has already altered the other bands.
            let b = SIMD3((0..<3).map { dot(jacobian[$0], amounts) - residual[$0] })
            let regularization: Float = 1e-7
            var normal = [SIMD3<Float>](repeating: .zero, count: 3)
            var rhs = SIMD3<Float>.zero
            for j in 0..<3 {
                rhs[j] = regularization * amounts[j]
                for k in 0..<3 {
                    normal[j][k] = (j == k ? regularization : 0)
                    for channel in 0..<3 {
                        normal[j][k] += jacobian[channel][j] * jacobian[channel][k]
                    }
                }
                for channel in 0..<3 { rhs[j] += jacobian[channel][j] * b[channel] }
            }
            var best = SIMD3<Float>.zero
            var bestError = dot(b, b) + regularization * dot(amounts, amounts)
            for mask in 1..<8 {
                let active = (0..<3).filter { mask & (1 << $0) != 0 }
                guard let candidate = solve(normal, rhs, active: active),
                      candidate.x >= 0, candidate.y >= 0, candidate.z >= 0 else { continue }
                let error = SIMD3((0..<3).map { dot(jacobian[$0], candidate) - b[$0] })
                let distance = candidate - amounts
                let score = dot(error, error) + regularization * dot(distance, distance)
                if score < bestError { bestError = score; best = candidate }
            }
            let step = best - amounts
            if max(abs(step.x), abs(step.y), abs(step.z)) < 2e-7 { break }
            var scale: Float = 1
            let error = dot(residual, residual)
            var accepted = false
            for _ in 0..<12 {
                let candidate = amounts + scale * step
                let next = measurement(candidate).0 - target
                if dot(next, next) < error {
                    amounts = candidate; accepted = true; break
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

    private func solve(_ matrix: [SIMD3<Float>], _ rhs: SIMD3<Float>,
                       active: [Int]) -> SIMD3<Float>? {
        var a = matrix, b = rhs
        for (index, column) in active.enumerated() {
            guard a[column][column] > 1e-10 else { return nil }
            for row in active.dropFirst(index + 1) {
                let factor = a[row][column] / a[column][column]
                for k in active.dropFirst(index) { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var result = SIMD3<Float>.zero
        for row in active.reversed() {
            var value = b[row]
            for k in active where k > row { value -= a[row][k] * result[k] }
            result[row] = value / a[row][row]
        }
        return result
    }
}
