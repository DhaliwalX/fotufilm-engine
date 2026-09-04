import Foundation

/// Bounds checking for a stock that arrived from outside.
public extension FilmStockDefinition {
    struct ValidationFailure: Error, CustomStringConvertible {
        public var field: String
        public var reason: String

        public var description: String { "\(field): \(reason)" }
    }

    /// Throws on the first problem, naming the field.
    func validate() throws {
        func fail(_ field: String, _ reason: String) -> ValidationFailure {
            ValidationFailure(field: "\(id.isEmpty ? "<no id>" : id).\(field)",
                              reason: reason)
        }
        func check(_ field: String, _ value: Float,
                   _ range: ClosedRange<Float>) throws {
            guard value.isFinite else { throw fail(field, "is not a finite number") }
            guard range.contains(value) else {
                throw fail(field, "is \(value); expected \(range.lowerBound)...\(range.upperBound)")
            }
        }
        func check(_ field: String, _ values: [Float], count: Int,
                   _ range: ClosedRange<Float>) throws {
            guard values.count == count else {
                throw fail(field, "has \(values.count) entries; expected \(count)")
            }
            for value in values { try check(field, value, range) }
        }
        func check(_ field: String, _ rows: [[Float]], shape: (Int, Int),
                   _ range: ClosedRange<Float>) throws {
            guard rows.count == shape.0 else {
                throw fail(field, "has \(rows.count) rows; expected \(shape.0)")
            }
            for row in rows { try check(field, row, count: shape.1, range) }
        }

        guard schemaVersion <= FilmStockDefinition.currentSchemaVersion else {
            throw fail("schemaVersion",
                       "is \(schemaVersion); this build reads up to "
                           + "\(FilmStockDefinition.currentSchemaVersion)")
        }
        try Self.checkIdentifier(id, field: "id", limit: 64, fail: fail)
        try Self.checkText(name, field: "name", limit: 64, required: true, fail: fail)
        try Self.checkText(subtitle, field: "subtitle", limit: 128, required: false, fail: fail)
        if let nativeFormatID {
            try Self.checkIdentifier(nativeFormatID, field: "nativeFormatID",
                                     limit: 32, fail: fail)
        }
        try check("referenceIlluminantKelvin",
                  referenceIlluminantKelvin ?? 5500, 2000...12000)
        if let spectralLineage {
            // A loaded id: a stock id, possibly behind a pack qualifier and a dot.
            try Self.checkIdentifier(spectralLineage, field: "spectralLineage",
                                     limit: 130, fail: fail)
        }

        try check("sensitivity", sensitivity, shape: (3, 3), -10...10)
        for (index, row) in sensitivity.enumerated() where abs(row.reduce(0, +)) < 1e-6 {
            throw fail("sensitivity", "row \(index) sums to zero and cannot be normalised")
        }

        try spectral.validate(fail: fail)

        // `curves` declares how many capture layers the emulsion has; every other per-layer
        // field is then checked against that count rather than against a literal, so a stock
        // that coats a different number is rejected once, here, with a reason — instead of
        // decoding cleanly and tripping a `precondition` somewhere inside the renderer.
        let layers = curves.count
        guard FilmStock.supportedCaptureLayerCounts.contains(layers) else {
            let supported = FilmStock.supportedCaptureLayerCounts
            throw fail("curves",
                       "declares \(layers) dye-forming capture layers; this build renders "
                       + (supported.lowerBound == supported.upperBound
                          ? "\(supported.lowerBound)"
                          : "\(supported.lowerBound)-\(supported.upperBound)")
                       + ". A layer that develops without forming a dye (REALA 500D's 4th "
                       + "Color Layer, say) belongs in donorLayers; a fourth *dye-forming* "
                       + "layer needs an N-to-dye forming step and an image pipeline that "
                       + "carries N planes; see FilmStock.supportedCaptureLayerCounts")
        }
        for (index, curve) in curves.enumerated() {
            try curve.validate(field: "curves[\(index)]", fail: fail)
        }

        let donors = donorLayers ?? []
        guard FilmStock.supportedDonorLayerCounts.contains(donors.count) else {
            throw fail("donorLayers",
                       "declares \(donors.count) donor layers; the packed kernel "
                       + "configuration carries at most "
                       + "\(FilmStock.supportedDonorLayerCounts.upperBound); see "
                       + "FilmStock.supportedDonorLayerCounts")
        }
        for (index, donor) in donors.enumerated() {
            let field = "donorLayers[\(index)]"
            try Self.checkText(donor.name, field: "\(field).name", limit: 16,
                               required: true, fail: fail)
            guard donor.sensitivity.count == SpectralGrid.count else {
                throw fail("\(field).sensitivity",
                           "has \(donor.sensitivity.count) samples; expected "
                           + "\(SpectralGrid.count), 380...780 nm at 10 nm")
            }
            for value in donor.sensitivity {
                guard value.isFinite, (0...1e4).contains(value) else {
                    throw fail("\(field).sensitivity",
                               "holds \(value); expected 0...10000.0")
                }
            }
            guard donor.sensitivity.max() ?? 0 > 0 else {
                throw fail("\(field).sensitivity", "is zero at every wavelength")
            }
            try donor.curve.validate(field: "\(field).curve", fail: fail)
            // The same bound as `couplerInhibition`: a release row is the same physical
            // quantity, stated for a donor record instead of a dye-forming one.
            try check("\(field).inhibition", donor.inhibition, count: layers, 0...4)
            try check("\(field).releaseGamma", donor.releaseGamma ?? 1, 0.25...4)
            if let depth = donor.depthUM {
                try check("\(field).depthUM", depth, -1000...1000)
            }
        }
        try paperCurve.validate(field: "paperCurve", fail: fail)
        // A gamma inside its own bound still describes a print nothing can
        // make — 20 over the default gap is 18 D — so bound the density scale
        // too. 3.0 clears the measured sheet's 2.10 and every carried value.
        let paperRange = paperCurve.gamma * (paperCurve.shoulder - paperCurve.toe)
        guard paperRange <= 3.0 else {
            throw fail("paperCurve", "spans \(paperRange) D above base; expected at most 3.0")
        }
        try check("paperMidDensity", paperMidDensity ?? 0.744, 0.01...4)
        // The loader turns an unrecognised id into "no preference", so an id that is merely
        // misspelled would print on the default sheet and look deliberate. Name it here instead.
        if let medium = nativePrintMedium, PrintPaper.preset(id: medium) == nil {
            throw fail("nativePrintMedium",
                       "is \"\(medium)\"; expected one of "
                        + PrintPaper.allCases.map(\.id).joined(separator: ", "))
        }

        try check("flare", flare ?? 0, 0...1)
        try check("emulsionDiffusionMM",
                  emulsionDiffusionMM ?? [Float](repeating: 0, count: layers),
                  count: layers, 0...2)
        try check("emulsionDiffusionSecondaryMM",
                  emulsionDiffusionSecondaryMM ?? [Float](repeating: 0, count: layers),
                  count: layers, 0...2)
        try check("emulsionDiffusionPrimaryShare",
                  emulsionDiffusionPrimaryShare ?? [Float](repeating: 1, count: layers),
                  count: layers, 0...1)
        try check("mtfLumaShare", mtfLumaShare ?? 0, 0...1)
        try check("lumaDiffusionMM", lumaDiffusionMM ?? 0, 0...2)

        try check("couplerInhibition", couplerInhibition, shape: (layers, layers), 0...4)
        try check("couplerReleaseGamma", couplerReleaseGamma ?? [1, 1, 1],
                  count: layers, 0.25...4)
        if let couplerGeometry {
            try check("couplerGeometry.layerDepthUM", couplerGeometry.layerDepthUM,
                      count: layers, -1000...1000)
            // Gaps are read off neighbouring array entries, so a stack listed out of order would
            // silently pair the wrong layers across the wrong interlayer.
            let depths = couplerGeometry.layerDepthUM
            let rising = zip(depths, depths.dropFirst()).allSatisfy { $0 < $1 }
            let falling = zip(depths, depths.dropFirst()).allSatisfy { $0 > $1 }
            guard rising || falling else {
                throw fail("couplerGeometry.layerDepthUM",
                           "must be strictly monotonic so neighbouring entries are "
                           + "neighbouring layers; got \(depths)")
            }
            try check("couplerGeometry.interlayerTransmission",
                      couplerGeometry.interlayerTransmission,
                      count: depths.count - 1, 0...1)
            // Non-negative: a negative release would have a layer *develop* its neighbours, which
            // `releaseSolvedFromInterImage` refuses to return in the first place.
            try check("couplerGeometry.release", couplerGeometry.release, count: layers, 0...4)
            try check("couplerGeometry.selfRetention", couplerGeometry.selfRetention, 0...1)
        }
        try check("couplerDiffusionMM", couplerDiffusionMM, 0...2)
        try check("adjacencyStrength", adjacencyStrength ?? 0, 0...4)
        try check("adjacencyRadiusMM", adjacencyRadiusMM ?? 0, 0...2)

        try check("grainStrength", grainStrength, 0...1)
        try check("grainSizeMM", grainSizeMM, 0.0005...0.5)
        try check("grainLayerWeights", grainLayerWeights, count: layers, 0...10)
        try check("grainLumaCorrelation", grainLumaCorrelation ?? 0, 0...1)
        try check("grainMottleShare", grainMottleShare ?? 0, 0...0.9)
        try check("grainMottleSizeRatio", grainMottleSizeRatio ?? 3, 1...8)
        // The two density scales must stay well inside the film's own scale: a toe wider than
        // the whole curve would move the peak off the end of it, and a decay that long would
        // leave the coarse population never handing over to the fine one, which is the
        // measurement's one unambiguous feature.
        try check("grainDensityProfile",
                  grainDensityProfile ?? FilmStock.defaultGrainDensityProfile,
                  count: 3, 0...100)
        if let profile = grainDensityProfile, profile.count == 3 {
            try check("grainDensityProfile.toeDensity", profile[1], 0.001...1)
            try check("grainDensityProfile.decayDensity", profile[2], 0.01...4)
        }
        try check("halationStrength", halationStrength, count: layers, 0...1)
        try check("halationLookScale", halationLookScale ?? 1, 0...100)
        try check("halationHazeMM", halationHazeMM ?? 0, 0...0.5)
        for (field, profile) in [("halationProfile", halationProfile),
                                 ("estimatedHalationProfile", estimatedHalationProfile)] {
            guard let profile else { continue }
            try check("\(field).roundTripOpticalDepth",
                      profile.roundTripOpticalDepth, count: layers, 0...20)
            try check("\(field).angularExponent",
                      profile.angularExponent, count: layers, 0...16)
            try check("\(field).diffuseShare",
                      profile.diffuseShare, count: layers, 0...1)
            try check("\(field).diffuseSigmaMM",
                      profile.diffuseSigmaMM, count: layers, 0...1)
            try check("\(field).bounceRetention",
                      profile.bounceRetention, count: layers, 0...1)
            if let depths = profile.recordDepthMM {
                try check("\(field).recordDepthMM", depths, count: layers, 0...0.1)
            }
            for layer in 0..<layers
            where profile.diffuseShare[layer] > 0
                && profile.diffuseSigmaMM[layer] <= 0 {
                throw fail("\(field).diffuseSigmaMM",
                           "layer \(layer) must be positive when diffuseShare is non-zero")
            }
        }
        if let matrix = halationReturnMatrix {
            guard matrix.count == layers else {
                throw fail("halationReturnMatrix",
                           "expects \(layers) receiver rows, found \(matrix.count)")
            }
            for row in matrix {
                try check("halationReturnMatrix", row, count: layers, 0...1)
            }
        }

        if let reciprocityFailure {
            try check("reciprocityFailure.thresholdSeconds",
                      reciprocityFailure.thresholdSeconds, 0.01...100_000)
            try check("reciprocityFailure.lostStopsPerDecade",
                      reciprocityFailure.lostStopsPerDecade, 0...4)
            if let statedThrough = reciprocityFailure.statedThroughSeconds {
                try check("reciprocityFailure.statedThroughSeconds", statedThrough,
                          reciprocityFailure.thresholdSeconds...100_000)
            }
            if let weights = reciprocityFailure.layerWeights {
                try check("reciprocityFailure.layerWeights", weights,
                          count: 3, 0...4)
            }
        }

        if let development {
            try Self.checkText(development.developer, field: "development.developer",
                               limit: 96, required: true, fail: fail)
            try Self.checkText(development.dilution, field: "development.dilution",
                               limit: 32, required: false, fail: fail)
            try Self.checkText(development.agitation, field: "development.agitation",
                               limit: 128, required: true, fail: fail)
            try Self.checkText(development.source, field: "development.source",
                               limit: 192, required: true, fail: fail)
            try check("development.temperatureC", development.temperatureC, 0...50)
            guard (1...10_000).contains(development.sourcePage) else {
                throw fail("development.sourcePage",
                           "is \(development.sourcePage); expected 1...10000")
            }
            guard !development.conditions.isEmpty else {
                throw fail("development.conditions", "is empty")
            }
            let sortedStops = development.conditions.map(\.stops).sorted()
            for pair in zip(sortedStops, sortedStops.dropFirst())
            where abs(pair.0 - pair.1) <= 1e-4 {
                throw fail("development.conditions", "repeats \(pair.0) stops")
            }
            for (index, condition) in development.conditions.enumerated() {
                let field = "development.conditions[\(index)]"
                try check("\(field).stops", condition.stops, -6...6)
                guard abs(condition.stops) > 1e-4 else {
                    throw fail("\(field).stops",
                               "reference development is already the stock and must not be repeated")
                }
                try Self.checkText(condition.label, field: "\(field).label",
                                   limit: 64, required: true, fail: fail)
                try check("\(field).timeMinutes", condition.timeMinutes, 0.1...120)
                if let exposureIndex = condition.exposureIndex {
                    try check("\(field).exposureIndex", exposureIndex, 1...1_000_000)
                }
                guard condition.curves.count == layers else {
                    throw fail("\(field).curves",
                               "has \(condition.curves.count) entries; expected \(layers)")
                }
                for (curveIndex, curve) in condition.curves.enumerated() {
                    try curve.validate(field: "\(field).curves[\(curveIndex)]", fail: fail)
                }
                let donorCurves = condition.donorCurves ?? []
                guard donorCurves.count == donors.count else {
                    throw fail("\(field).donorCurves",
                               "has \(donorCurves.count) entries; expected \(donors.count)")
                }
                for (curveIndex, curve) in donorCurves.enumerated() {
                    try curve.validate(field: "\(field).donorCurves[\(curveIndex)]", fail: fail)
                }
                if let value = condition.grainStrength {
                    try check("\(field).grainStrength", value, 0...1)
                }
                if let value = condition.grainSizeMM {
                    try check("\(field).grainSizeMM", value, 0.0005...0.5)
                }
                if let values = condition.grainLayerWeights {
                    try check("\(field).grainLayerWeights", values, count: layers, 0...10)
                }
                if let value = condition.grainFogDensity {
                    try check("\(field).grainFogDensity", value, 0...6)
                }
                if let value = condition.adjacencyStrength {
                    try check("\(field).adjacencyStrength", value, 0...4)
                }
            }
        }
    }

