import XCTest
@testable import FotufilmCore
@testable import FotufilmStockMatch

final class StockPreferenceTests: XCTestCase {

    private let films = ["portra", "velvia", "trix", "gold", "provia",
                         "ektar", "cinestill", "acros"]

    private func candidates(seed: inout UInt64)
        -> [(id: String, features: StockFeatures)] {
        films.map { film in
            var features = StockFeatures()
            for term in StockFeatures.Term.allCases {
                features[term] = term.isPenalty
                    ? abs(next(&seed)) * 0.6
                    : (next(&seed) - 0.5) * 1.2
            }
            return (film, features)
        }
    }

    private func next(_ seed: inout UInt64) -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float((seed >> 33) % 100_000) / 100_000
    }

    private func history(
        count: Int, seed start: UInt64 = 1,
        proposedByPrior: Bool = false,
        choose: ([(id: String, features: StockFeatures)]) -> String
    ) -> StockPreference.History {
        var seed = start
        var history = StockPreference.History()
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            let table = candidates(seed: &seed)
            let proposed = proposedByPrior
                ? table.min {
                    StockPreference.prior.score($0.features, film: $0.id)
                        < StockPreference.prior.score($1.features, film: $1.id)
                }?.id
                : nil
            history.record(StockPreference.Observation(
                photoID: "photo-\(index)",
                recorded: epoch.addingTimeInterval(Double(index) * 3600),
                chosenFilmID: choose(table), proposedFilmID: proposed,
                candidates: table))
        }
        return history
    }

    func testWithNothingLearnedTheWeightsAreExactlyThePrior() {
        let weights = StockPreference.train(StockPreference.History())
        XCTAssertEqual(weights.terms, StockPreference.prior.terms)
        XCTAssertTrue(weights.bias.isEmpty)
    }

    func testTheSignedDescriptorsStartAtZero() {
        for term in StockFeatures.Term.allCases where !term.isPenalty {
            XCTAssertEqual(StockPreference.prior.terms[term.rawValue], 0,
                           "\(term.name) must cost nothing until it is learned")
        }
    }

    func testTheAnalyticFitMatchesThePriorWeightedFeatures() {
        let scene = StockMatch.SceneDescription(
            regionStops: (0..<256).map { -6 + 10 * Float($0) / 255 },
            chromaMedian: 0.3, chromaHigh: 0.4, specularFraction: 0.01,
            textureEnergy: 0.05)
        for stock in TestStocks.all {
            let fit = StockMatch.fit(scene: scene, stock: stock)
            let raw = StockMatch.analytic(scene: scene, stock: stock)
            XCTAssertEqual(fit.isEligible, raw.isEligible)
            XCTAssertEqual(fit.meterMiss,
                           StockMatch.kMeterWeight * raw.features[.meterMiss],
                           accuracy: 1e-6)
            XCTAssertEqual(fit.outsideLatitude,
                           StockMatch.kOutsideWeight
                            * raw.features[.outsideLatitude], accuracy: 1e-6)
            XCTAssertEqual(fit.recoveryDemand,
                           StockMatch.kRecoveryWeight
                            * raw.features[.recoveryDemand], accuracy: 1e-6)
            XCTAssertEqual(fit.grainExposure,
                           StockMatch.kGrainWeight
                            * raw.features[.grainOnSmoothFrame], accuracy: 1e-6)
        }
    }

    func testItLearnsAFilmSomeoneAlwaysPicks() {
        let learned = StockPreference.train(history(count: 60) { _ in "velvia" })
        guard let velvia = learned.bias["velvia"] else {
            return XCTFail("velvia was never given a bias")
        }
        for film in films where film != "velvia" {
            XCTAssertLessThan(velvia, learned.bias[film] ?? 0,
                              "velvia should be cheaper than \(film)")
        }
    }

    func testItLearnsATermSomeoneChoosesBy() {
        let learned = StockPreference.train(history(count: 80) { table in
            table.max { $0.features[.chromaDelta] < $1.features[.chromaDelta] }!
                .id
        })
        XCTAssertLessThan(learned.terms[StockFeatures.Term.chromaDelta.rawValue],
                          -0.05,
                          "more colour should have become a reason to choose")
    }

    func testItDoesNotInventAPreferenceFromNoise() {
        var seed: UInt64 = 99
        let learned = StockPreference.train(history(count: 40) { table in
            table[Int(next(&seed) * Float(table.count)) % table.count].id
        })
        for film in films {
            XCTAssertLessThan(abs(learned.bias[film] ?? 0), 0.35,
                              "\(film) picked up a bias from random choices")
        }
    }

    func testAFewPhotographsBarelyMoveAnything() {
        let three = StockPreference.train(history(count: 3) { _ in "velvia" })
        let many = StockPreference.train(history(count: 200) { _ in "velvia" })
        let small = abs(three.bias["velvia"] ?? 0)
        let large = abs(many.bias["velvia"] ?? 0)
        XCTAssertLessThan(small, large / 4,
                          "three photographs should not swing the pack")
    }

    func testAKeptSuggestionCountsForLessThanACorrection() {
        let corrected = StockPreference.train(
            history(count: 80, proposedByPrior: true) { _ in "velvia" })
        let agreed = StockPreference.train(
            history(count: 80, proposedByPrior: true) { table in
                table.min {
                    StockPreference.prior.score($0.features, film: $0.id)
                        < StockPreference.prior.score($1.features, film: $1.id)
                }!.id
            })
        let movement = { (weights: StockWeights) -> Float in
            zip(weights.terms, StockPreference.prior.terms)
                .reduce(0) { $0 + abs($1.0 - $1.1) }
                + weights.bias.values.reduce(0) { $0 + abs($1) }
        }
        XCTAssertLessThan(movement(agreed), movement(corrected),
                          "agreeing with the suggestion moved the model more "
                          + "than correcting it")
    }

    func testItBeatsBothBaselinesOnAConsistentUser() {
        let taste = history(count: 120) { table in
            table.min {
                $0.features[.clipping] * 6 - $0.features[.grainAmount]
                    < $1.features[.clipping] * 6 - $1.features[.grainAmount]
            }!.id
        }
        let report = StockPreference.evaluate(taste)
        print("StockPreference synthetic user:")
        for line in report.lines { print(line) }

        XCTAssertGreaterThan(report.learnedTop1, report.priorTop1,
                             "learning did not beat the hand-set weights")
        XCTAssertGreaterThan(report.learnedTop1, report.frequentTop1,
                             "learning did not beat 'always the usual film'")
    }

    func testHistoryReplacesRatherThanAppends() {
        var history = StockPreference.History()
        var seed: UInt64 = 7
        let table = candidates(seed: &seed)
        for film in ["portra", "velvia", "trix"] {
            history.record(StockPreference.Observation(
                photoID: "same", chosenFilmID: film, proposedFilmID: nil,
                candidates: table))
        }
        XCTAssertEqual(history.observations.count, 1)
        XCTAssertEqual(history.observations.first?.chosenFilmID, "trix")

        history.revise(photoID: "same", chosenFilmID: "gold")
        XCTAssertEqual(history.observations.first?.chosenFilmID, "gold")
        history.revise(photoID: "same", chosenFilmID: "not-in-the-pack")
        XCTAssertEqual(history.observations.first?.chosenFilmID, "gold")
    }

    func testAHistoryFromAnotherVersionIsIgnored() {
        var stale = history(count: 40) { _ in "velvia" }
        stale.version = StockPreference.kVersion - 1
        XCTAssertEqual(StockPreference.train(stale).terms,
                       StockPreference.prior.terms)
    }

    func testTrainingIsFastEnoughToRunOnEverySave() throws {
        // The budget is a claim about the shipped app, which is optimised.
        // Unoptimised, the same training measures ~1.5 s against the 400 ms
        // ceiling while release measures ~6.5 ms, so running the assertion
        // here would report a build configuration rather than a regression.
        try XCTSkipIf(_isDebugAssertConfiguration(),
                      "training budget is only meaningful in a release build")
        let full = history(count: StockPreference.kMaxObservations) { table in
            table.min { $0.features[.clipping] < $1.features[.clipping] }!.id
        }
        var best = Double.infinity
        for _ in 0..<3 {
            let start = DispatchTime.now()
            _ = StockPreference.train(full)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds
                                    - start.uptimeNanoseconds) / 1_000_000)
        }
        print(String(format: "StockPreference train: %.1f ms for %d "
                     + "observations x %d films",
                     best, full.observations.count, films.count))
        XCTAssertLessThan(best, 400, "training has become too slow to run "
                          + "when a photograph is saved")
    }

    func testAnObservationSurvivesBeingWrittenAndRead() throws {
        let original = history(count: 5) { _ in "portra" }
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StockPreference.History.self,
                                                from: data)
        XCTAssertEqual(original, restored)
        XCTAssertEqual(StockPreference.train(restored).bias["portra"],
                       StockPreference.train(original).bias["portra"])
    }
}
