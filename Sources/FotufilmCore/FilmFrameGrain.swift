import Foundation

/// Film grain laid crystal by crystal over a whole frame, for finished stills.
///
/// The tiles lay a frame from a square of film 256 µm a side, so every patch of it recurs across
/// the frame in eight orientations, and magnified a still shows its features again and again.
/// Here the film is the tiles' own — the same texels, samples, crystals and clouds — laid once
/// over the whole frame, with each crystal developed at the frame's own density where it sits.
/// Its tone and strength are the tiles' to the statistics: the mean a pixel's footprint reads is
/// the tiles' table at that pitch.
extension FilmGrain {
    /// Whether this host can lay frame grain.
    public static var laysFrameGrain: Bool {
        #if canImport(Metal)
        FilmFrameMetalRenderer.shared != nil
        #else
        false
        #endif
    }

    /// The film seed a frame of `seed` is laid from: the tiles' coating, another stretch of it per
    /// frame seed.
    static func frameFilmSeed(_ seed: UInt32) -> UInt64 {
        tileSeed ^ (UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
    }

    /// Samples a texel side the frame film of record `r` is laid at: the tiles' own for silver
    /// grains, which are as small as a sample; two for dye clouds, whose grain reads within a
    /// percent of the tiles' sampling at every pitch and costs half as much.
    func frameSupersample(_ r: Int) -> Int {
        records[r].sublayers.contains { $0.profile == .silverGrain }
            ? Self.supersample(pxPerMM: 1 / Self.tileTexelMM) : 2
    }

    /// The stretch of film a frame's mean densities are read from.
    static let frameMeanSeed: UInt64 = tileSeed ^ 0x5A3F_1E1D_0000_0000

    #if canImport(Metal)
    /// Record `r` as the frame renderer lays it, its crystals hashed from `seed`.
    func frameRecord(_ r: Int, seed: UInt64, supersample s: Int) -> FilmFrameMetalRenderer.Record? {
        let record = records[r]
        guard !record.sublayers.isEmpty else { return nil }
        let h = Self.tileTexelMM / Float(s)
        let golden: UInt32 = 0x9E37_79B9
        let base = FilmRandom.seed32(seed)
        // A silver grain's covered area against its peak, to the largest peak a crystal's draw
        // reaches in practice.
        let silverEdges = record.sublayers.filter { $0.profile == .silverGrain }.map(\.edge)
        let areaCount = 512
        let maxPeak = (silverEdges.max() ?? 0) * 16
        let areas = maxPeak > 0
            ? (0..<areaCount).map { Self.occupiedArea(peak: Float($0) * maxPeak / Float(areaCount - 1),
                                                       profile: .silverGrain) }
            : []
        var reach: Float = 0
        let sublayers = record.sublayers.enumerated().map { b, layer -> FilmFrameMetalRenderer.Sublayer in
            let stream = UInt32(truncatingIfNeeded: r * 8 + b * 2)
            let cell = layer.cellMM
            let thresholds = FilmRandom.countThresholds(mean: layer.coatedPerMM2 * cell * cell)
            let limit = max(thresholds.lastIndex(where: { $0 < 1 }).map { $0 + 1 } ?? 0, 1)
            let sigma = layer.sigmaMM / h
            let silver = layer.profile == .silverGrain
            let terms: [(sigma: Float, scale: Float)]
            if silver {
                // Each grain's Gaussian, less the variance its linear deposit adds, carries
                // `2π σ²` of demand at peak 1 as the reference lays it point by point.
                let width = max(sigma * sigma - 1.0 / 6, 0.01).squareRoot()
                terms = [(width, 2 * Float.pi * sigma * sigma)]
                let widest = areas.last.map { sigma * $0.squareRoot() / 2 } ?? 0
                reach = max(reach, (4.2 * sigma + widest + 1) / Float(s))
            } else {
                terms = Self.dyeCloudTerms.map {
                    ($0.sigma * sigma, $0.weight * 2 * Float.pi * ($0.sigma * sigma) * ($0.sigma * sigma))
                }
                reach = max(reach, (3.5 * Self.dyeCloudTerms.last!.sigma * sigma + 1) / Float(s))
            }
            return FilmFrameMetalRenderer.Sublayer(
                silver: silver, cellTexels: cell / Self.tileTexelMM, limit: limit,
                thresholds: thresholds, forming: layer.forming,
                edge: layer.peakDemand / layer.capacity, capacity: layer.capacity,
                resolvedShare: silver ? min(max((sigma - 0.5) / 1.5, 0), 1) : 1,
                terms: terms, sigmaSamples: sigma,
                crystalBase: base ^ (stream &* golden), countBase: base ^ ((stream &+ 1) &* golden))
        }
        return FilmFrameMetalRenderer.Record(
            sublayers: sublayers, dMin: record.dMin,
            tableScale: Float(Self.tableSamples - 1) / max(record.dMax - record.dMin, 1e-6),
            areas: areas, areaStep: maxPeak / Float(areaCount - 1), reachTexels: reach)
    }
    #endif
}

extension FilmGrain.TileBinding {
    /// Lays this film's grain over `density`, a frame of interleaved developed gross densities
    /// (`channels` per pixel, the records first), crystal by crystal for a frame of `pxPerMM`,
    /// scaled by `amount` and laid as `look` lays it, the colour mix included: what the kernel's
    /// grain stage adds, without its tiles. False, leaving `density` as it was, where the host
    /// cannot lay it or `shouldContinue` stops it.
    public func addFrameGrain(to density: UnsafeMutableBufferPointer<Float>, channels: Int,
                              width: Int, height: Int, pxPerMM: Float, amount: Float,
                              look: FilmGrain.Look, seed: UInt32,
                              shouldContinue: () -> Bool = { true }) -> Bool {
        guard let planes = frameGrain(density: UnsafeBufferPointer(density), channels: channels,
                                      width: width, height: height, pxPerMM: pxPerMM,
                                      amount: amount, look: look, seed: seed,
                                      shouldContinue: shouldContinue)
        else { return false }
        let count = width * height
        if grain.monochrome {
            let plane = planes[1]
            guard !plane.isEmpty else { return true }
            for i in 0..<count {
                for c in 0..<min(channels, 3) { density[i * channels + c] += plane[i] }
            }
            return true
        }
        let (own, shared) = FilmGrain.Look.mix(colour: look.colour)
        for i in 0..<count {
            let g = planes.map { $0.isEmpty ? 0 : $0[i] }
            let mean = (g[0] + g[1] + g[2]) / 3
            for c in 0..<min(channels, 3) { density[i * channels + c] += own * g[c] + shared * mean }
        }
        return true
    }

