import XCTest
@testable import FotufilmCore

final class LensFilterTests: XCTestCase {

    private static var monochrome: FilmStock {
        FilmStock.presets["example-monochrome-100"]!
    }
    private static var colour: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private func kelvin(of spectrum: [Float]) -> Float {
        let xyz = SpectralGrid.xyz(spectrum: spectrum)
        let sum = xyz.x + xyz.y + xyz.z
        let uv = WhiteBalance.uvFromXY(SIMD2(xyz.x / sum, xyz.y / sum))
        var best: (kelvin: Float, distance: Float) = (0, .greatestFiniteMagnitude)
        var k: Float = 1600
        while k <= 20000 {
            let locus = WhiteBalance.uvFromXY(WhiteBalance.locusXY(k))
            let d = (locus.x - uv.x) * (locus.x - uv.x) + (locus.y - uv.y) * (locus.y - uv.y)
            if d < best.distance { best = (k, d) }
            k *= 1.0005
        }
        return best.kelvin
    }

    private func through(_ filter: LensFilter, _ illuminant: [Float]) -> [Float] {
        let t = filter.transmittance
        return (0..<SpectralGrid.count).map { illuminant[$0] * t[$0] }
    }

    // MARK: The surfaces

    func testUncoatedSurfacesAreFresnelExactly() {
        for wavelength in stride(from: Float(380), through: 780, by: 10) {
            let n = OpticalMaterial.crownGlass.index(wavelengthNM: wavelength)
            let expected = ((n - 1) / (n + 1)) * ((n - 1) / (n + 1))
            let measured = ThinFilm.reflectance(wavelengthNM: wavelength,
                                                layers: FilterCoating.uncoated.layers,
                                                substrate: .crownGlass)
            XCTAssertEqual(measured, expected, accuracy: 1e-7, "\(wavelength) nm")
        }
        let clear = LensFilter(id: "clear", name: "clear",
                               internalTransmittance: [Float](repeating: 1,
                                                              count: SpectralGrid.count),
                               substrate: .crownGlass, coating: .uncoated)
        // (1 − R)² / (1 − R²) = (1 − R) / (1 + R) once the trapped reflections are summed.
        let r = ThinFilm.reflectance(wavelengthNM: 550, layers: [], substrate: .crownGlass)
        XCTAssertEqual(clear.transmittance[34], (1 - r) / (1 + r), accuracy: 1e-5)
        XCTAssertEqual(clear.transmittance[34], 0.9187, accuracy: 0.001)
    }

    func testSingleLayerCoatingMeetsItsClosedFormMinimum() {
        let design = OpticalMaterial.designWavelengthNM
        let coating = OpticalMaterial.magnesiumFluoride.index(wavelengthNM: design)
        let glass = OpticalMaterial.crownGlass.index(wavelengthNM: design)
        let squared = coating * coating
        let expected = ((squared - glass) / (squared + glass)) * ((squared - glass) / (squared + glass))
        let measured = ThinFilm.reflectance(wavelengthNM: design,
                                            layers: FilterCoating.singleLayer.layers,
                                            substrate: .crownGlass)
        XCTAssertEqual(measured, expected, accuracy: 1e-6)
        XCTAssertEqual(measured, 0.0123, accuracy: 0.0005)

        // The purple bloom: a single layer is only tuned at one wavelength and gives light back
        // at both ends of the band.
        let ends = [380, 780].map {
            ThinFilm.reflectance(wavelengthNM: Float($0),
                                 layers: FilterCoating.singleLayer.layers, substrate: .crownGlass)
        }
        for end in ends { XCTAssertGreaterThan(end, measured * 1.4) }
    }

    func testMultiCoatingBeatsBareGlassAcrossTheVisible() {
        for wavelength in stride(from: Float(400), through: 700, by: 10) {
            let coated = ThinFilm.reflectance(wavelengthNM: wavelength,
                                              layers: FilterCoating.multiCoated.layers,
                                              substrate: .crownGlass)
            let bare = ThinFilm.reflectance(wavelengthNM: wavelength, layers: [],
                                            substrate: .crownGlass)
            XCTAssertLessThan(coated, bare / 4, "\(wavelength) nm")
        }
        for wavelength in stride(from: Float(420), through: 640, by: 10) {
            XCTAssertLessThan(ThinFilm.reflectance(wavelengthNM: wavelength,
                                                   layers: FilterCoating.multiCoated.layers,
                                                   substrate: .crownGlass),
                              0.003, "\(wavelength) nm")
        }
    }

