import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How an edit's negative is read from what its frame measures, the one way every surface reads
/// it: the desktop host, the browser's profile request and the command line. An edit saved with
/// the first reading keeps it, so it prints as it did.
extension WebNativeEdit.Negative {
    /// Whether the edit reads the film through the scan's light and camera (`NegativeScanModel`)
    /// and balances as `balance` says, or with the first reading.
    public var readsModel: Bool { (reading ?? 1) >= 2 }

    /// Whether the edit was made with the reading new scans are made with; one that was not
    /// keeps its own until it is updated.
    public var isCurrentReading: Bool { (reading ?? 1) >= Self.currentReading }

    /// The edit moved to the current reading, as Update Reading moves it: where the scan
    /// `separates`, its camera's channels measured, the dyes separated all the way unless the
    /// edit had set how far, and a frame that was balanced on its roll still on it.
    public func updatedReading(separates: Bool) -> WebNativeEdit.Negative {
        var updated = self
        updated.reading = Self.currentReading
        if separates, (crosstalk ?? 0) == 0 { updated.crosstalk = 1 }
        if roll != nil { updated.balance = .roll }
        return updated
    }

    /// How far the reading separates the dyes: all the way where a reading through the scan's
    /// light and camera does not say, not at all where the first reading does not.
    public var separation: Float { crosstalk ?? (readsModel ? 1 : 0) }

    /// What the reading sees the film through: the edit's light and camera, the camera left to
    /// what the scan's file says of it (`NegativeScanCapture`).
    public func setup(source: NegativeScanCapture? = nil) -> NegativeScanSetup {
        (source ?? NegativeScanCapture()).setup(
            light: scanLight ?? .white, camera: camera.map(NegativeScanSetup.Camera.init(name:)))
    }

    /// The stray light the reading takes off the scan, linear scan RGB like `border`: the
    /// edit's share of `frameLight`, the framed picture's average light
    /// (`ApproximateNegativeScan.frameLight`), or where the edit leaves it to be measured what
    /// the scan's `holder` shows (`ApproximateNegativeScan.strayLight`), none where it shows no
    /// holder. No more than a reading takes (`ApproximateNegativeScan.flareLimit`), and none on
    /// the first reading. web/src/negative-reading.js `readingFlare` mirrors this.
    public func strayLight(border: SIMD3<Float>, frameLight: SIMD3<Float>?,
                           holder: SIMD3<Float>?) -> SIMD3<Float> {
        guard readsModel else { return .zero }
        let shares = ApproximateNegativeScan.flareShares
        let stray = flare.map { share -> SIMD3<Float> in
            (frameLight ?? .zero) * min(max(share, shares.lowerBound), shares.upperBound)
        } ?? holder ?? .zero
        var held = SIMD3<Float>.zero
        for c in 0..<3 where stray[c].isFinite && border[c].isFinite && border[c] > 0 {
            held[c] = min(max(stray[c], 0), ApproximateNegativeScan.flareLimit * border[c])
        }
        return held
    }

    /// The frame's tones over `border` net of the scan's stray light, `flare`: its densest end
    /// as measured, the neutral picked on it, and the rises across its tonal steps, each in the
    /// scan channels' densities over the clear film.
    public func tones(border: SIMD3<Float>, denseEnd: SIMD3<Float>?,
                      slopes: SIMD2<Float>? = nil,
                      flare: SIMD3<Float> = .zero) -> ApproximateNegativeScan.Tones {
        let picked = neutral.flatMap { neutral -> SIMD3<Float>? in
            guard neutral.count == 3,
                  (0..<3).allSatisfy({ neutral[$0].isFinite && neutral[$0] > flare[$0]
                      && border[$0] > flare[$0] })
            else { return nil }
            var density = SIMD3<Float>.zero
            for c in 0..<3 {
                let sample: Float = neutral[c] - flare[c]
                let clear: Float = border[c] - flare[c]
                density[c] = -log10(sample / clear)
            }
            return density
        }
        return .init(denseEnd: denseEnd, picked: picked, slopes: slopes)
    }

    /// The frame's balance read as `stock`: `denseEnd` is its own densest end over `border`
    /// (`ApproximateNegativeScan.denseEnd(border:preview:)`), before any roll's colour, and
    /// `slopes` the rises across its tonal steps, both net of the scan's stray light, `flare`,
    /// which `border` here still carries; `source` is what the scan's file says of its camera.
    public func balance(stock: FilmStock, border: SIMD3<Float>, denseEnd: SIMD3<Float>?,
                        slopes: SIMD2<Float>? = nil, source: NegativeScanCapture? = nil,
                        flare: SIMD3<Float> = .zero) -> ApproximateNegativeScan.Balance {
        guard readsModel else {
            return ApproximateNegativeScan.balance(
                stock: stock, denseEnd: ApproximateNegativeScan.denseEnd(denseEnd, roll: roll),
                correction: correction)
        }
        return ApproximateNegativeScan.balance(
            stock: stock, setup: setup(source: source), separation: separation,
            mode: balance ?? .frame,
            tones: tones(border: border, denseEnd: denseEnd, slopes: slopes, flare: flare),
            roll: roll)
    }

    /// The frame read without a film, as Normal reads a negative. Arguments as
    /// `balance(stock:border:denseEnd:slopes:source:flare:)`.
    public func plain(border: SIMD3<Float>, denseEnd: SIMD3<Float>?,
                      slopes: SIMD2<Float>? = nil, source: NegativeScanCapture? = nil,
                      flare: SIMD3<Float> = .zero) -> PlainNegativeScan {
        guard readsModel else {
            return PlainNegativeScan(
                border: border, denseEnd: ApproximateNegativeScan.denseEnd(denseEnd, roll: roll),
                correction: correction)
        }
        return PlainNegativeScan(
            border: border, setup: setup(source: source), separation: separation,
            mode: balance ?? .frame,
            tones: tones(border: border, denseEnd: denseEnd, slopes: slopes, flare: flare),
            roll: roll, flare: flare)
    }

    /// Everything of the edit a reading turns on, for keeping one made before: two edits with
    /// the same key read the same frame of the same scan alike.
    public var readingKey: String {
        let roll = roll.map { "\($0.colour),\($0.level.map { "\($0)" } ?? ""),\($0.slopes ?? [])" }
        return [
            "\(reading ?? 1)", camera ?? "", balance?.rawValue ?? "", "\(neutral ?? [])",
            roll ?? "", crosstalk.map { "\($0)" } ?? "", scanLight?.rawValue ?? "",
            flare.map { "\($0)" } ?? "",
        ].joined(separator: "|")
    }
}