    /// Each record's grain before the colour mix, `width × height`; empty for a record with
    /// none. With `raw`, the density each pixel's footprint reads instead.
    func frameGrain(density: UnsafeBufferPointer<Float>, channels: Int, width: Int, height: Int,
                    pxPerMM: Float, amount: Float, look: FilmGrain.Look, seed: UInt32,
                    raw: Bool = false, shouldContinue: () -> Bool) -> [[Float]]? {
        #if canImport(Metal)
        guard let renderer = FilmFrameMetalRenderer.shared, width > 0, height > 0, channels >= 3,
              density.count >= width * height * channels else { return nil }
        let geometry = look.geometry(pxPerMM: pxPerMM)
        let amounts = look.recordAmounts(amount)
        let filmSeed = FilmGrain.frameFilmSeed(seed)
        var planes = [[Float]](repeating: [], count: 3)
        for r in grain.monochrome ? [1] : [0, 1, 2] where !tiles.levels[r].isEmpty {
            let s = grain.frameSupersample(r)
            guard let record = grain.frameRecord(r, seed: filmSeed, supersample: s),
                  let means = raw ? [0, 0] : frameMeans(r, renderer: renderer, pitch: geometry.pitch,
                                                        footprint: geometry.footprint, supersample: s,
                                                        shouldContinue: shouldContinue)
            else { return nil }
            let plane = (0..<(width * height)).map { density[$0 * channels + r] }
            guard let out = renderer.render(
                record: record, density: plane, width: width, height: height,
                pitch: geometry.pitch, footprint: geometry.footprint, supersample: s,
                amount: amounts[r], meanAt: means, lo: tiles.dMin[r],
                hi: tiles.dMax[r], raw: raw, shouldContinue: shouldContinue)
            else { return nil }
            planes[r] = out
        }
        return planes
        #else
        return nil
        #endif
    }

    #if canImport(Metal)
    /// The mean density footprints of `footprint` texels read on the frame film itself at
    /// `meanLevels` gross densities across the tiles' range, from a flat patch of it per level,
    /// `meanPatchMM` a side. The mean bends between the tiles' own levels by several thousandths,
    /// which their blended grain cancels and a film developed at the frame's own density does not.
    private func frameMeans(_ r: Int, renderer: FilmFrameMetalRenderer, pitch: Float, footprint: Float,
                            supersample s: Int, shouldContinue: () -> Bool) -> [Float]? {
        let levels = Self.meanLevels
        guard let record = grain.frameRecord(r, seed: FilmGrain.frameMeanSeed, supersample: s) else { return nil }
        // Pixels a patch spans, and how many at its edges lie near enough the next level's
        // crystals or footprints to be left out.
        let patch = max(Int((Self.meanPatchMM / FilmGrain.tileTexelMM / pitch).rounded(.up)), 8)
        let border = Int(((record.reachTexels + footprint) / pitch).rounded(.up)) + 1
        let side = patch + 2 * border
        let width = side * levels
        let lo = tiles.dMin[r], hi = tiles.dMax[r]
        var plane = [Float](repeating: 0, count: width * side)
        for y in 0..<side {
            for x in 0..<width {
                plane[y * width + x] = lo + (hi - lo) * Float(x / side) / Float(levels - 1)
            }
        }
        guard let read = renderer.render(
            record: record, density: plane, width: width, height: side, pitch: pitch,
            footprint: footprint, supersample: s, amount: 1, meanAt: [0, 0], lo: lo, hi: hi,
            raw: true, shouldContinue: shouldContinue)
        else { return nil }
        return (0..<levels).map { k in
            var total = 0.0
            for y in border..<(border + patch) {
                for x in (k * side + border)..<(k * side + border + patch) { total += Double(read[y * width + x]) }
            }
            return Float(total / Double(patch * patch))
        }
    }

    /// Side of the flat patch each level's mean is read from, mm: its own grain moves the mean
    /// by about a thousandth.
    static let meanPatchMM: Float = 0.6
    /// Gross densities the frame's mean is read at, `dMin` to `dMax`.
    static let meanLevels = 65
    #endif
}