    /// `self` if it passes, for use in a decode chain.
    func validated() throws -> FilmStockDefinition {
        try validate()
        return self
    }

    private static func checkIdentifier(
        _ value: String, field: String, limit: Int,
        fail: (String, String) -> ValidationFailure) throws {
        guard !value.isEmpty else { throw fail(field, "is empty") }
        guard value.count <= limit else {
            throw fail(field, "is longer than \(limit) characters")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw fail(field, "may hold only letters, digits, '-', '_' and '.'")
        }
    }

    private static func checkText(
        _ value: String?, field: String, limit: Int, required: Bool,
        fail: (String, String) -> ValidationFailure) throws {
        guard let value else {
            if required { throw fail(field, "is missing") }
            return
        }
        if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw fail(field, "is empty")
        }
        guard value.count <= limit else {
            throw fail(field, "is longer than \(limit) characters")
        }
    }
}

extension FilmStockDefinition.CurveSpec {
    func validate(field: String,
                  fail: (String, String) -> FilmStockDefinition.ValidationFailure) throws {
        for (name, value) in [("dMin", dMin), ("gamma", gamma), ("toe", toe),
                              ("toeWidth", toeWidth), ("shoulder", shoulder),
                              ("shoulderWidth", shoulderWidth)] {
            guard value.isFinite else {
                throw fail("\(field).\(name)", "is not a finite number")
            }
        }
        guard (-1...6).contains(dMin) else {
            throw fail("\(field).dMin", "is \(dMin); expected -1...6")
        }
        guard (0.01...20).contains(gamma) else {
            throw fail("\(field).gamma", "is \(gamma); expected 0.01...20")
        }
        guard (-12...12).contains(toe), (-12...12).contains(shoulder) else {
            throw fail(field, "puts toe or shoulder outside -12...12 log exposure")
        }
        guard shoulder > toe else {
            throw fail(field, "has its shoulder at or below its toe")
        }
        guard (0.001...20).contains(toeWidth), (0.001...20).contains(shoulderWidth) else {
            throw fail(field, "has a toe or shoulder width outside 0.001...20")
        }
        if let secondary {
            try secondary.validate(field: "\(field).secondary", fail: fail)
        }
    }
}

