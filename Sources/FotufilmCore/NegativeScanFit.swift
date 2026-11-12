import Foundation

/// A reading fitted on the scan model: what each film record reads of the scan's three channel
/// densities over clear film, so the densities read are the ones that made the scan.
///
/// A scan's channel is broader than the dye it is read for and sees the film's other dyes and
/// its mask, and a broad channel reads less density than the dye has at its peak, since light the
/// dye passes fills it. The fit takes both from the film's own spectra under the scan's lamp and
/// camera (`NegativeScanSetup`): the film's greys and the colours about them
/// (`NegativeScanModel.patches`) are scanned as the model sees them, and the weights are the
/// least squares from their channel densities back to their record densities.
extension NegativeScanModel {
    /// The weights: rows are records, columns the scan's red, green and blue densities over the
    /// clear film. `separation` runs from each record read from its own channel alone, scaled so
    /// the film's greys keep their densities (0), to the full fit across the channels (1).
    /// Patches a channel reads no light of are left out. One channel per record at unit weight
    /// where the patches cannot tell the records apart.
    public func weights(separation: Float) -> [SIMD3<Float>] {
        weights(separation: separation, patches: Self.patches(stock: stock))
    }

    func weights(separation: Float, patches: [Patch]) -> [SIMD3<Float>] {
        if stock.isMonochrome { return Array(repeating: SIMD3(0, 1, 0), count: 3) }
        return Self.weights(separation: separation, readings: patches.compactMap { patch in
            scannerDensity(density: patch.density).map { read in
                Reading(scanner: read,
                        target: SIMD3((0..<3).map { patch.density[$0] - base[$0] }),
                        weight: patch.weight, isNeutral: patch.isNeutral)
            }
        })
    }

    /// One patch as a fit takes it: the scan channels' densities over the clear film, and the
    /// densities over the clear film that made them.
    struct Reading {
        var scanner: SIMD3<Float>
        var target: SIMD3<Float>
        var weight: Float
        var isNeutral: Bool
    }

    /// The least squares from `readings`' channel densities back to their targets, `separation`
    /// of the way from each target's own channel alone, scaled to keep the greys.
    static func weights(separation: Float, readings: [Reading]) -> [SIMD3<Float>] {
        let identity = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        // In double precision: a camera's channels overlap, and the moments of their densities
        // are too nearly dependent to solve in single.
        var moments = [SIMD3<Double>](repeating: .zero, count: 3)
        var products = [SIMD3<Double>](repeating: .zero, count: 3)
        var greyMoments = SIMD3<Double>.zero, greyProducts = SIMD3<Double>.zero
        for reading in readings {
            let scanner = SIMD3<Double>(reading.scanner), weight = Double(reading.weight)
            let target = SIMD3<Double>(reading.target)
            for row in 0..<3 {
                moments[row] += weight * scanner[row] * scanner
                products[row] += weight * target[row] * scanner
            }
            if reading.isNeutral {
                greyMoments += weight * scanner * scanner
                greyProducts += weight * scanner * target
            }
        }
        guard (0..<3).allSatisfy({ greyMoments[$0] > 1e-6 }) else { return identity }
        let slopes = greyProducts / greyMoments
        let own = (0..<3).map { identity[$0] * Float(slopes[$0]) }
        let strength = separation.isFinite
            ? min(max(separation, NegativeScanCrosstalk.range.lowerBound),
                  NegativeScanCrosstalk.range.upperBound) : 0
        guard strength > 0 else { return own }
        var full: [SIMD3<Float>] = []
        for record in 0..<3 {
            guard let row = Self.solve(moments, products[record]) else { return own }
            full.append(SIMD3<Float>(row))
        }
        return (0..<3).map { own[$0] + strength * (full[$0] - own[$0]) }
    }

    /// `x` where `rows · x = right`, by elimination on the largest pivot. Nil where the rows
    /// are dependent.
    private static func solve(_ rows: [SIMD3<Double>], _ right: SIMD3<Double>) -> SIMD3<Double>? {
        var a = rows, b = right
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard abs(a[pivot][column]) > 1e-9 else { return nil }
            a.swapAt(column, pivot)
            (b[column], b[pivot]) = (b[pivot], b[column])
            for row in 0..<3 where row != column {
                let factor = a[row][column] / a[column][column]
                a[row] -= factor * a[column]
                b[row] -= factor * b[column]
            }
        }
        let x = SIMD3((0..<3).map { b[$0] / a[$0][$0] })
        return (0..<3).allSatisfy({ x[$0].isFinite }) ? x : nil
    }
}
