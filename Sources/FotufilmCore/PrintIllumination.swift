import Foundation

extension SpectralRuntime {
    /// Exposure light, separate from the lamp used to view the finished print. Release
    /// printing mixes independently timed RGB beams before they pass through the negative.
    /// Every receiving layer integrates the whole mixture, retaining spectral crosstalk.
    static func printingLamp(paper: PrintPaper, density: [Float], dyes: [[Float]],
                             neutralDensity: Float = 0) -> [Float] {
        guard paper.isProjected else {
            return paper.isScan ? SpectralGrid.equalEnergy : SpectralGrid.enlarger3200K
        }
        let beams = SpectralGrid.releasePrinterBeams
        let response = beams.map {
            paperExposure(density: density, dyes: dyes, lamp: $0,
                          paperSensitivity: paper.sensitivity,
                          neutralDensity: neutralDensity)
        }
        // Normalize columns before solving so a dense orange mask does not make the
        // blue light numerically insignificant. Sensitivities are relative; absolute
        // printer speed and per-record offsets are supplied by the curve anchors.
        let norms = response.map { max(max($0.x, max($0.y, $0.z)), 1e-12) }
        let columns = zip(response, norms).map { $0 / $1 }
        var lights = SIMD3<Float>(repeating: 1)
        func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            a.x * b.x + a.y * b.y + a.z * b.z
        }
        // Non-negative least squares: an unreachable target can close a light, never
        // subtract photons. Three-variable coordinate descent also handles overlapping
        // or nearly dependent receiver bands without an unstable matrix inverse.
        var residual = columns[0] + columns[1] + columns[2] - SIMD3(repeating: 1)
        for _ in 0..<64 {
            for channel in 0..<3 {
                let column = columns[channel]
                let next = max(0, lights[channel]
                    - dot(column, residual) / max(dot(column, column), 1e-12))
                residual += column * (next - lights[channel])
                lights[channel] = next
            }
        }
        let weights = SIMD3(lights.x / norms[0], lights.y / norms[1],
                            lights.z / norms[2])
        let lamp = (0..<SpectralGrid.count).map { i in
            beams[0][i] * weights.x + beams[1][i] * weights.y + beams[2][i] * weights.z
        }
        let peak = max(lamp.max() ?? 0, 1e-12)
        return lamp.map { $0 / peak }
    }
}

extension SpectralGrid {
    /// Idealized additive printer filters on a 3200 K tungsten source, in R/G/B order.
    /// H-1-2383/2393 specify 2043 heat-absorbing glass with UV filtration; Fuji
    /// 3513DI specifies SC-41 plus 2043 on a Bell & Howell Model C. Neither source
    /// supplies complete dichroic transmission curves. These broad, tapered passbands
    /// are an approximation, not measured 2043, Series 1700, or SC-41 spectra.
    /// UV below 400 nm and the far-red/IR tail above 730 nm are excluded. The 10 nm
    /// UV transition approximates a 410 nm cut; inter-band overlap is retained.
    static let releasePrinterBeams: [[Float]] = [
        (Float(590), Float(610), Float(700), Float(730)),
        (Float(490), Float(510), Float(580), Float(610)),
        (Float(400), Float(410), Float(480), Float(500)),
    ].map { low, rise, fall, high in
        zip(wavelengths, enlarger3200K).map { wavelength, energy in
            let transmission = max(0, min(1, min((wavelength - low) / (rise - low),
                                                 (high - wavelength) / (high - fall))))
            return energy * transmission
        }
    }
}