    // MARK: What the filter is named for

    func testConversionFiltersMakeTheirPublishedMiredShift() {
        let specified: [(LensFilter, Float, Float)] = [
            (.wratten85B, 5500, 3200), (.wratten85, 5500, 3400), (.wratten85C, 5500, 3800),
            (.wratten80A, 3200, 5500), (.wratten80B, 3400, 5500),
            (.wratten80C, 3800, 5500), (.wratten80D, 4200, 5500),
        ]
        for (filter, source, target) in specified {
            let light = Illuminant.atLocus(kelvin: source)
            let result = kelvin(of: through(filter, light))
            let shift = 1e6 / result - 1e6 / source
            let wanted = 1e6 / target - 1e6 / source
            XCTAssertEqual(shift, wanted, accuracy: 1.5,
                           "\(filter.name): \(source) K → \(result) K, wanted \(target) K")
        }
        // The 81 and 82 series state a shift rather than a pair, which is how they are built.
        let balancing: [(LensFilter, Float)] = [
            (.wratten81, 9), (.wratten81A, 18), (.wratten81B, 27),
            (.wratten81C, 35), (.wratten81EF, 53),
            (.wratten82, -10), (.wratten82A, -21), (.wratten82B, -32), (.wratten82C, -45),
        ]
        let daylight = Illuminant.atLocus(kelvin: 5500)
        for (filter, wanted) in balancing {
            let shift = 1e6 / kelvin(of: through(filter, daylight)) - 1e6 / 5500
            XCTAssertEqual(shift, wanted, accuracy: 1.5, filter.name)
        }
    }

    func testConversionFiltersLeaveNoTint() {
        for (filter, source) in [(LensFilter.wratten85B, Float(5500)),
                                 (.wratten80A, 3200), (.wratten81EF, 5500),
                                 (.wratten82C, 5500)] {
            let result = through(filter, Illuminant.atLocus(kelvin: source))
            let xyz = SpectralGrid.xyz(spectrum: result)
            let sum = xyz.x + xyz.y + xyz.z
            let uv = WhiteBalance.uvFromXY(SIMD2(xyz.x / sum, xyz.y / sum))
            let locus = WhiteBalance.uvFromXY(WhiteBalance.locusXY(kelvin(of: result)))
            let offLocus = ((locus.x - uv.x) * (locus.x - uv.x)
                            + (locus.y - uv.y) * (locus.y - uv.y)).squareRoot()
            // A tenth of the ~0.006 uv step that reads as a visible green or magenta cast.
            XCTAssertLessThan(offLocus, 0.0006, filter.name)
        }
    }

    func testFilterFactorsAgreeWithThePublishedOnesOrAreLighter() {
        let daylight = Illuminant.atLocus(kelvin: 5500)
        for (filter, published) in [(LensFilter.wratten85B, Float(0.67)),
                                    (.wratten85, 0.67)] {
            let measured = -log2(filter.luminousTransmittance(illuminant: daylight))
            XCTAssertEqual(measured, published, accuracy: 0.15, filter.name)
        }
        for (filter, source, published) in [(LensFilter.wratten80A, Float(3200), Float(2.0)),
                                            (.wratten80B, 3400, 1.67),
                                            (.wratten80C, 3800, 1.0)] {
            let light = Illuminant.atLocus(kelvin: source)
            let measured = -log2(filter.luminousTransmittance(illuminant: light))
            XCTAssertLessThan(measured, published, filter.name)
            XCTAssertGreaterThan(measured, published - 0.85, filter.name)
        }
    }

    func testEveryDeckIDResolvesInTheCatalogue() {
        let deckIDs = ["w85b", "w85", "w80a", "w80b", "w81a", "w81ef", "w82a", "w82c",
                       "nd03", "nd06", "nd09", "nd12", "nd18", "nd30",
                       "w8", "w15", "w21", "w25", "w29", "w58"]
        for id in deckIDs {
            XCTAssertNotNil(LensFilter.catalogued(id),
                            "deck id '\(id)' resolves to no catalogued filter")
        }
    }

    func testNeutralDensityIsExactAndNeutral() {
        for density in [Float(0.3), 0.6, 0.9, 1.2, 1.8, 3.0] {
            let filter = LensFilter.neutralDensity(density)
            let stops = -log2(filter.luminousTransmittance())
            // The shortfall is the filter's own two surfaces, which a real one has too.
            XCTAssertEqual(stops, density / 0.30103, accuracy: 0.05, "ND \(density)")
            let tinted = kelvin(of: through(filter, SpectralGrid.d65))
            XCTAssertEqual(tinted, kelvin(of: SpectralGrid.d65), accuracy: 25, "ND \(density)")
        }
    }

