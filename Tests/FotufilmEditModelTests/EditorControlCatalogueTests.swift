import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class EditorControlCatalogueTests: XCTestCase {

    // MARK: - The list accounts for itself

    func testEveryFieldIsEitherCataloguedOrPending() {
        let catalogued = Set(EditorControlCatalogue.all.map(\.field))
        let pending = Set(EditorControlCatalogue.pending.keys)

        XCTAssertTrue(catalogued.isDisjoint(with: pending),
                      "a field cannot be both offered and pending: "
                      + "\(catalogued.intersection(pending))")
        let unaccounted = Set(EditorControlField.allCases)
            .subtracting(catalogued).subtracting(pending)
        XCTAssertEqual(catalogued.union(pending),
                       Set(EditorControlField.allCases),
                       "unaccounted fields: \(unaccounted)")
    }

    func testCatalogueHasNoRepeatedFields() {
        let fields = EditorControlCatalogue.all.map(\.field)
        XCTAssertEqual(fields.count, Set(fields).count)
    }

    func testEveryPendingEntryGivesAReason() {
        for (field, reason) in EditorControlCatalogue.pending {
            XCTAssertFalse(reason.isEmpty, "\(field) is pending without a reason")
        }
    }

    func testEveryRowIsTitledAndExplained() {
        for control in EditorControlCatalogue.all {
            XCTAssertFalse(control.title.isEmpty, "\(control.field) has no title")
            XCTAssertFalse(control.detail.isEmpty,
                           "\(control.field) has no detail line")
        }
    }

    // MARK: - The numbers are coherent

    func testEveryScaleContainsItsNeutral() {
        for control in EditorControlCatalogue.all {
            guard let scale = control.kind.scale else { continue }
            XCTAssertTrue(scale.range.contains(scale.neutral),
                          "\(control.field) rests at \(scale.neutral), outside "
                          + "\(scale.range)")
        }
    }

    func testEveryAdmittedRangeCoversItsDrawnTravel() {
        for control in EditorControlCatalogue.all {
            guard let scale = control.kind.scale else { continue }
            XCTAssertTrue(scale.admitted.contains(scale.range.lowerBound)
                              && scale.admitted.contains(scale.range.upperBound),
                          "\(control.field) draws \(scale.range) outside its "
                          + "admitted \(scale.admitted)")
        }
    }

    func testHalationAdmitsTheResolvePluginsTypedMaximum() throws {
        let halation = try XCTUnwrap(EditorControlCatalogue.control(.halation))
        let scale = try XCTUnwrap(halation.kind.scale)
        XCTAssertEqual(scale.unit, .stopsFromOff)
        XCTAssertEqual(HalationAmount.scale(fromStops: scale.admitted.upperBound),
                       100, accuracy: 1e-9,
                       "the row no longer admits what the plugin can type")
    }

    // MARK: - The halation row's stops

    func testHalationStopsAndTheStoredMultipleAgree() throws {
        let scale = try XCTUnwrap(
            EditorControlCatalogue.control(.halation)?.kind.scale)
        XCTAssertEqual(HalationAmount.scale(fromStops: scale.neutral), 1,
                       accuracy: 1e-12, "rest must be the film's own look")
        for (stops, multiple) in [(0.0, 1.0), (1.0, 2.0), (-1.0, 0.5),
                                  (-5.0, 1.0 / 32), (3.0, 8.0)] {
            XCTAssertEqual(HalationAmount.scale(fromStops: stops), multiple,
                           accuracy: 1e-12)
            XCTAssertEqual(HalationAmount.stops(fromScale: multiple), stops,
                           accuracy: 1e-12)
        }
    }

    func testTheMeasuredFilmSitsWellInsideTheTrack() throws {
        let scale = try XCTUnwrap(
            EditorControlCatalogue.control(.halation)?.kind.scale)
        // The deepest look scale any shipped sheet states.
        let deepest = HalationAmount.stops(fromScale: 1.0 / 40)
        XCTAssertGreaterThan(deepest, scale.range.lowerBound,
                             "the deepest measured film is off the bottom of the "
                             + "track")
        let fraction = (deepest - scale.range.lowerBound)
            / (scale.range.upperBound - scale.range.lowerBound)
        XCTAssertGreaterThan(fraction, 0.04,
                             "the measured film is crushed against the end of "
                             + "the track, which is what the stops axis is for")
    }

    func testTheBottomOfTheHalationTrackIsOff() throws {
        let scale = try XCTUnwrap(
            EditorControlCatalogue.control(.halation)?.kind.scale)
        XCTAssertEqual(scale.range.lowerBound, EditorControlUnit.offStops)
        XCTAssertEqual(HalationAmount.scale(fromStops: scale.range.lowerBound), 0)
        XCTAssertEqual(HalationAmount.stops(fromScale: 0), scale.range.lowerBound)
        XCTAssertEqual(scale.unit.format(scale.range.lowerBound), "Off")
    }

    func testEveryFaderTrackStartsAtItsOffMark() {
        for control in EditorControlCatalogue.all {
            guard let scale = control.kind.scale,
                  scale.unit == .stopsFromOff else { continue }
            XCTAssertEqual(scale.range.lowerBound, EditorControlUnit.offStops,
                           "\(control.field) draws a fader that does not start "
                           + "at the off mark")
        }
    }

    // MARK: - Curves and the rows they fold out of

    func testEveryCurveRestsInsideItsTravelAndClimbsItsAxis() {
        for control in EditorControlCatalogue.all {
            guard let curve = control.kind.curve else { continue }
            XCTAssertTrue(curve.range.contains(curve.neutral),
                          "\(control.field) rests at \(curve.neutral), outside "
                          + "\(curve.range)")
            XCTAssertFalse(curve.handles.isEmpty,
                           "\(control.field) is a curve with no handles")
            XCTAssertEqual(curve.handles, curve.handles.sorted(),
                           "\(control.field)'s handles do not ascend")
            for handle in curve.handles {
                XCTAssertTrue(curve.domain.contains(handle),
                              "\(control.field) puts a handle at \(handle), off "
                              + "its \(curve.domain) axis")
            }
            XCTAssertFalse(curve.isMoved(curve.restingValues),
                           "\(control.field) badges its own resting curve as an edit")
        }
    }

    func testEveryFoldOutFollowsItsOwnerInTheSameSection() {
        let all = EditorControlCatalogue.all
        for (index, control) in all.enumerated() {
            guard let owner = control.foldsUnder else { continue }
            guard let ownerIndex = all.firstIndex(where: { $0.field == owner })
            else {
                XCTFail("\(control.field) folds under \(owner), which is not "
                        + "catalogued")
                continue
            }
            XCTAssertLessThan(ownerIndex, index,
                              "\(control.field) is drawn before the row it folds "
                              + "under")
            XCTAssertEqual(all[ownerIndex].section, control.section,
                           "\(control.field) folds under a row in another section")
            // The arrow goes on the owner, and the panel only puts one on a slider.
            XCTAssertNotNil(all[ownerIndex].kind.scale,
                            "\(owner) carries a fold-out but is not a slider")
            // A fold-out the film can take under an owner it cannot is an arrow on nothing.
            XCTAssertEqual(all[ownerIndex].availability, control.availability,
                           "\(control.field) and its owner are offered on "
                           + "different films")
        }
    }

    func testTheHalationSpectrumFoldsOutOfTheHalationRow() throws {
        let spectrum = try XCTUnwrap(
            EditorControlCatalogue.control(.halationSpectrum))
        XCTAssertEqual(spectrum.foldsUnder, .halation)
        XCTAssertEqual(spectrum.section, .filmEmulsion)
        let curve = try XCTUnwrap(spectrum.kind.curve)
        XCTAssertEqual(curve.neutral, 0,
                       "no stops added must be the film's own return")
        XCTAssertEqual(curve.unit, .stops,
                       "a masked negative's green return is sixty times under its "
                       + "red, which a multiplier's travel cannot reach")
        XCTAssertEqual(curve.handles,
                       HalationSpectrum.handleNM.map(Double.init),
                       "the drawn ladder and the engine's ladder have parted")
    }

    func testAdmittedDefaultsToTheDrawnTravel() {
        let scale = EditorControlScale(0...2, neutral: 1, unit: .multiplier)
        XCTAssertEqual(scale.admitted, scale.range)
    }

    func testEveryNamedStopLiesInItsTravel() {
        for control in EditorControlCatalogue.all {
            guard case .chips(let scale, let choices) = control.kind else {
                continue
            }
            XCTAssertFalse(choices.isEmpty,
                           "\(control.field) has chips but no stops")
            for choice in choices {
                XCTAssertTrue(scale.range.contains(choice.value),
                              "\(control.field)'s \"\(choice.label)\" stop at "
                              + "\(choice.value) is outside \(scale.range)")
            }
        }
    }

    func testEverySnappedSliderRestsOnAStopInsideItsTravel() {
        for control in EditorControlCatalogue.all {
            guard case .slider(let scale) = control.kind,
                  !scale.stops.isEmpty else { continue }
            for stop in scale.stops {
                XCTAssertTrue(scale.range.contains(stop),
                              "\(control.field)'s stop at \(stop) is outside "
                              + "\(scale.range)")
            }
            XCTAssertTrue(scale.stops.contains(scale.neutral),
                          "\(control.field) rests at \(scale.neutral), which is "
                          + "not one of its stops \(scale.stops)")
            XCTAssertEqual(scale.stops, scale.stops.sorted(),
                           "\(control.field)'s stops are out of order")
        }
    }

    func testTheLabsQuantitiesAreSnappedSliders() throws {
        let push = try XCTUnwrap(EditorControlCatalogue.control(.push))
        guard case .slider(let pushScale) = push.kind else {
            return XCTFail("push is \(push.kind), not a slider")
        }
        XCTAssertEqual(pushScale.stops, [-2, 0, 1, 2])
        XCTAssertEqual(pushScale.range, -2...2,
                       "the travel should end where the stops do")

        let expired = try XCTUnwrap(EditorControlCatalogue.control(.expired))
        guard case .slider(let expiredScale) = expired.kind else {
            return XCTFail("expired is \(expired.kind), not a slider")
        }
        XCTAssertEqual(expiredScale.stops, [0, 5, 10, 20])
        XCTAssertEqual(expiredScale.range, 0...20,
                       "the travel should end where the stops do")

        // Bleach bypass stays chips: off, half and full are three named states of a process, not
        // three amounts of one quantity, and there is no travel between them to slide along.
        let bleach = try XCTUnwrap(EditorControlCatalogue.control(.bleach))
        guard case .chips = bleach.kind else {
            return XCTFail("bleach bypass is \(bleach.kind), not chips")
        }
    }

    func testMovedIsToleranctOfATouchButNotOfAnEdit() {
        let scale = EditorControlScale(-1...1, neutral: 0, unit: .signed)
        XCTAssertFalse(scale.isMoved(0))
        XCTAssertFalse(scale.isMoved(1e-9))
        XCTAssertTrue(scale.isMoved(0.01))

        // Print correction rests at 0.05, not at zero: an untouched print is not "0% correction".
        let correction = EditorControlScale(0...1, neutral: 0.05, unit: .percent)
        XCTAssertFalse(correction.isMoved(0.05))
        XCTAssertTrue(correction.isMoved(0))
    }

    // MARK: - The panel's order

    func testSectionsRunInOrderAndDoNotInterleave() {
        let sections = EditorControlCatalogue.all.map(\.section)
        var seen: [EditorControlSection] = []
        for section in sections where seen.last != section {
            XCTAssertFalse(seen.contains(section),
                           "\(section) appears in more than one run")
            seen.append(section)
        }
        let declared = EditorControlSection.allCases.filter { section in
            EditorControlCatalogue.all.contains { $0.section == section }
        }
        XCTAssertEqual(seen, declared,
                       "panel order does not follow the declared section order")
    }

    func testGroupsRunInOrderAndDoNotInterleave() {
        var seen: [EditorControlGroup] = []
        for group in EditorControlCatalogue.all.map(\.group) where seen.last != group {
            XCTAssertFalse(seen.contains(group),
                           "\(group) appears in more than one run")
            seen.append(group)
        }
        // Against the declared order rather than a copy of it, so the two cannot drift: a group
        // added to the enum and forgotten in the catalogue fails here, and so does one whose
        // rows are scattered through the panel instead of run together.
        XCTAssertEqual(seen, EditorControlGroup.allCases)
        XCTAssertEqual(seen, [.film, .lens, .light, .print, .frame])
    }

    // MARK: - What the film will take

    private func preset(_ id: String) throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets[id], "stock \(id) is not installed")
    }

    func testBleachBypassIsOfferedOnlyToAColourNegative() throws {
        let bleach = try XCTUnwrap(EditorControlCatalogue.control(.bleach))

        XCTAssertTrue(bleach.availability.admits(
            stock: try preset("example-negative-400")))
        XCTAssertFalse(bleach.availability.admits(
            stock: try preset("example-monochrome-100")))
        XCTAssertFalse(bleach.availability.admits(
            stock: try preset("example-reversal-64")))
        XCTAssertFalse(bleach.availability.admits(stock: nil))
    }

    func testThePrintSectionIsAbsentOnAReversalStock() throws {
        let reversal = try preset("example-reversal-64")
        let offered = EditorControlCatalogue.controls(in: .printPaper,
                                                      for: reversal)
        XCTAssertTrue(offered.isEmpty)

        let negative = try preset("example-negative-400")
        XCTAssertEqual(
            EditorControlCatalogue.controls(in: .printPaper, for: negative)
                .map(\.field),
            [.paper, .printLight, .printCorrection])
    }

    /// The grade is available in Light & Color for every develop, film or not, so it survives a
    /// reversal stock and Normal alike: the nine band rows, and the switch that says what all nine
    /// are working on.
    func testTheGradeIsOfferedWhateverTheFilm() throws {
        for stock in [try preset("example-reversal-64"),
                      try preset("example-monochrome-100")] {
            XCTAssertEqual(
                EditorControlCatalogue.controls(in: .lightGrade, for: stock).count,
                10)
        }
        XCTAssertEqual(
            EditorControlCatalogue.controls(in: .lightGrade, for: nil).count, 10)
        XCTAssertEqual(
            EditorControlCatalogue.controls(in: .lightGrade, for: nil).first?.field,
            .gradeSpace,
            "the space the corrector works in stands over the rows it governs")
    }

    func testNormalKeepsTheLightAndLosesTheEmulsion() {
        let fields = Set(EditorControlCatalogue.controls(for: nil).map(\.field))
        for scene: EditorControlField in [.exposure, .warmth, .tint, .highlights,
                                          .shadows, .saturation, .vibrance] {
            XCTAssertTrue(fields.contains(scene), "\(scene) should survive Normal")
        }
        for emulsion: EditorControlField in [.grain, .halation, .couplers,
                                             .push, .bleach, .expired] {
            XCTAssertFalse(fields.contains(emulsion),
                           "\(emulsion) has no meaning without a film")
        }
    }

    func testLongExposureIsOfferedOnlyWhereTheSheetStatesARate() throws {
        let shutter = try XCTUnwrap(EditorControlCatalogue.control(.shutter))
        let rule = shutter.availability
        XCTAssertEqual(rule, .statedReciprocity)
        var stock = try preset("example-negative-400")

        stock.reciprocityFailure = ReciprocityFailure(thresholdSeconds: 1,
                                                     lostStopsPerDecade: 0.83,
                                                     statedThroughSeconds: 16)
        XCTAssertTrue(rule.admits(stock: stock))

        stock.reciprocityFailure = ReciprocityFailure(thresholdSeconds: 1,
                                                     lostStopsPerDecade: 0)
        XCTAssertFalse(rule.admits(stock: stock),
                       "a stated hold must not offer a correction")

        stock.reciprocityFailure = nil
        XCTAssertFalse(rule.admits(stock: stock))
        XCTAssertFalse(rule.admits(stock: nil))
    }

    func testPushPullIsOfferedOnlyWithAMeasuredDevelopmentFamily() throws {
        let push = try XCTUnwrap(EditorControlCatalogue.control(.push))
        XCTAssertEqual(push.availability, .measuredDevelopment)
        var stock = try preset("example-negative-400")

        XCTAssertFalse(push.availability.admits(stock: stock))
        XCTAssertFalse(EditorControlCatalogue.controls(for: stock).contains { $0.field == .push })

        stock.developmentProfile = FilmDevelopmentProfile(
            developer: "test", temperatureC: 20, agitation: "test",
            source: "test measurement", sourcePage: 1,
            conditions: [FilmDevelopmentCondition(
                stops: 1, label: "Push 1", timeMinutes: 10,
                curves: stock.curves)])
        XCTAssertTrue(push.availability.admits(stock: stock))
        let measured = try XCTUnwrap(
            EditorControlCatalogue.controls(for: stock).first { $0.field == .push })
        guard case .slider(let scale) = measured.kind else {
            return XCTFail("push is \(measured.kind), not a slider")
        }
        XCTAssertEqual(scale.range, 0...1)
        XCTAssertEqual(scale.stops, [0, 1])
    }

    // MARK: - Against the engine itself

    func testEveryEngineOptionIsAccountedFor() {
        let options = Mirror(reflecting: FotufilmEngine.Options())
            .children.compactMap(\.label)
        XCTAssertFalse(options.isEmpty, "Mirror found no options to check")

        let classified = Set(EngineOptionCoverage.byOptionName.keys)
        XCTAssertEqual(Set(options), classified,
                       "unclassified: \(Set(options).subtracting(classified)); "
                       + "stale: \(classified.subtracting(Set(options)))")
    }

    func testEveryControlNamedByTheCoverageMapExists() {
        let catalogued = Set(EditorControlCatalogue.all.map(\.field))
        for (option, coverage) in EngineOptionCoverage.byOptionName {
            guard case .control(let fields) = coverage else { continue }
            XCTAssertFalse(fields.isEmpty, "\(option) names no control")
            for field in fields {
                XCTAssertTrue(catalogued.contains(field),
                              "\(option) names \(field), which is not offered")
            }
        }
    }

    func testTheKnownGapsAreTheDeclaredGaps() {
        let unexposedOrGlobal = EngineOptionCoverage.byOptionName
            .filter { _, coverage in
                switch coverage {
                case .unexposed, .globalSetting: return true
                case .control, .derived: return false
                }
            }
            .keys.sorted()

        XCTAssertEqual(unexposedOrGlobal,
                       ["couplerRangeScale", "flareScale", "halationHazeMM",
                        "negativeViewing", "stage", "textureStages",
                        "useEstimatedHalationProfile"])
    }

    func testTheAuditedGapsAreAllOffered() {
        let catalogued = Set(EditorControlCatalogue.all.map(\.field))
        for field: EditorControlField in [.localTone, .grainMottle, .grainModel,
                                          .couplerReach, .couplerSelf, .shutter,
                                          .gradeSpace] {
            XCTAssertTrue(catalogued.contains(field), "\(field) has no row")
        }
        XCTAssertTrue(EditorControlCatalogue.pending.isEmpty,
                      "still pending: \(EditorControlCatalogue.pending.keys)")
    }

    func testTheCouplerGeometryRowsNeedALayerModel() throws {
        for field: EditorControlField in [.couplerReach, .couplerSelf] {
            let control = try XCTUnwrap(EditorControlCatalogue.control(field))
            XCTAssertEqual(control.availability, .couplerGeometry)
        }

        var stock = try preset("example-negative-400")
        XCTAssertTrue(
            EditorControlAvailability.couplerGeometry.admits(stock: stock))
        stock.couplerGeometry = nil
        XCTAssertFalse(
            EditorControlAvailability.couplerGeometry.admits(stock: stock),
            "a fixed matrix has no geometry to scale")
        XCTAssertFalse(
            EditorControlAvailability.couplerGeometry.admits(stock: nil))
    }

    // MARK: - Reading the numbers

    func testValuesReadAsTheSheetsWriteThem() {
        XCTAssertEqual(EditorControlUnit.stops.format(2), "+2.0 EV")
        XCTAssertEqual(EditorControlUnit.stopsFromOff.format(2), "+2.0 EV")
        XCTAssertEqual(EditorControlUnit.stopsFromOff.format(-2), "-2.0 EV")
        XCTAssertEqual(
            EditorControlUnit.stopsFromOff.format(EditorControlUnit.offStops),
            "Off")
        XCTAssertEqual(EditorControlUnit.stops.format(-1), "-1.0 EV")
        XCTAssertEqual(EditorControlUnit.multiplier.format(1), "1.00×")
        XCTAssertEqual(EditorControlUnit.percent.format(0.05), "5%")
        XCTAssertEqual(EditorControlUnit.years.format(0), "Fresh")
        XCTAssertEqual(EditorControlUnit.years.format(10), "10 yr")
        XCTAssertEqual(EditorControlUnit.seconds.format(30), "30 s")
        XCTAssertEqual(EditorControlUnit.seconds.format(0.5), "0.50 s")
        XCTAssertEqual(EditorControlUnit.kelvin.format(5003), "5003 K")
    }

    func testAValueThatRoundsToZeroReadsWithoutASign() {
        XCTAssertEqual(EditorControlUnit.signed.format(-1e-17), "+0.00")
        XCTAssertEqual(EditorControlUnit.signed.format(-0.0001), "+0.00")
        XCTAssertEqual(EditorControlUnit.signed.format(0), "+0.00")
        XCTAssertEqual(EditorControlUnit.stops.format(-0.001), "+0.0 EV")
        XCTAssertEqual(EditorControlUnit.degrees.format(-0.001), "+0.0°")
        XCTAssertEqual(EditorControlUnit.multiplier.format(-1e-9), "0.00×")
        XCTAssertEqual(EditorControlUnit.percent.format(-1e-9), "0%")
        XCTAssertEqual(EditorControlUnit.kelvin.format(-0.2), "0 K")
        XCTAssertEqual(EditorControlUnit.seconds.format(-0.001), "0.00 s")
    }

    func testAValueThatShowsKeepsItsSign() {
        XCTAssertEqual(EditorControlUnit.signed.format(-0.01), "-0.01")
        XCTAssertEqual(EditorControlUnit.stops.format(-0.05), "-0.1 EV")
        XCTAssertEqual(EditorControlUnit.degrees.format(-0.4), "-0.4°")
        XCTAssertEqual(EditorControlUnit.multiplier.format(0.995), "1.00×")
    }
}
