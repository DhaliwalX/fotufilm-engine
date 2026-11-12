import Foundation

/// The matrix a raw decoder mixed a camera's balanced channels into its picture with, found from
/// the picture itself where the decoder does not say (`NegativeScanSetup.matrix`).
///
/// A decoder balances each sensor channel on its white and mixes the three into the picture's
/// primaries: picture = E · D · sensor, with D the balance and E the matrix. The same pixels
/// decoded on a second white of the same colour temperature and another tint keep E and change D,
/// so the second picture is T = E · (D₂ D₁⁻¹) · E⁻¹ of the first: a linear map whose eigenvectors
/// are E's columns, each to the scale that takes balanced white to the picture's white.
public enum NegativeScanDecoderMatrix {
    /// Fewest pixels a recovery takes.
    static let fewestSamples = 64
    /// Samples at or over this in either decode may be clipped and are left out.
    static let ceiling: Float = 0.8
    /// How far the second decode may stray from a linear map of the first, as a fraction of its
    /// own level, before the two are not the one matrix under two balances.
    static let residual = 0.01
    /// How far apart the three channels' balance changes must be, as a fraction of the largest:
    /// channels whose balance changed alike cannot be told apart.
    static let separation = 0.02
    /// How far recoveries from different tints may differ in any entry and still be averaged.
    static let agreement: Float = 0.03

    /// The matrix behind `before` and `after`: the same pixels decoded on two whites that differ
    /// in tint alone, in the picture's linear primaries. Rows are the picture's red, green and
    /// blue over the sensor's balanced channels. Nil where the pair does not show one: too few
    /// usable pixels, a map that is not linear, or channels the tint moved alike.
    public static func recovered(before: [SIMD3<Float>], after: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard before.count == after.count,
              let map = linearMap(from: before, to: after),
              let values = eigenvalues(map) else { return nil }
        let scale = values.map(abs).max() ?? 0
        guard scale > 0 else { return nil }
        for i in 0..<3 {
            for j in (i + 1)..<3 where abs(values[i] - values[j]) < separation * scale { return nil }
        }
        // One eigenvector per balance change, each a column of the matrix at any scale.
        var columns: [SIMD3<Double>] = []
        for value in values {
            guard let vector = nullVector(map, value) else { return nil }
            columns.append(vector)
        }
        // Each sensor channel mostly makes its own channel of the picture, which orders them.
        var order: [Int] = []
        for row in 0..<3 {
            guard let column = (0..<3).max(by: { abs(columns[$0][row]) < abs(columns[$1][row]) })
            else { return nil }
            order.append(column)
        }
        guard Set(order).count == 3 else { return nil }
        let ordered = order.map { columns[$0] }
        // Balanced white is the picture's white: the columns add up to one in every row.
        guard let scales = solve(ordered, SIMD3<Double>(1, 1, 1)) else { return nil }
        let matrix = (0..<3).map { row in
            SIMD3<Float>(Float(ordered[0][row] * scales[0]), Float(ordered[1][row] * scales[1]),
                         Float(ordered[2][row] * scales[2]))
        }
        return plausible(matrix) ? matrix : nil
    }

    /// The matrix behind one decode and others of it on different tints: the mean of what each
    /// pair shows, where every pair shows one and they agree. Nil otherwise.
    public static func recovered(before: [SIMD3<Float>], tinted: [[SIMD3<Float>]]) -> [SIMD3<Float>]? {
        var found: [[SIMD3<Float>]] = []
        for after in tinted {
            guard let matrix = recovered(before: before, after: after) else { return nil }
            found.append(matrix)
        }
        guard let first = found.first else { return nil }
        for other in found.dropFirst() {
            for row in 0..<3 {
                let difference = other[row] - first[row]
                guard (0..<3).allSatisfy({ abs(difference[$0]) <= agreement }) else { return nil }
            }
        }
        return (0..<3).map { row in
            found.reduce(SIMD3<Float>.zero) { $0 + $1[row] } / Float(found.count)
        }
    }

    /// A matrix a decoder could have used: finite, each channel of the picture made mostly of its
    /// own sensor channel, nothing out of proportion.
    static func plausible(_ matrix: [SIMD3<Float>]) -> Bool {
        guard matrix.count == 3 else { return false }
        for row in 0..<3 {
            let own = matrix[row][row]
            guard own.isFinite, own > 0 else { return false }
            for column in 0..<3 {
                let entry = matrix[row][column]
                guard entry.isFinite, abs(entry) <= 4 else { return false }
                if column != row, abs(entry) >= own { return false }
            }
        }
        return true
    }

