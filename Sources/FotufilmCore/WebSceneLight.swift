import Foundation

/// Build-time export of the native exposure-domain reconstruction. The browser integrates
/// these shared spectra under the capture light; no per-temperature film packs are needed.
public enum WebSceneLight {
    // Each cell carries a signed reconstructed spectrum, then two spectral-locus
    // band indices and their luminance weights. Clamp the integrated continuation,
    // not its individual bands, before adding the monochromatic contribution.
    public static let stride = SpectralGrid.count + 4

    public static func geometry() -> [Float]? {
        guard let model = MeasuredReflectanceTable.shared else { return nil }
        let bands = SpectralGrid.count, d = SpectralRuntime.lutDimension
        var values = [Float](repeating: 0, count: d * d * d * stride)
        func spectrum(_ rgb: SIMD3<Float>) -> [Float] {
            let peak = max(rgb.x, rgb.y, rgb.z)
            guard peak > 0 else { return [Float](repeating: 0, count: bands) }
            let radiance = peak / SpectralRuntime.reconstructionAnchor
            return model.reflectance(rgb / radiance).map { $0 * radiance }
        }
        for z in 0..<d { for y in 0..<d { for x in 0..<d {
            let point = SIMD3(Float(x), Float(y), Float(z)) / Float(d - 1)
            let light = SpectralRuntime.sceneLight(ColorScience.linearExposureDomainToRec2020(point))
            let offset = ((z * d + y) * d + x) * stride
            var reflected = [Float](repeating: 0, count: bands)
            switch light {
            case .none: break
            case .reflectance(let rgb): reflected = spectrum(rgb)
            case .extrapolated(let face, let mirror):
                let a = spectrum(face), b = spectrum(mirror)
                reflected = (0..<bands).map { 2 * a[$0] - b[$0] }
            case .locus(let mono):
                let a = spectrum(mono.face), b = spectrum(mono.mirror)
                reflected = (0..<bands).map { (1 - mono.share) * (2 * a[$0] - b[$0]) }
                values[offset + bands] = Float(mono.lowerBand)
                values[offset + bands + 1] = Float(mono.upperBand)
                values[offset + bands + 2] = mono.share * mono.luminance * (1 - mono.upperShare)
                    / max(SpectralGrid.yBar[mono.lowerBand], 1e-12)
                values[offset + bands + 3] = mono.share * mono.luminance * mono.upperShare
                    / max(SpectralGrid.yBar[mono.upperBand], 1e-12)
            }
            values.replaceSubrange(offset..<(offset + bands), with: reflected)
        } } }
        return values
    }

    public static func catalog(stocks supplied: [(String, FilmStock)]) -> [String: Any] {
        let stocks: [[String: Any]] = supplied.map { id, stock in
            let rows = Array(stock.spectralProfile.layerSensitivity.prefix(3))
                + (stock.donorLayers.first.map { [$0.sensitivity] } ?? [])
            let reference = SpectralRuntime.filmReferenceIlluminant(for: stock)
            let referenceY = Illuminant.luminance(reference)
            let denominators = rows.map { row in
                (0..<SpectralGrid.count).reduce(Float(0)) {
                    $0 + reference[$1] / referenceY * row[$1]
                }
            }
            return ["id": id, "sensitivity": rows, "denominators": denominators]
        }
        return ["version": 2, "dimension": SpectralRuntime.lutDimension,
                "bands": SpectralGrid.count, "stride": stride,
                "wavelengths": SpectralGrid.wavelengths, "yBar": SpectralGrid.yBar,
                "daylight": [Illuminant.s0, Illuminant.s1, Illuminant.s2], "stocks": stocks]
    }
}
