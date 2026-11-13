import Foundation

extension PrinterProfile {
    public enum Matching: String, Sendable {
        case fixed, density, densityAndColor
    }

    public enum MatchingError: Error {
        case unsupportedMedium, invalidReference
    }

    public struct Match: Sendable {
        public let printer: PrinterProfile
        public let referenceRGB: SIMD3<Float>
        public let targetRGB: SIMD3<Float>
        /// Maximum absolute error in display-linear RGB, not a perceptual Delta E.
        public let residual: Float
        /// True when the requested match was not reached within the profile's constraints.
        public let limited: Bool
    }

    /// Adjusts this printer against a chosen developed-film reference patch. `targetDensity`
    /// is the desired reference film, printed under the fixed simulatedTungsten setup.
    /// Apply the returned printer to the entire frame. No pixelwise colour correction or
    /// automatic scene/skin selection occurs. Supply the developed stock used by the renderer.
    public func matching(_ mode: Matching, referenceDensity: SIMD3<Float>,
                         targetDensity: SIMD3<Float>, stock: FilmStock,
                         paper: PrintPaper = .ektacolorEdge,
                         enlarger: Enlarger = .diffuser, bleachBypass: Float = 0,
                         printViewingKelvin: Float? = nil,
                         printSurface: PrintSurface = .clean) throws -> Match {
        guard Enlarger.illuminates(stock: stock, paper: paper) else {
            throw MatchingError.unsupportedMedium
        }
        func array(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
        guard (array(referenceDensity) + array(targetDensity)).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw MatchingError.invalidReference
        }
        let callier = enlarger.callierCoefficient(for: stock, paper: paper)
        let silverCallier = callier == 1 ? Float(1) : Enlarger.silverCallierCoefficient
        let bleach = SpectralRuntime.retainedSilverFraction(bleachBypass, stock: stock)
        let dMin = stock.curves.map(\.dMin)
        let basis = stock.isReversal ? SpectralRuntime.neutralDensityBasis(for: stock) : nil
        func energy(_ density: [Float], _ p: PrinterProfile) -> SIMD3<Float> {
            SpectralRuntime.paperExposure(
                density: (basis?(density) ?? density).map { $0 * callier }, stock: stock,
                lamp: p.filteredSpectrum, paperSensitivity: paper.sensitivity,
                neutralDensity: silverCallier * SpectralRuntime.retainedSilverDensity(
                    density, dMin: dMin, fraction: bleach), densityScale: callier) * exp2(p.exposureEV)
        }
        let calibration = energy((0..<3).map { stock.developedDensity(layer: $0, logExposure: 0) }, .simulatedTungsten)
        let targetEnergy = energy(array(targetDensity), .simulatedTungsten)
        guard (array(calibration) + array(targetEnergy)).allSatisfy({ $0.isFinite && $0 > 1e-20 }) else {
            throw MatchingError.invalidReference
        }
        let curves = paper.printCurves(for: stock)
        let mids = paper.printExposureMidpoints(for: stock)
        let output = SpectralRuntime.tables(for: stock, paper: paper, bleachBypass: bleach,
                                           printViewingKelvin: printViewingKelvin,
                                           printSurface: printSurface, callier: callier,
                                           printer: .simulatedTungsten).paperOutput!
        func rgb(_ e: SIMD3<Float>) -> SIMD3<Float> {
            let value = output.sample(SIMD3((0..<3).map { c in
                let x = mids[c] + paper.exposureDirection * log10(max(e[c], 1e-20) / calibration[c])
                return (curves[c].density(logExposure: x) - curves[c].dMin)
                    / (curves[c].dMax - curves[c].dMin)
            }))
            // The renderer delivers a neutral print for a monochrome stock.
            return stock.isMonochrome ? SIMD3(repeating: (value.x + value.y + value.z) / 3) : value
        }
        let targetRGB = rgb(targetEnergy)
        let w = ColorScience.displayP3LuminanceWeights
        func luminance(_ v: SIMD3<Float>) -> Float { w.0 * v.x + w.1 * v.y + w.2 * v.z }
        var p = normalized
        func response(_ p: PrinterProfile) -> SIMD3<Float> { energy(array(referenceDensity), p) }
        func residual(_ p: PrinterProfile) -> SIMD3<Float> {
            let e = response(p)
            return SIMD3((0..<3).map { log(max(e[$0], 1e-20) / targetEnergy[$0]) })
        }
        func worst(_ v: SIMD3<Float>) -> Float { max(abs(v.x), max(abs(v.y), abs(v.z))) }
        func finish() -> Match {
            let reference = rgb(response(p))
            let limited: Bool
            switch mode {
            case .fixed: limited = false
            case .density: limited = abs(luminance(reference) - luminance(targetRGB)) > 1e-5
            case .densityAndColor: limited = worst(residual(p)) > 1e-4
            }
            return Match(printer: p, referenceRGB: reference, targetRGB: targetRGB,
                         residual: worst(reference - targetRGB), limited: limited)
        }
        if mode == .fixed { return finish() }
        if mode == .density {
            let target = paper.exposureDirection * luminance(targetRGB)
            func level(_ ev: Float) -> Float {
                var test = p; test.exposureEV = ev
                return paper.exposureDirection * luminance(rgb(response(test)))
            }
            if abs(level(p.exposureEV) - target) < 1e-7 { return finish() }
            var lo = Self.exposureRange.lowerBound, hi = Self.exposureRange.upperBound
            if target >= level(lo) { p.exposureEV = lo; return finish() }
            if target <= level(hi) { p.exposureEV = hi; return finish() }
            for _ in 0..<32 {
                let ev = (lo + hi) / 2
                if level(ev) > target { lo = ev } else { hi = ev }
            }
            p.exposureEV = (lo + hi) / 2
            return finish()
        }
        func shifted(_ source: PrinterProfile, axis: Int, by amount: Float) -> PrinterProfile {
            var value = source
            switch axis {
            case 0: value.exposureEV += amount
            case 1: value.magenta += amount
            default: value.yellow += amount
            }
            return value.normalized
        }
        func control(_ p: PrinterProfile, _ axis: Int) -> Float {
            axis == 0 ? p.exposureEV : axis == 1 ? p.magenta : p.yellow
        }
        func squared(_ v: SIMD3<Float>) -> Float { v.x * v.x + v.y * v.y + v.z * v.z }
        for _ in 0..<35 {
            let f = residual(p)
            if worst(f) < 2e-6 { break }
            var columns = [SIMD3<Float>]()
            for axis in 0..<3 {
                let lo = shifted(p, axis: axis, by: -0.001)
                let hi = shifted(p, axis: axis, by: 0.001)
                columns.append((residual(hi) - residual(lo)) / (control(hi, axis) - control(lo, axis)))
            }
            var a = (0..<3).map { row in [columns[0][row], columns[1][row], columns[2][row], -f[row]] }
            var singular = false
            for k in 0..<3 {
                let pivot = (k..<3).max { abs(a[$0][k]) < abs(a[$1][k]) }!
                if abs(a[pivot][k]) < 1e-8 { singular = true; break }
                a.swapAt(k, pivot)
                let divisor = a[k][k]
                for j in k..<4 { a[k][j] /= divisor }
                for i in 0..<3 where i != k {
                    let factor = a[i][k]
                    for j in k..<4 { a[i][j] -= factor * a[k][j] }
                }
            }
            if singular { break }
            var accepted = false
            var step: Float = 1
            for _ in 0..<11 {
                let candidate = PrinterProfile(lampKelvin: p.lampKelvin,
                    exposureEV: p.exposureEV + step * a[0][3],
                    magenta: p.magenta + step * a[1][3], yellow: p.yellow + step * a[2][3]).normalized
                if squared(residual(candidate)) < squared(f) {
                    p = candidate; accepted = true; break
                }
                step /= 2
            }
            if !accepted { break }
        }
        return finish()
    }