    // MARK: Stacking

    func testStackingPaysForItsExtraSurfaces() {
        let single = LensFilterStack(.neutralDensity(0.9)).luminousTransmittance()
        let stacked = LensFilterStack([.neutralDensity(0.3), .neutralDensity(0.6)])
            .luminousTransmittance()
        XCTAssertLessThan(stacked, single)
        // Two multicoated surfaces, so a tenth of a percent — not nothing, and not a stop.
        XCTAssertEqual(stacked / single, 1 - 0.0013, accuracy: 0.001)

        // Uncoated glass makes the same point loudly: two more Fresnel surfaces is 8% of light.
        let bare = { (d: Float) in LensFilter.neutralDensity(d, coating: .uncoated) }
        let bareSingle = LensFilterStack(bare(0.9)).luminousTransmittance()
        let bareStacked = LensFilterStack([bare(0.3), bare(0.6)]).luminousTransmittance()
        XCTAssertEqual(bareStacked / bareSingle, 0.918, accuracy: 0.01)
    }

    func testVeilingGlareTracksTheCoatingAndTheStack() {
        func glare(_ coating: FilterCoating, count: Int) -> Float {
            var filter = LensFilter.wratten85B
            filter.coating = coating
            return LensFilterStack([LensFilter](repeating: filter, count: count))
                .addedVeilingGlare
        }
        XCTAssertGreaterThan(glare(.uncoated, count: 1), glare(.singleLayer, count: 1))
        XCTAssertGreaterThan(glare(.singleLayer, count: 1), glare(.multiCoated, count: 1))
        for coating in FilterCoating.allCases {
            XCTAssertGreaterThan(glare(coating, count: 2), glare(coating, count: 1),
                                 coating.rawValue)
        }
        // Measured: one uncoated filter is a fortieth of the lens's own glare, two are a fifth,
        // and a multicoated one is three parts in a million — invisible, which is the answer.
        XCTAssertEqual(glare(.uncoated, count: 1), 0.000199, accuracy: 0.00002)
        XCTAssertEqual(glare(.uncoated, count: 2), 0.00178, accuracy: 0.0002)
        XCTAssertLessThan(glare(.multiCoated, count: 2), 0.00001)
        XCTAssertEqual(LensFilterStack().addedVeilingGlare, 0)
    }

    // MARK: What the film makes of it

    func testTheSameFilterIsADifferentFilterOnADifferentStock() {
        let stack = LensFilterStack(.wratten25)
        var spreads: [Float] = []
        var shifted = TestStocks.negative
        shifted.spectralProfile = .color(peaksNM: [630, 550, 450], dyeFamily: .kodakNegative)
        for stock in [TestStocks.negative, shifted] {
            let layers = stack.layerTransmittances(stock: stock)
            // A deep red passes the red record and takes the blue one out entirely.
            XCTAssertGreaterThan(layers.x, 0.7, stock.name)
            XCTAssertLessThan(layers.y, 0.25, stock.name)
            XCTAssertLessThan(layers.z, 0.01, stock.name)
            spreads.append(layers.x)
        }
        // And it does not treat them all alike: the red records differ in where they sit under
        // the filter's cut, so the transmittances differ by more than rounding.
        if let low = spreads.min(), let high = spreads.max(), spreads.count > 1 {
            XCTAssertGreaterThan(high - low, 0.05,
                                 "a spectral filter must separate stocks, not tint them alike")
        }
    }

    func testConversionFiltersMoveTheLayersTheWayTheirNamesSay() {
        for stock in FilmStock.presets.values where !stock.isMonochrome {
            let warm = LensFilterStack(.wratten85B).layerTransmittances(stock: stock)
            XCTAssertGreaterThan(warm.x, warm.y, stock.name)
            XCTAssertGreaterThan(warm.y, warm.z, stock.name)
            let cool = LensFilterStack(.wratten80A).layerTransmittances(stock: stock)
            XCTAssertGreaterThan(cool.z, cool.y, stock.name)
            XCTAssertGreaterThan(cool.y, cool.x, stock.name)
        }
    }

