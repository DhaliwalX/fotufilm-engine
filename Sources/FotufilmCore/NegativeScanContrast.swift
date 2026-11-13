import Foundation

/// How steep a roll's records read against each other, from its pictures' tonal steps.
///
/// Light falling off across a surface, or a shadow lying on it, changes the exposure of every
/// record alike whatever the surface's colour. Across such a step each record's density rises by
/// its own contrast, so over a frame's many steps the rises of red and blue per unit of green
/// say how steep the records read against each other. Steps between surfaces of different
/// colours scatter around that without leaning one way, and unlike a frame's levels the steps
/// carry nothing of the light's own colour. Development, the film's age and what is assumed of
/// the scanning light all move this, and none of them changes along a roll.
extension ApproximateNegativeScan {
    /// How many steps a frame needs before its rises are told from them.
    static let tonalStepCount = 256
    /// How far green differs across a step, in density.
    static let tonalStep: Float = 0.1

    /// How red and blue rise per unit of green across the framed picture's tonal steps, in the
    /// scan channels' densities over `border`: the medians over pairs of pixels a little apart
    /// in the central 80% whose green differs by `tonalStep` or more. Nil for a frame with too
    /// few steps to tell.
    public static func tonalSlopes(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD2<Float>? {
        guard preview.width >= 2, preview.height >= 2,
              (0..<3).allSatisfy({ border[$0].isFinite && border[$0] > 0 }) else { return nil }
        let mx = preview.width / 10, my = preview.height / 10
        let width = preview.width - 2 * mx, height = preview.height - 2 * my
        var density = [[Float]](repeating: [Float](repeating: .nan, count: width * height),
                                count: 3)
        for y in 0..<height { for x in 0..<width {
            let i = (y + my) * preview.width + x + mx
            let pixel = (0..<3).map { preview.planes[$0][i] }
            guard pixel.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            for c in 0..<3 { density[c][y * width + x] = -log10(pixel[c] / border[c]) }
        } }
        // Far enough apart to span an edge the preview has softened.
        let apart = max(1, max(preview.width, preview.height) / 170)
        var red: [Float] = [], blue: [Float] = []
        func step(_ from: Int, _ to: Int) {
            let green = density[1][to] - density[1][from]
            guard abs(green) >= tonalStep else { return }
            let rises = SIMD2(density[0][to] - density[0][from],
                              density[2][to] - density[2][from]) / green
            guard rises.x.isFinite, rises.y.isFinite else { return }
            red.append(rises.x)
            blue.append(rises.y)
        }
        for y in 0..<height { for x in 0..<width {
            if x + apart < width { step(y * width + x, y * width + x + apart) }
            if y + apart < height { step(y * width + x, (y + apart) * width + x) }
        } }
        guard red.count >= tonalStepCount else { return nil }
        red.sort()
        blue.sort()
        return SIMD2(red[red.count / 2], blue[blue.count / 2])
    }

    /// How far a roll's steepness moves a record's gain.
    public static let contrastRange: ClosedRange<Float> = 0.7...1.5
    /// How far a single frame's own tonal steps may move a record's gain.
    public static let frameContrastRange: ClosedRange<Float> = 0.75...1.35

    /// The gains that make red and blue as steep against green as `stock`'s own grey scale,
    /// from how they rise across tonal steps (`slopes`, in the scan channels' densities) and
    /// what each record reads from the channels (`weights`), shrunk toward one in log space by
    /// `weight` (`1` on a roll, smaller on a single frame). Held inside `range`; one for a
    /// black-and-white film, or rises that read no record.
    static func contrast(stock: FilmStock, weights: [SIMD3<Float>],
                         slopes: SIMD2<Float>, weight: Float = 1,
                         range: ClosedRange<Float> = contrastRange) -> SIMD3<Float> {
        guard !stock.isMonochrome, weight > 0, let film = greyRise(stock) else { return .one }
        let read = NegativeScanCrosstalk.apply(weights, SIMD3(slopes.x, 1, slopes.y))
        var gains = SIMD3<Float>.one
        guard read.y.isFinite, read.y > 0 else { return gains }
        let w = min(max(weight, 0), 1)
        for record in [0, 2] where read[record].isFinite && read[record] > 0 {
            let raw = (film[record] / film.y) / (read[record] / read.y)
            let gain = w == 1 ? raw : pow(raw, w)
            gains[record] = min(max(gain, range.lowerBound), range.upperBound)
        }
        return gains
    }

    /// How far each record's density rises along the film's grey scale between the exposures
    /// that put green 0.2 and 1.2 over its base, where a picture's steps lie. Nil for a film
    /// too flat to have that span.
    static func greyRise(_ stock: FilmStock) -> SIMD3<Float>? {
        let green = stock.curves[1]
        let top = min(1.2, 0.8 * (green.dMax - green.dMin))
        guard top >= 0.5 else { return nil }
        let low = green.logExposure(density: green.dMin + 0.2)
        let high = green.logExposure(density: green.dMin + top)
        let rise = SIMD3((0..<3).map {
            stock.curves[$0].density(logExposure: high) - stock.curves[$0].density(logExposure: low)
        })
        guard (0..<3).allSatisfy({ rise[$0].isFinite && rise[$0] > 0.05 }) else { return nil }
        return rise
    }
}
