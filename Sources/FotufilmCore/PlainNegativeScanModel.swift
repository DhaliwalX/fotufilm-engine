import Foundation

/// A scan read without a film, through the light and camera that made it. With no film to take
/// spectra from, the reading is fitted on a colour negative of the ordinary kind: its three dyes
/// over an orange mask. The scan's channels see that film as they see any (`NegativeScanSetup`),
/// and the weights are the least squares from their densities back to its dyes', as a known
/// film's are (`NegativeScanModel.weights`).
extension PlainNegativeScan {
    /// The ordinary film's clear base per `SpectralGrid` wavelength: an orange mask, which reads
    /// about 0.2 of density to red light, 0.6 to green and 0.85 to blue. A broad channel reads a
    /// dye through the mask's slope across it, so the fit needs the mask though the readings are
    /// over the clear film.
    static let mask: [Float] = {
        let dyes = NegativeScanCrosstalk.plainDyes
        return (0..<SpectralGrid.count).map { 0.2 + 0.4 * dyes[1][$0] + 0.65 * dyes[2][$0] }
    }()

    /// The dye densities the fit is made on: greys from thin to dense, and colours about each,
    /// one dye more or less than the others, each grey counting as much as the colours about it.
    private static let patches: [(amounts: SIMD3<Float>, weight: Float)] = {
        var shifts: [SIMD3<Float>] = []
        for amount in [Float(0.18), 0.36] {
            for sign in [Float(-1), 1] {
                shifts.append(SIMD3(sign * amount, 0, 0))
                shifts.append(SIMD3(0, sign * amount, 0))
                shifts.append(SIMD3(0, 0, sign * amount))
            }
        }
        var patches: [(amounts: SIMD3<Float>, weight: Float)] = []
        for level in stride(from: Float(0.05), through: 1.5, by: 0.1) {
            patches.append((SIMD3(repeating: level), Float(shifts.count)))
            for shift in shifts where level + shift.min() >= 0 {
                patches.append((SIMD3(repeating: level) + shift, 1))
            }
        }
        return patches
    }()

    /// What each channel reads of the scan through `setup`: rows the film's cyan, magenta and
    /// yellow dyes, which the scan's red, green and blue are read for, columns the scan's
    /// densities over the clear film. `separation` runs from each dye read from its own channel
    /// alone, scaled to keep the greys' densities (0), to the full fit across the channels (1).
    public static func weights(setup: NegativeScanSetup, separation: Float) -> [SIMD3<Float>] {
        let response = setup.response()
        let dyes = NegativeScanCrosstalk.plainDyes
        func read(_ amounts: SIMD3<Float>) -> SIMD3<Float> {
            var read = SIMD3<Float>.zero
            for i in 0..<SpectralGrid.count {
                let density = mask[i] + amounts.x * dyes[0][i] + amounts.y * dyes[1][i]
                    + amounts.z * dyes[2][i]
                read += pow(10, -density) * SIMD3(response[0][i], response[1][i], response[2][i])
            }
            return read
        }
        let clear = read(.zero)
        guard clear.min() > 0 else { return [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] }
        let readings = patches.compactMap { patch -> NegativeScanModel.Reading? in
            let film = read(patch.amounts)
            // A camera's channel can read no light of a deep colour its matrix subtracts.
            guard film.min() > 0 else { return nil }
            return NegativeScanModel.Reading(
                scanner: SIMD3((0..<3).map { -log10(film[$0] / clear[$0]) }),
                target: patch.amounts, weight: patch.weight, isNeutral: patch.weight > 1)
        }
        return NegativeScanModel.weights(separation: separation, readings: readings)
    }

    /// Reads against `border` through `setup`, its weights across the channels at `separation`,
    /// along a negative's curve with its toe, balanced as `mode` says on the frame's neutral, one
    /// picked on it or else its densest end, or on its roll's; or left as the film reads. With
    /// no film to say how steep its records are, red's and blue's densities are scaled onto
    /// green's at that neutral, which holds the greys between the clear film and the neutral
    /// whatever each record's contrast. A `roll` that measured its tonal steps says the
    /// contrast itself: red and blue are then made as steep as green by it, and the neutral is
    /// balanced by each channel's light, as an exposure. The frame's own densest end prints as
    /// `highlight` whichever it is balanced on. `tones` are net of the scan's stray light,
    /// `flare`, which `border` still carries.
    public init(border: SIMD3<Float>, setup: NegativeScanSetup, separation: Float,
                mode: ApproximateNegativeScan.BalanceMode, tones: ApproximateNegativeScan.Tones,
                roll: ApproximateNegativeScan.RollBalance? = nil, flare: SIMD3<Float> = .zero) {
        let weights = Self.weights(setup: setup, separation: separation)
        let readable = { (density: SIMD3<Float>?) -> SIMD3<Float>? in
            density.flatMap { d in (0..<3).allSatisfy({ d[$0].isFinite }) ? d : nil }
        }
        let dense = readable(tones.denseEnd)
        var reference = Self.defaultReference
        if let dense, case let green = NegativeScanCrosstalk.apply(weights, dense).y, green > 0.05 {
            reference = green
        }
        var gains = SIMD3<Float>.one
        // A roll's tonal steps say how steep red and blue read against green: with no film to
        // say otherwise, a grey's records are as steep as each other.
        var steepened = false
        if mode != .none, let slopes = roll?.slopes, slopes.count == 2 {
            let read = NegativeScanCrosstalk.apply(weights, SIMD3(slopes[0], 1, slopes[1]))
            if read.y.isFinite, read.y > 0 {
                let range = ApproximateNegativeScan.contrastRange
                for channel in [0, 2] where read[channel].isFinite && read[channel] > 0 {
                    gains[channel] = min(max(read.y / read[channel], range.lowerBound),
                                         range.upperBound)
                }
                steepened = true
            }
        }
        var balance = SIMD3<Float>.one
        let toeLight = Self.modelToe * pow(10, -reference / Self.gamma)
        // As a known film's balance takes its neutral
        // (`ApproximateNegativeScan.balance(stock:setup:separation:mode:tones:roll:)`).
        let neutrals = mode == .none ? [] : [
            mode == .roll ? roll?.neutral(green: dense?.y) : nil, readable(tones.picked), dense,
        ]
        if let neutral = neutrals.lazy.compactMap({ $0 }).map({
            NegativeScanCrosstalk.apply(weights, $0) }).first(where: { $0.y > 0.05 }) {
            if steepened {
                // The exposure that made each channel's density there, brought onto green's.
                let exposure = { (channel: Int) -> Float in
                    pow(10, (gains[channel] * neutral[channel] - reference) / Self.gamma) - toeLight
                }
                let green = exposure(1)
                for channel in [0, 2] where neutral[channel] > 0.05 {
                    let own = exposure(channel)
                    guard green > 0, own > 0 else { continue }
                    balance[channel] = min(max(green / own, Self.balanceRange.lowerBound),
                                           Self.balanceRange.upperBound)
                }
            } else {
                for channel in [0, 2] where neutral[channel] > 0.05 {
                    gains[channel] = min(max(neutral.y / neutral[channel],
                                             ApproximateNegativeScan.gainRange.lowerBound),
                                         ApproximateNegativeScan.gainRange.upperBound)
                }
            }
        }
        self.border = border
        self.gains = gains
        self.weights = weights
        self.reference = reference
        self.flare = flare
        self.toe = Self.modelToe
        self.balance = balance
    }
}
