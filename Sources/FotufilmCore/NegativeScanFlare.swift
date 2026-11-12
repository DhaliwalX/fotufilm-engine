import Foundation

/// A scan's stray light: what the lens and the room add to every sample alike. A reading takes
/// it off before a density is read (`ApproximateNegativeScan.flare`), since left in it reads the
/// densest film thinner than it is. It is set as a share of the frame's light, or measured from
/// the holder where the scan shows one, which passes no light of its own.
extension ApproximateNegativeScan {
    /// The shares of a frame's average light a scan's stray light can be set to.
    public static let flareShares: ClosedRange<Float> = 0...0.02

    /// The framed picture's average light, linear scan RGB: the mean over the central 80%,
    /// which keeps the holder out, of the samples that are numbers, none counted under zero.
    /// Nil for a frame too small to read.
    public static func frameLight(preview: ImageBuffer) -> SIMD3<Float>? {
        guard preview.width >= 2, preview.height >= 2 else { return nil }
        let mx = preview.width / 10, my = preview.height / 10
        var sum = SIMD3<Double>.zero
        var count = 0
        for y in my..<(preview.height - my) { for x in mx..<(preview.width - mx) {
            let i = y * preview.width + x
            let pixel = SIMD3((0..<3).map { preview.planes[$0][i] })
            guard (0..<3).allSatisfy({ pixel[$0].isFinite }) else { continue }
            sum += SIMD3<Double>(pixel.replacing(with: 0, where: pixel .< 0))
            count += 1
        } }
        guard count >= 16 else { return nil }
        return SIMD3<Float>(sum / Double(count))
    }

    /// The stray light of a whole scan that shows its holder, linear scan RGB: what its
    /// holder shows (`holderLight`), no more than the largest share of the scan's middle's
    /// average light a scan's is set to. Nil where no holder shows, or it shows no light.
    public static func strayLight(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        holder(border: border, preview: preview)?.stray
    }

    /// The light a whole scan's holder shows, linear scan RGB, which passes none of its own.
    /// The holder is taken to be in view only where the darkest twentieth of the scan lies
    /// around its edge, is even to within a stop, and is darker than the densest film in the
    /// scan's middle by a stop or more in every channel: a dense sky or a lamp at the picture's
    /// edge is none of these. Its light is that twentieth's lower quartile. Nil where no holder
    /// shows, or the holder shows no light.
    public static func holderLight(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        holder(border: border, preview: preview)?.light
    }

    /// A framed picture with the scan's holder left out, for what a reading measures of the
    /// frame: its densest end, which times the print, would otherwise be the holder's, where a
    /// scan shows much of one. A pixel is the holder's where its density over `border`, the mean
    /// of its channels', is past `limit` (`holder(border:preview:)`), or it passes no light, or
    /// it lies beside one that is; it is made no number, which the measures pass over.
    public static func withoutHolder(_ preview: ImageBuffer, border: SIMD3<Float>,
                                     limit: Float) -> ImageBuffer {
        let width = preview.width, height = preview.height
        var holder = [Bool](repeating: false, count: preview.pixelCount)
        for i in 0..<preview.pixelCount {
            let pixel = SIMD3((0..<3).map { preview.planes[$0][i] })
            holder[i] = !((0..<3).allSatisfy({ pixel[$0].isFinite && pixel[$0] > 0 })
                && (0..<3).reduce(Float(0), { $0 - log10(pixel[$1] / border[$1]) }) / 3 <= limit)
        }
        // The holder's edge is blurred into the film beside it: those pixels read denser than
        // any film and off its colour, so the holder is grown over them, by a hundredth of the
        // frame's long edge.
        let reach = max(2, max(width, height) / holderEdge)
        var across = holder
        for y in 0..<height { for x in 0..<width where !holder[y * width + x] {
            let from = max(0, x - reach), to = min(width - 1, x + reach)
            across[y * width + x] = (from...to).contains { holder[y * width + $0] }
        } }
        var film = preview
        for y in 0..<height { for x in 0..<width {
            let from = max(0, y - reach), to = min(height - 1, y + reach)
            if (from...to).contains(where: { across[$0 * width + x] }) {
                for c in 0..<3 { film.planes[c][y * width + x] = .nan }
            }
        } }
        return film
    }

    /// The frame's long edge over how far a holder is grown past its limit.
    static let holderEdge = 100