extension FilmStockDefinition.CurveSpec.ComponentSpec {
    func validate(field: String,
                  fail: (String, String) -> FilmStockDefinition.ValidationFailure) throws {
        for (name, value) in [("gamma", gamma), ("toe", toe),
                              ("toeWidth", toeWidth), ("shoulder", shoulder),
                              ("shoulderWidth", shoulderWidth)] {
            guard value.isFinite else {
                throw fail("\(field).\(name)", "is not a finite number")
            }
        }
        guard (0.001...20).contains(gamma) else {
            throw fail("\(field).gamma", "is \(gamma); expected 0.001...20")
        }
        guard (-12...12).contains(toe), (-12...12).contains(shoulder), shoulder > toe else {
            throw fail(field, "has invalid toe/shoulder positions")
        }
        guard (0.001...20).contains(toeWidth), (0.001...20).contains(shoulderWidth) else {
            throw fail(field, "has a toe or shoulder width outside 0.001...20")
        }
    }
}

extension FilmStockDefinition.SpectralSpec {
    func validate(fail: (String, String) -> FilmStockDefinition.ValidationFailure) throws {
        func checkSamples(_ rows: [[Float]], field: String,
                          range: ClosedRange<Float>, needsSignal: Bool) throws {
            guard rows.count == 3 else {
                throw fail(field, "has \(rows.count) layers; expected 3, in R, G, B order")
            }
            for (index, row) in rows.enumerated() {
                guard row.count == SpectralGrid.count else {
                    throw fail("\(field)[\(index)]",
                               "has \(row.count) samples; expected \(SpectralGrid.count), "
                                   + "380...780 nm at 10 nm")
                }
                for value in row {
                    guard value.isFinite else {
                        throw fail("\(field)[\(index)]", "holds a value that is not finite")
                    }
                    guard range.contains(value) else {
                        throw fail("\(field)[\(index)]",
                                   "holds \(value); expected \(range.lowerBound)..."
                                       + "\(range.upperBound)")
                    }
                }
                if needsSignal, row.max() ?? 0 <= 0 {
                    throw fail("\(field)[\(index)]", "is zero at every wavelength")
                }
            }
        }

        switch self {
        case let .samples(layerSensitivity, imageDyeDensity):
            try checkSamples(layerSensitivity, field: "spectral.layerSensitivity",
                             range: 0...1e4, needsSignal: true)
            try checkSamples(imageDyeDensity, field: "spectral.imageDyeDensity",
                             range: 0...100, needsSignal: false)
        case let .measured(layerSensitivity, _):
            try checkSamples(layerSensitivity, field: "spectral.layerSensitivity",
                             range: 0...1e4, needsSignal: true)
        case let .color(peaksNM, widthsNM, _):
            guard peaksNM.count == 3 else {
                throw fail("spectral.peaksNM",
                           "has \(peaksNM.count) entries; expected 3")
            }
            for peak in peaksNM {
                guard peak.isFinite, (300...900).contains(peak) else {
                    throw fail("spectral.peaksNM", "holds \(peak) nm; expected 300...900")
                }
            }
            if let widthsNM {
                guard widthsNM.count == 3 else {
                    throw fail("spectral.widthsNM",
                               "has \(widthsNM.count) entries; expected 3")
                }
                for width in widthsNM {
                    guard width.isFinite, (1...400).contains(width) else {
                        throw fail("spectral.widthsNM",
                                   "holds \(width) nm; expected 1...400")
                    }
                }
            }
        case let .monochrome(rgbWeights):
            guard rgbWeights.count == 3 else {
                throw fail("spectral.rgbWeights",
                           "has \(rgbWeights.count) entries; expected 3")
            }
            for weight in rgbWeights {
                guard weight.isFinite, (0...100).contains(weight) else {
                    throw fail("spectral.rgbWeights", "holds \(weight); expected 0...100")
                }
            }
            guard rgbWeights.reduce(0, +) > 0 else {
                throw fail("spectral.rgbWeights", "sums to zero")
            }
        }
    }
}