    /// The least-squares 3 × 3 map from `before` to `after`, rows of the result over `before`'s
    /// channels, where the pair is linear to within `residual`.
    static func linearMap(from before: [SIMD3<Float>], to after: [SIMD3<Float>]) -> [SIMD3<Double>]? {
        var normal = [SIMD3<Double>](repeating: .zero, count: 3)
        var cross = [SIMD3<Double>](repeating: .zero, count: 3)
        var used: [(SIMD3<Double>, SIMD3<Double>)] = []
        used.reserveCapacity(before.count)
        for (a, b) in zip(before, after) {
            guard (0..<3).allSatisfy({ a[$0].isFinite && b[$0].isFinite }),
                  a.min() > 0, b.min() > 0, a.max() < ceiling, b.max() < ceiling else { continue }
            let x = SIMD3<Double>(a), y = SIMD3<Double>(b)
            for row in 0..<3 {
                normal[row] += x[row] * x
                cross[row] += y[row] * x
            }
            used.append((x, y))
        }
        guard used.count >= fewestSamples else { return nil }
        // Each row of the map solves the same normal equations against its own channel.
        var map: [SIMD3<Double>] = []
        for row in 0..<3 {
            guard let solved = solve(columns(normal), cross[row]) else { return nil }
            map.append(solved)
        }
        var error = SIMD3<Double>.zero, level = SIMD3<Double>.zero
        for (x, y) in used {
            let fitted = SIMD3(dot(map[0], x), dot(map[1], x), dot(map[2], x))
            error += (fitted - y) * (fitted - y)
            level += y * y
        }
        for channel in 0..<3 {
            guard level[channel] > 0, (error[channel] / level[channel]).squareRoot() <= residual
            else { return nil }
        }
        return map
    }

    /// The three real eigenvalues of `matrix` (rows), nil where two are complex or equal.
    static func eigenvalues(_ matrix: [SIMD3<Double>]) -> [Double]? {
        let (a, b, c) = (matrix[0], matrix[1], matrix[2])
        let trace = a.x + b.y + c.z
        let minors = (a.x * b.y - a.y * b.x) + (a.x * c.z - a.z * c.x) + (b.y * c.z - b.z * c.y)
        let determinant = dot(a, cross(b, c))
        // λ³ − trace·λ² + minors·λ − determinant, with λ = x + trace / 3: x³ + p·x + q.
        let shift = trace / 3
        let p = minors - 3 * shift * shift
        let q = -2 * shift * shift * shift + minors * shift - determinant
        guard p.isFinite, q.isFinite, 4 * p * p * p + 27 * q * q < 0 else { return nil }
        let radius = 2 * (-p / 3).squareRoot()
        let angle = acos(min(max(3 * q / (2 * p) * (-3 / p).squareRoot(), -1), 1)) / 3
        return (0..<3).map { shift + radius * cos(angle - 2 * .pi * Double($0) / 3) }
    }

    /// A vector `matrix − value` takes to nothing, at unit length: the eigenvector of `value`.
    static func nullVector(_ matrix: [SIMD3<Double>], _ value: Double) -> SIMD3<Double>? {
        var rows = matrix
        for i in 0..<3 { rows[i][i] -= value }
        // The rows span a plane; the vector is across it, taken from the pair that says so best.
        let candidates = [cross(rows[0], rows[1]), cross(rows[0], rows[2]), cross(rows[1], rows[2])]
        guard let best = candidates.max(by: { dot($0, $0) < dot($1, $1) }) else { return nil }
        let length = dot(best, best).squareRoot()
        guard length.isFinite, length > 0 else { return nil }
        return best / length
    }

    /// The weights of `columns` that add up to `target`, by Cramer's rule.
    static func solve(_ columns: [SIMD3<Double>], _ target: SIMD3<Double>) -> SIMD3<Double>? {
        let whole = dot(columns[0], cross(columns[1], columns[2]))
        guard whole.isFinite, abs(whole) > 1e-12 else { return nil }
        let solved = SIMD3(dot(target, cross(columns[1], columns[2])),
                           dot(columns[0], cross(target, columns[2])),
                           dot(columns[0], cross(columns[1], target))) / whole
        return (0..<3).allSatisfy({ solved[$0].isFinite }) ? solved : nil
    }

    private static func columns(_ rows: [SIMD3<Double>]) -> [SIMD3<Double>] {
        (0..<3).map { SIMD3(rows[0][$0], rows[1][$0], rows[2][$0]) }
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