    /// Both of the above from one look at the scan, and where the holder ends: `limit` is the
    /// density over the clear film, the mean of a pixel's channels', past which a pixel is the
    /// holder's. A holder's light is uneven and its edge is blurred into the film's, so the
    /// limit is where the fewest pixels lie between the densest film in the scan's middle and
    /// the holder: film denser than the middle's, a sky at the picture's edge, stays film.
    public static func holder(border: SIMD3<Float>, preview: ImageBuffer)
        -> (light: SIMD3<Float>, stray: SIMD3<Float>, limit: Float)? {
        let width = preview.width, height = preview.height
        guard width >= 16, height >= 16,
              (0..<3).allSatisfy({ border[$0].isFinite && border[$0] > 0 }) else { return nil }
        // Each pixel that is a number, with the light it passes as shares of the clear film's.
        var pixels: [(index: Int, light: Float)] = []
        pixels.reserveCapacity(preview.pixelCount)
        func sample(_ i: Int) -> SIMD3<Float>? {
            let pixel = SIMD3((0..<3).map { preview.planes[$0][i] })
            guard (0..<3).allSatisfy({ pixel[$0].isFinite }) else { return nil }
            return pixel.replacing(with: 0, where: pixel .< 0)
        }
        for i in 0..<preview.pixelCount {
            guard let pixel = sample(i) else { continue }
            pixels.append((i, (pixel / border).sum()))
        }
        guard pixels.count >= 320 else { return nil }
        let mx = width / 5, my = height / 5
        func central(_ i: Int) -> Bool {
            let x = i % width, y = i / width
            return x >= mx && x < width - mx && y >= my && y < height - my
        }
        let count = max(16, pixels.count / 20)
        pixels.sort { $0.light < $1.light || ($0.light == $1.light && $0.index < $1.index) }
        let dark = pixels.prefix(count)
        // Around the edge, and even.
        let outside = dark.reduce(0) { $0 + (central($1.index) ? 0 : 1) }
        guard outside * 5 >= count * 4 else { return nil }
        let low = dark[dark.startIndex + (count - 1) / 10].light
        let high = dark[dark.startIndex + (count - 1) * 9 / 10].light
        guard low > 0, high <= 2 * low else { return nil }
        // Darker than any film in the middle.
        var middle = [[Float]](repeating: [], count: 3)
        for i in 0..<preview.pixelCount where central(i) {
            guard let pixel = sample(i) else { continue }
            for c in 0..<3 { middle[c].append(pixel[c]) }
        }
        guard middle[0].count >= 16 else { return nil }
        var light = SIMD3<Float>.zero, stray = SIMD3<Float>.zero, densest = SIMD3<Float>.zero
        for c in 0..<3 {
            let values = dark.map { preview.planes[c][$0.index] }.map { max($0, 0) }.sorted()
            let holder = values[(count - 1) / 4]
            let film = middle[c].sorted()
            densest[c] = film[(film.count - 1) / 1000]
            guard holder * 2 <= densest[c] else { return nil }
            let mean = film.reduce(Float(0), +) / Float(film.count)
            light[c] = holder
            stray[c] = min(holder, flareShares.upperBound * mean)
        }
        guard light.min() > 0, densest.min() > 0 else { return nil }
        // The fewest pixels between the middle's densest film and the holder.
        let density = { (v: SIMD3<Float>) -> Float in
            (0..<3).reduce(Float(0)) { $0 - log10(v[$1] / border[$1]) } / 3
        }
        let from = density(densest), to = density(light)
        let bins = Int((to - from) / holderBin)
        guard bins >= 2 else { return (light, stray, (from + to) / 2) }
        var counts = [Float](repeating: 0, count: bins)
        for i in 0..<preview.pixelCount {
            guard let pixel = sample(i), pixel.min() > 0 else { continue }
            let bin = Int(((density(pixel) - from) / holderBin).rounded(.down))
            if bin >= 0, bin < bins { counts[bin] += 1 }
        }
        let smoothed = counts.indices.map { i in
            (counts[max(i - 1, 0)] + 2 * counts[i] + counts[min(i + 1, bins - 1)]) / 4
        }
        // The middle of the widest stretch as empty as the emptiest step, so film a little
        // denser than the scan's middle shows stays on the film's side.
        let empty = (smoothed.min() ?? 0) + Float(preview.pixelCount) * 0.0005
        var best = 0..<1, run: Range<Int>? = nil
        for i in 0...bins {
            if i < bins, smoothed[i] <= empty {
                run = (run?.lowerBound ?? i)..<(i + 1)
            } else if let ended = run {
                if ended.count > best.count || smoothed[best.lowerBound] > empty { best = ended }
                run = nil
            }
        }
        return (light, stray, from + Float(best.lowerBound + best.upperBound) / 2 * holderBin)
    }

    /// The width, in density, of the steps the holder's limit is looked for in.
    static let holderBin: Float = 0.05
}