    /// Adjusts this already-timed optical printer so mid-grey on `paper` moves by `exposureStops`
    /// in luminance and adopts `balance` (`1 / whiteBalance.gains`) in chromaticity, solving
    /// directly through the paper's curves, Dichroic filtration and dye unmix rather than assuming
    /// a fixed scalar contrast.
    public func timed(exposureStops: Float, whiteBalanceGains balance: SIMD3<Float>,
                      stock: FilmStock, paper: PrintPaper, enlarger: Enlarger = .diffuser,
                      bleachBypass: Float = 0, printViewingKelvin: Float? = nil) -> PrinterProfile {
        let base = normalized
        guard Enlarger.illuminates(stock: stock, paper: paper),
              (exposureStops != 0 || balance != .one) else {
            return base
        }
        let callier = enlarger.callierCoefficient(for: stock, paper: paper)
        let silverCallier = callier == 1 ? Float(1) : Enlarger.silverCallierCoefficient
        let bleach = SpectralRuntime.retainedSilverFraction(bleachBypass, stock: stock)
        let dMin = stock.curves.map(\.dMin)
        let basis = stock.isReversal ? SpectralRuntime.neutralDensityBasis(for: stock) : nil
        let midDensity = (0..<3).map { stock.developedDensity(layer: $0, logExposure: 0) }
        func energy(_ density: [Float], _ p: PrinterProfile) -> SIMD3<Float> {
            SpectralRuntime.paperExposure(
                density: (basis?(density) ?? density).map { $0 * callier }, stock: stock,
                lamp: p.filteredSpectrum, paperSensitivity: paper.sensitivity,
                neutralDensity: silverCallier * SpectralRuntime.retainedSilverDensity(
                    density, dMin: dMin, fraction: bleach), densityScale: callier) * exp2(p.exposureEV)
        }
        let calibration = energy(midDensity, .simulatedTungsten)
        let reference = calibration * exp2(base.exposureEV)
        guard [reference.x, reference.y, reference.z].allSatisfy({ $0.isFinite && $0 > 1e-20 }) else {
            return base
        }
        let curves = paper.printCurves(for: stock)
        let mids = paper.printExposureMidpoints(for: stock)
        let receiver = SpectralRuntime.printReceiver(
            stock: stock, paper: paper,
            viewingLight: SpectralRuntime.viewingLight(for: paper, kelvin: printViewingKelvin))
        func rgb(_ p: PrinterProfile) -> SIMD3<Float> {
            let e = energy(midDensity, p)
            let density = SIMD3((0..<3).map { c in
                let x = mids[c] + paper.exposureDirection * log10(max(e[c], 1e-20) / reference[c])
                return curves[c].density(logExposure: x) - curves[c].dMin
            })
            let value = receiver.rgb(density: density)
            return stock.isMonochrome ? SIMD3(repeating: (value.x + value.y + value.z) / 3) : value
        }
        let w = ColorScience.displayP3LuminanceWeights
        func luminance(_ v: SIMD3<Float>) -> Float { w.0 * v.x + w.1 * v.y + w.2 * v.z }
        let paperWhite = receiver.rgb(density: .zero)
        let maxLuma = max(0.98 * luminance(paperWhite), 0.2)
        let baseRGB = rgb(base)
        let baseLuma = max(luminance(baseRGB), 1e-6)
        if stock.isMonochrome {
            let target = paper.exposureDirection * min(baseLuma * exp2(exposureStops), maxLuma)
            func level(_ ev: Float) -> Float {
                var test = base; test.exposureEV = ev
                return paper.exposureDirection * luminance(rgb(test))
            }
            var p = base
            var lo = Self.exposureRange.lowerBound, hi = Self.exposureRange.upperBound
            if target >= level(lo) { p.exposureEV = lo; return p.normalized }
            if target <= level(hi) { p.exposureEV = hi; return p.normalized }
            for _ in 0..<32 {
                let ev = (lo + hi) / 2
                if level(ev) > target { lo = ev } else { hi = ev }
            }
            p.exposureEV = (lo + hi) / 2
            return p.normalized
        }
        let chromatic = balance * (baseLuma / max(luminance(baseRGB * balance), 1e-6))
        let targetRGB = SIMD3((0..<3).map { c in
            min(max(baseRGB[c] * chromatic[c] * exp2(exposureStops), 1e-5),
                max(0.98 * paperWhite[c], 0.2))
        })
        func residual(_ p: PrinterProfile) -> SIMD3<Float> {
            let current = rgb(p)
            return SIMD3((0..<3).map { log(max(current[$0], 1e-6) / targetRGB[$0]) })
        }
        func shifted(_ source: PrinterProfile, axis: Int, by amount: Float) -> PrinterProfile {
            var value = source
            switch axis {
            case 0: value.exposureEV += amount
            case 1: value.magenta += amount
            default: value.yellow += amount
            }
            return value.normalized
        }
        func control(_ p: PrinterProfile, _ axis: Int) -> Float {
            axis == 0 ? p.exposureEV : axis == 1 ? p.magenta : p.yellow
        }
        func squared(_ v: SIMD3<Float>) -> Float { v.x * v.x + v.y * v.y + v.z * v.z }
        var p = base
        for _ in 0..<30 {
            let f = residual(p)
            if max(abs(f.x), max(abs(f.y), abs(f.z))) < 1e-4 { break }
            var columns = [SIMD3<Float>]()
            for axis in 0..<3 {
                let lo = shifted(p, axis: axis, by: -0.002)
                let hi = shifted(p, axis: axis, by: 0.002)
                let span = control(hi, axis) - control(lo, axis)
                columns.append(abs(span) > 1e-6 ? (residual(hi) - residual(lo)) / span : .zero)
            }
            let reg: Float = 1e-5
            var normal = [SIMD3<Float>](repeating: .zero, count: 3)
            var rhs = [Float](repeating: 0, count: 3)
            for j in 0..<3 {
                rhs[j] = -(columns[j] * f).sum()
                for k in 0..<3 {
                    normal[j][k] = (columns[j] * columns[k]).sum() + (j == k ? reg : 0)
                }
            }
            var a = (0..<3).map { row in [normal[row].x, normal[row].y, normal[row].z, rhs[row]] }
            var singular = false
            for k in 0..<3 {
                let pivot = (k..<3).max { abs(a[$0][k]) < abs(a[$1][k]) }!
                if abs(a[pivot][k]) < 1e-8 { singular = true; break }
                a.swapAt(k, pivot)
                let divisor = a[k][k]
                for j in k..<4 { a[k][j] /= divisor }
                for i in 0..<3 where i != k {
                    let factor = a[i][k]
                    for j in k..<4 { a[i][j] -= factor * a[k][j] }
                }
            }
            if singular { break }
            var accepted = false
            var step: Float = 1
            for _ in 0..<10 {
                let candidate = PrinterProfile(
                    lampKelvin: p.lampKelvin,
                    exposureEV: p.exposureEV + step * a[0][3],
                    magenta: p.magenta + step * a[1][3],
                    yellow: p.yellow + step * a[2][3]).normalized
                if squared(residual(candidate)) < squared(f) {
                    p = candidate; accepted = true; break
                }
                step *= 0.5
            }
            if !accepted { break }
        }
        return p.normalized
    }
}
