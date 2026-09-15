import Foundation

/// Fixed spectral receiver for color negatives on Digital Reference. Equal-energy illumination
/// reads the developed image dyes through broad RA-4 sensitivity bands. A common density matrix
/// separates their overlap against the public synthetic negative dye basis, then a common curve
/// delivers the records directly in Display P3. These are explicit modeling choices, not
/// measurements of a scanner or display. No capture-stock inverse is applied.
///
/// Only the stock's reference exposure is balanced. Its layer contrast, toe/shoulder differences,
/// and spectral dye interactions survive at other exposures and for chromatic subjects.
enum DigitalReferenceReceiver {
    static let illuminant = SpectralGrid.equalEnergy
    static let sensitivity = SpectralGrid.paperSensitivity

    /// Common digital density scale, independent of the selected negative's legacy paper curve.
    /// Retains the previous still-film display range without fitting away stock differences.
    static let curve = CharacteristicCurve(
        dMin: 0.07, gamma: 2.60, toe: -0.52, toeWidth: 0.16,
        shoulder: 0.42, shoulderWidth: 0.14)

    /// The receiver's small-signal density response at a neutral synthetic negative. Because
    /// the reference dyes partition unity, equal amounts transmit a constant spectrum. The
    /// derivative of measured density is therefore the band-weighted mean of each dye.
    /// This characterizes the receiver once, without looking at a selected stock or its curves.
    private static let densityUnmix: [SIMD3<Float>] = {
        let dyes = SpectralGrid.dyes(family: .kodakNegative)
        let rows: [SIMD3<Float>] = (0..<3).map { band in
            var response = SIMD3<Float>(repeating: 0)
            var total: Float = 0
            for i in 0..<SpectralGrid.count {
                let weight = illuminant[i] * sensitivity[band][i]
                total += weight
                for dye in 0..<3 { response[dye] += weight * dyes[dye][i] }
            }
            return response / total
        }
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
                  a.x * b.y - a.y * b.x)
        }
        let a = cross(rows[1], rows[2])
        let b = cross(rows[2], rows[0])
        let c = cross(rows[0], rows[1])
        // Transpose the cofactors into inverse rows. Normalizing their sums cancels the
        // common determinant and holds an equal-channel exposure exactly on the neutral axis.
        return (0..<3).map { i in
            let row = SIMD3(a[i], b[i], c[i])
            return row / (row.x + row.y + row.z)
        }
    }()

    static func read(_ relativeLogEnergy: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(densityUnmix.map { row in
            row.x * relativeLogEnergy.x + row.y * relativeLogEnergy.y
                + row.z * relativeLogEnergy.z
        })
    }

    /// Digital output has display primaries, not a second set of photographic paper dyes.
    static func rgb(density: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(10, -density.x), pow(10, -density.y), pow(10, -density.z))
    }
}
