import XCTest
@testable import FotufilmCore
@testable import FotufilmStockMatch

final class StockPreferenceModelTests: XCTestCase {

    private let films = ["portra", "velvia", "trix", "gold", "provia", "ektar"]
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func next(_ seed: inout UInt64) -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float((seed >> 33) % 100_000) / 100_000
    }

    private func candidates(seed: inout UInt64, scale: Float = 1)
        -> [(id: String, features: StockFeatures)] {
        films.map { film in
            var features = StockFeatures()
            for term in StockFeatures.Term.allCases {
                features[term] = term.isPenalty
                    ? next(&seed) * 0.6 * scale
                    : (next(&seed) - 0.5) * 1.2 * scale
            }
            return (film, features)
        }
    }

    private func history(
        count: Int, seed start: UInt64 = 3, scale: Float = 1,
        spacing: TimeInterval = 3600, from: Date? = nil,
        choose: ([(id: String, features: StockFeatures)]) -> String
    ) -> StockPreference.History {
        var seed = start
        var history = StockPreference.History()
        let base = from ?? epoch
        for index in 0..<count {
            let table = candidates(seed: &seed, scale: scale)
            history.record(StockPreference.Observation(
                photoID: "photo-\(base.timeIntervalSince1970)-\(index)",
                recorded: base.addingTimeInterval(Double(index) * spacing),
                chosenFilmID: choose(table), proposedFilmID: nil,
                candidates: table))
        }
        return history
    }

    private func objective(_ weights: StockWeights,
                           _ history: StockPreference.History,
                           now: Date) -> Double {
        var total = 0.0
        var counted = 0
        for observation in history.observations where observation.isUsable {
            let sample = observation.weight(
                now: now, halflife: StockPreference.kHalflife)
            guard sample > StockPreference.kNegligible else { continue }
            counted += 1

            var scores: [Double] = []
            var chosen = 0.0
            for slot in observation.films.indices {
                let film = observation.films[slot]
                let score = Double(weights.score(observation.vector(slot),
                                                 film: film))
                scores.append(score)
                if film == observation.chosenFilmID { chosen = score }
            }
            let best = scores.min() ?? 0
            let sum = scores.reduce(0) { $0 + exp(-($1 - best)) }
            total += Double(sample) * ((chosen - best) + log(sum))
        }
        guard counted > 0 else { return 0 }

        var penalty = 0.0
        for index in weights.terms.indices {
            let drift = Double(weights.terms[index]
                               - StockPreference.prior.terms[index])
            penalty += Double(StockPreference.kTermRegularisation)
                * drift * drift / 2
        }
        for bias in weights.bias.values {
            penalty += Double(StockPreference.kBiasRegularisation)
                * Double(bias) * Double(bias) / 2
        }
        return total / Double(counted) + penalty
    }

    private func fitted(_ shrunk: StockWeights,
                        _ history: StockPreference.History,
                        now: Date) -> StockWeights {
        var total: Float = 0
        for observation in history.observations where observation.isUsable {
            let sample = observation.weight(
                now: now, halflife: StockPreference.kHalflife)
            if sample > StockPreference.kNegligible { total += sample }
        }
        let trust = total / (total + StockPreference.kConfidence)
        var undone = shrunk
        for index in undone.terms.indices {
            let prior = StockPreference.prior.terms[index]
            undone.terms[index] = prior + (shrunk.terms[index] - prior) / trust
        }
        for (film, bias) in shrunk.bias { undone.bias[film] = bias / trust }
        return undone
    }

    private func numericalGradient(at weights: StockWeights,
                                   _ history: StockPreference.History,
                                   now: Date) -> [Double] {
        let step = 1e-3
        var gradient: [Double] = []
        for index in weights.terms.indices {
            var up = weights, down = weights
            up.terms[index] += Float(step)
            down.terms[index] -= Float(step)
            gradient.append((objective(up, history, now: now)
                             - objective(down, history, now: now)) / (2 * step))
        }
        for film in weights.bias.keys.sorted() {
            var up = weights, down = weights
            up.bias[film] = (up.bias[film] ?? 0) + Float(step)
            down.bias[film] = (down.bias[film] ?? 0) - Float(step)
            gradient.append((objective(up, history, now: now)
                             - objective(down, history, now: now)) / (2 * step))
        }
        return gradient
    }

    private func magnitude(_ vector: [Double]) -> Double {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    func testTrainingLowersTheObjectiveItClaimsToMinimise() {
        let now = epoch.addingTimeInterval(200 * 3600)
        let taste = history(count: 150) { table in
            table.min {
                $0.features[.clipping] * 4 - $0.features[.chromaDelta] * 2
                    < $1.features[.clipping] * 4 - $1.features[.chromaDelta] * 2
            }!.id
        }
        let learned = StockPreference.train(taste, now: now)
        let start = objective(StockPreference.prior, taste, now: now)
        let end = objective(fitted(learned, taste, now: now), taste, now: now)
        print(String(format: "StockPreference objective: %.4f -> %.4f",
                     start, end))
        XCTAssertLessThan(end, start,
                          "training moved to a worse point than the prior")
    }

    func testTheDescentReachesAStationaryPoint() {
        let now = epoch.addingTimeInterval(200 * 3600)
        let taste = history(count: 150) { table in
            table.min {
                $0.features[.clipping] * 4 - $0.features[.chromaDelta] * 2
                    < $1.features[.clipping] * 4 - $1.features[.chromaDelta] * 2
            }!.id
        }
        let learned = fitted(StockPreference.train(taste, now: now),
                             taste, now: now)
        let atStart = magnitude(numericalGradient(
            at: StockPreference.prior, taste, now: now))
        let atEnd = magnitude(numericalGradient(at: learned, taste, now: now))
        print(String(format: "StockPreference |gradient|: %.4f -> %.4f",
                     atStart, atEnd))
        XCTAssertLessThan(atEnd, atStart * 0.1,
                          "the descent stopped somewhere with a slope on it")
    }

    func testTheAnalyticGradientPointsWhereTheNumericalOneDoes() {
        let now = epoch.addingTimeInterval(50 * 3600)
        let taste = history(count: 40, seed: 11) { table in
            table.max { $0.features[.warmthDelta] < $1.features[.warmthDelta] }!
                .id
        }
        let numerical = numericalGradient(at: StockPreference.prior,
                                          taste, now: now)
        let terms = Array(numerical.prefix(StockFeatures.count))
        XCTAssertGreaterThan(magnitude(terms), 1e-4,
                             "the fixture has nothing to learn")

        let learned = fitted(StockPreference.train(taste, now: now),
                             taste, now: now)
        var travelled: [Double] = []
        for index in learned.terms.indices {
            travelled.append(Double(learned.terms[index]
                                    - StockPreference.prior.terms[index]))
        }
        let dot = zip(terms, travelled).reduce(0) { $0 + $1.0 * $1.1 }
        let cosine = dot / (magnitude(terms) * magnitude(travelled))
        print(String(format: "StockPreference gradient alignment: %.3f",
                     cosine))
        XCTAssertLessThan(cosine, -0.5,
                          "the weights moved across the gradient, not down it")
    }

    func testRecentChoicesOutweighOldOnes() {
        var combined = history(count: 60, seed: 5, spacing: 9 * 24 * 3600) {
            _ in "velvia"
        }
        let recent = history(count: 20, seed: 7, spacing: 12 * 3600,
                             from: epoch.addingTimeInterval(540 * 24 * 3600)) {
            _ in "portra"
        }
        for observation in recent.observations { combined.record(observation) }

        let now = epoch.addingTimeInterval(552 * 24 * 3600)
        let decayed = StockPreference.train(combined, now: now)
        let undecayed = StockPreference.train(combined, now: epoch)

        let decayedGap = (decayed.bias["portra"] ?? 0)
            - (decayed.bias["velvia"] ?? 0)
        let undecayedGap = (undecayed.bias["portra"] ?? 0)
            - (undecayed.bias["velvia"] ?? 0)
        print(String(format: "StockPreference recency: gap %.3f decayed, "
                     + "%.3f undecayed", decayedGap, undecayedGap))
        XCTAssertLessThan(decayedGap, undecayedGap,
                          "ageing the old choices did not favour the new ones")
    }

    func testTheOldestObservationsFallOffTheEnd() {
        var full = StockPreference.History()
        var seed: UInt64 = 21
        let overflow = StockPreference.kMaxObservations + 50
        for index in 0..<overflow {
            full.record(StockPreference.Observation(
                photoID: "photo-\(index)",
                recorded: epoch.addingTimeInterval(Double(index) * 3600),
                chosenFilmID: "velvia", proposedFilmID: nil,
                candidates: candidates(seed: &seed)))
        }
        XCTAssertEqual(full.observations.count,
                       StockPreference.kMaxObservations)
        XCTAssertEqual(full.observations.first?.photoID, "photo-50",
                       "the cap dropped the wrong end")
        XCTAssertEqual(full.observations.last?.photoID,
                       "photo-\(overflow - 1)")
    }

    func testABiasCannotGrowWithoutBound() {
        let now = epoch.addingTimeInterval(500 * 3600)
        let devoted = history(count: StockPreference.kMaxObservations,
                              seed: 31) { _ in "velvia" }
        let learned = StockPreference.train(devoted, now: now)
        let bias = learned.bias["velvia"] ?? 0
        print(String(format: "StockPreference devoted-user bias: %.3f", bias))
        XCTAssertLessThan(bias, 0, "the film they always pick got no credit")
        XCTAssertGreaterThan(bias, -20,
                             "the bias ran away; the L2 pull is not holding")
        for weight in learned.terms {
            XCTAssertTrue(weight.isFinite)
        }
    }

    func testHugeFeatureValuesDoNotProduceNonsense() {
        let now = epoch.addingTimeInterval(100 * 3600)
        let wild = history(count: 60, seed: 41, scale: 500) { table in
            table.min { $0.features[.clipping] < $1.features[.clipping] }!.id
        }
        let learned = StockPreference.train(wild, now: now)
        for (index, weight) in learned.terms.enumerated() {
            let name = StockFeatures.Term(rawValue: index)?.name ?? "?"
            XCTAssertTrue(weight.isFinite, "\(name) came back \(weight)")
        }
        for (film, bias) in learned.bias {
            XCTAssertTrue(bias.isFinite, "\(film) bias came back \(bias)")
        }
    }

    func testAnObservationFullOfNonsenseIsIgnored() {
        var poisoned = history(count: 30, seed: 51) { _ in "velvia" }
        let clean = StockPreference.train(poisoned, now: epoch)
        var rogue = poisoned.observations[0]
        rogue.photoID = "rogue"
        rogue.features = rogue.features.map { _ in Float.nan }
        poisoned.record(rogue)
        let after = StockPreference.train(poisoned, now: epoch)
        for index in after.terms.indices {
            XCTAssertTrue(after.terms[index].isFinite,
                          "a NaN observation poisoned the terms")
        }
        XCTAssertEqual(after.terms, clean.terms,
                       "a NaN observation was allowed to move the weights")
    }

    func testTrainingIsDeterministic() {
        let taste = history(count: 90, seed: 61) { table in
            table.min { $0.features[.structureLoss] < $1.features[.structureLoss] }!
                .id
        }
        let now = epoch.addingTimeInterval(120 * 3600)
        let first = StockPreference.train(taste, now: now)
        let second = StockPreference.train(taste, now: now)
        XCTAssertEqual(first.terms, second.terms)
        XCTAssertEqual(first.bias, second.bias)

        var shuffled = StockPreference.History()
        for observation in taste.observations.reversed() {
            shuffled.record(observation)
        }
        let reordered = StockPreference.train(shuffled, now: now)
        for index in first.terms.indices {
            XCTAssertEqual(first.terms[index], reordered.terms[index],
                           accuracy: 1e-4,
                           "the answer depends on insertion order")
        }
    }

    func testALearnedBiasCannotRankAnIneligibleFilm() {
        let width = 24, height = 18
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = 0.6
            pixels[index * 4 + 1] = 0.15
            pixels[index * 4 + 2] = 0.1
            pixels[index * 4 + 3] = 1
        }
        guard let scene = pixels.withUnsafeBufferPointer({ source in
            StockRanking.read(linearRGBA: source.baseAddress!,
                              width: width, height: height)
        }) else { return XCTFail("the scene would not read") }
        XCTAssertGreaterThan(scene.description.chromaMedian,
                             StockMatch.kColourlessCeiling,
                             "the fixture is not a colour photograph")

        let mono = StockRanking.Film(id: "mono", name: "Mono",
                                     stock: TestStocks.monochrome)
        var adoring = StockPreference.prior
        adoring.bias["mono"] = -1000
        let ranking = StockRanking.rank(scene: scene, films: [mono],
                                        weights: adoring) { _, bytes, _, _ in
            for index in bytes.indices { bytes[index] = 128 }
            return true
        }
        XCTAssertTrue(ranking.ordered.isEmpty,
                      "a bias got a monochrome film onto a colour photograph")
    }

    func testTheLearnerOnlyReordersFilmsThatWereRanked() {
        let width = 24, height = 18
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let level = 0.05 + 0.9 * Float(index % width) / Float(width)
            pixels[index * 4] = level
            pixels[index * 4 + 1] = level * 0.9
            pixels[index * 4 + 2] = level * 0.8
            pixels[index * 4 + 3] = 1
        }
        guard let scene = pixels.withUnsafeBufferPointer({ source in
            StockRanking.read(linearRGBA: source.baseAddress!,
                              width: width, height: height)
        }) else { return XCTFail("the scene would not read") }

        let pack = TestStocks.all.enumerated().map { index, stock in
            StockRanking.Film(id: "film-\(index)", name: "Film \(index)",
                              stock: stock)
        }
        func rank(_ weights: StockWeights) -> [String] {
            StockRanking.rank(scene: scene, films: pack,
                              weights: weights) { _, bytes, _, _ in
                for index in bytes.indices {
                    bytes[index] = UInt8((index * 7) % 256)
                }
                return true
            }.ordered.map(\.id)
        }
        let byPrior = rank(StockPreference.prior)
        var opinionated = StockPreference.prior
        opinionated.bias[byPrior.last ?? ""] = -50
        let byTaste = rank(opinionated)

        XCTAssertEqual(Set(byPrior), Set(byTaste),
                       "learning changed which films were eligible")
        XCTAssertEqual(byTaste.first, byPrior.last,
                       "the film it was taught to love did not come first")
    }
}