    func testCompensationPoliciesDifferTheWayMeteringDoes() {
        let stock = Self.colour
        let red = LensFilter.wratten25
        func gain(_ policy: LensFilterCompensation) -> Float {
            LensFilterStack(red, compensation: policy).exposureGain(stock: stock)
        }
        XCTAssertEqual(gain(.none), 1)
        XCTAssertEqual(gain(.throughTheLens),
                       1 / red.luminousTransmittance(), accuracy: 1e-5)
        // The film wants more than the meter gives it: the meter sees luminance, the emulsion
        // sees its own green record, and behind a red filter those are far apart.
        XCTAssertGreaterThan(gain(.filmSpeed), gain(.throughTheLens) * 1.4)

        // On a monochrome stock the three layers are one curve, so the film-speed factor is that
        // curve's own transmittance with nothing averaged.
        let mono = Self.monochrome
        let layers = LensFilterStack(red).layerTransmittances(stock: mono)
        XCTAssertEqual(layers.x, layers.y, accuracy: 1e-6)
        XCTAssertEqual(LensFilterStack(red, compensation: .filmSpeed).exposureGain(stock: mono),
                       1 / layers.y, accuracy: 1e-5)

        // An empty stack never touches the exposure, whatever policy is set.
        for policy in LensFilterCompensation.allCases {
            XCTAssertEqual(LensFilterStack([], compensation: policy).exposureGain(stock: stock), 1)
        }
    }

    func testContrastFilterFactorsRiseWithTheCut() {
        let stock = Self.monochrome
        let series: [LensFilter] = [.wratten8, .wratten12, .wratten15, .wratten16,
                                    .wratten21, .wratten23A, .wratten25, .wratten29]
        var previous: Float = -.greatestFiniteMagnitude
        for filter in series {
            let factor = LensFilterStack(filter).filterFactorStops(stock: stock)
            XCTAssertGreaterThan(factor, previous, filter.name)
            previous = factor
        }
        // The two ends, measured: a yellow costs about two thirds of a stop on this emulsion and
        // a deep red a little under three. Datasheets publish 1 and 4⅓ for a panchromatic film,
        // and they round upward; the example stock's response is broader than a real one's,
        // which is why it sits at the low end of that.
        XCTAssertEqual(LensFilterStack(.wratten8).filterFactorStops(stock: stock),
                       0.67, accuracy: 0.1)
        XCTAssertEqual(LensFilterStack(.wratten29).filterFactorStops(stock: stock),
                       2.80, accuracy: 0.15)
    }

    // MARK: The engine

    func testEmptyStackChangesNothingAtAll() {
        let stock = Self.colour
        var bare = FotufilmEngine.Options()
        var filtered = FotufilmEngine.Options()
        filtered.lensFilters = LensFilterStack()
        let a = FilmEngineInvocation(stock: stock, options: bare, width: 64, height: 64)
        let b = FilmEngineInvocation(stock: stock, options: filtered, width: 64, height: 64)
        XCTAssertEqual(a.spectralCacheID, b.spectralCacheID)
        XCTAssertEqual(a.configuration, b.configuration)
        XCTAssertEqual(a.featureMask, b.featureMask)
        XCTAssertEqual(a.spectral.exposure.values, b.spectral.exposure.values)

        // And a filter that is present does move all of it.
        bare.lensFilters = LensFilterStack(.wratten85B)
        let c = FilmEngineInvocation(stock: stock, options: bare, width: 64, height: 64)
        XCTAssertNotEqual(a.spectralCacheID, c.spectralCacheID)
        XCTAssertNotEqual(a.spectral.exposure.values, c.spectral.exposure.values)
        XCTAssertGreaterThan(c.configuration[FilmEngineInvocation.flareOffset],
                             a.configuration[FilmEngineInvocation.flareOffset])
    }

    func testTheFilterLandsInTheExposureTableAndNowhereElse() {
        let stock = Self.colour
        var options = FotufilmEngine.Options()
        let bare = FilmEngineInvocation(stock: stock, options: options, width: 64, height: 64)
        options.lensFilters = LensFilterStack(.wratten85B)
        let filtered = FilmEngineInvocation(stock: stock, options: options, width: 64, height: 64)
        XCTAssertEqual(bare.spectral.filmOutput.values, filtered.spectral.filmOutput.values)
        XCTAssertEqual(bare.spectral.paperOutput?.values, filtered.spectral.paperOutput?.values)
        XCTAssertNotEqual(bare.spectral.exposure.values, filtered.spectral.exposure.values)
    }

    func testExposureTableCarriesTheFilterAtTheNeutral() {
        let stock = Self.colour
        let neutral = SIMD3<Float>(repeating: 0.18)
        func exposure(_ stack: LensFilterStack) -> SIMD3<Float> {
            SpectralRuntime.filteredExposure(for: stock, cct: nil, stack: stack).sample(neutral)
        }
        let bare = SpectralRuntime.tables(for: stock).exposure.sample(neutral)
        XCTAssertEqual(bare.x, bare.y, accuracy: 1e-3)
        XCTAssertEqual(bare.y, bare.z, accuracy: 1e-3)

        let warm = exposure(LensFilterStack(.wratten85B, compensation: .none))
        XCTAssertGreaterThan(warm.x / warm.z, 2.5)
        let cool = exposure(LensFilterStack(.wratten80A, compensation: .none))
        XCTAssertGreaterThan(cool.z / cool.x, 2.5)

        // Metering restores the level without undoing the balance — that is what a filter factor
        // is, and what it is not.
        let metered = exposure(LensFilterStack(.wratten85B, compensation: .filmSpeed))
        XCTAssertEqual(metered.y, bare.y, accuracy: bare.y * 0.02)
        XCTAssertEqual(metered.x / metered.z, warm.x / warm.z, accuracy: 0.05)
    }

    func testFilteredTablesAreCachedWithoutCollapsingTogether() {
        let stock = Self.colour
        let a = SpectralRuntime.filteredExposure(for: stock, cct: nil,
                                                 stack: LensFilterStack(.wratten85B))
        let again = SpectralRuntime.filteredExposure(for: stock, cct: nil,
                                                     stack: LensFilterStack(.wratten85B))
        XCTAssertEqual(a.values, again.values)
        for other in [LensFilterStack(.wratten80A),
                      LensFilterStack(.wratten85B, compensation: .none),
                      LensFilterStack([.wratten85B, .nd09])] {
            XCTAssertNotEqual(
                a.values,
                SpectralRuntime.filteredExposure(for: stock, cct: nil, stack: other).values)
        }
        XCTAssertNotEqual(
            a.values,
            SpectralRuntime.filteredExposure(for: stock, cct: 2856,
                                             stack: LensFilterStack(.wratten85B)).values)
    }

    func testAPrintDevelopedThroughAnAmberFilterComesOutWarmer() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the engine is not linked into this build")
        let size = 32
        var grey = ImageBuffer(width: size, height: size)
        for plane in 0..<3 {
            for i in 0..<grey.pixelCount { grey.planes[plane][i] = 0.18 }
        }
        var bare = FotufilmEngine.Options()
        bare.grainScale = 0
        var warmed = bare
        warmed.lensFilters = LensFilterStack(.wratten85B, compensation: .filmSpeed)
        var cooled = bare
        cooled.lensFilters = LensFilterStack(.wratten80A, compensation: .filmSpeed)

        let probe = size * size / 2 + size / 2
        func print_(_ options: FotufilmEngine.Options) -> SIMD3<Float> {
            let out = FotufilmEngine(stock: Self.colour, options: options)
                .process(linearRGB: grey)
            return SIMD3(out.planes[0][probe], out.planes[1][probe], out.planes[2][probe])
        }
        let plain = print_(bare), amber = print_(warmed), blue = print_(cooled)

        // An unfiltered grey card prints grey, which is what makes the rest of this readable.
        XCTAssertEqual(plain.x / plain.z, 1, accuracy: 0.08)
        XCTAssertGreaterThan(amber.x / amber.z, plain.x / plain.z * 1.3)
        XCTAssertLessThan(blue.x / blue.z, plain.x / plain.z / 1.3)

        // Metered through, so the print is re-balanced rather than merely darkened: the green
        // record lands within a fifth of a stop of where it was.
        XCTAssertEqual(amber.y, plain.y, accuracy: plain.y * 0.15)
    }

    func testEveryPresetIsWellFormed() {
        var seen = Set<String>()
        for filter in LensFilter.catalogue {
            XCTAssertTrue(seen.insert(filter.id).inserted, "duplicate id \(filter.id)")
            XCTAssertEqual(filter.transmittance.count, SpectralGrid.count, filter.name)
            for value in filter.transmittance {
                XCTAssertTrue(value >= 0 && value <= 1, filter.name)
                XCTAssertFalse(value.isNaN, filter.name)
            }
            // Not opaque. The floor has to clear a ten-stop neutral density, which passes a
            // thousandth of the light and is a perfectly good filter.
            XCTAssertGreaterThan(filter.transmittance.max() ?? 0, 5e-4, filter.name)
            XCTAssertLessThan(filter.luminousTransmittance(), 0.999, filter.name)
        }
    }
}
