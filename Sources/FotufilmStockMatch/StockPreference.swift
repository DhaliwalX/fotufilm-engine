import Foundation

/// Learns stock-ranking weights from user selections.
public enum StockPreference {

    /// Default ranking weights used before enough observations are available.
    public static let prior = StockWeights(terms: [
        StockMatch.kMeterWeight,
        StockMatch.kOutsideWeight,
        StockMatch.kRecoveryWeight,
        StockMatch.kGrainWeight,
        StockRanking.kClipWeight,
        StockRanking.kStructureWeight,
        StockRanking.kChromaWeight,
        0, 0, 0, 0, 0,
    ])

    /// One photograph that settled on a film.
    public struct Observation: Codable, Equatable, Sendable {
        /// The shelf's id, so a later change of mind replaces this rather
        /// than appending a second opinion.
        public var photoID: String
        public var recorded: Date
        public var chosenFilmID: String
        /// What auto-apply proposed, if it was on.
        public var proposedFilmID: String?
        public var films: [String]
        /// Row-major, `films.count * StockFeatures.count`.
        public var features: [Float]

        public init(photoID: String, recorded: Date = Date(),
                    chosenFilmID: String, proposedFilmID: String?,
                    candidates: [(id: String, features: StockFeatures)]) {
            self.photoID = photoID
            self.recorded = recorded
            self.chosenFilmID = chosenFilmID
            self.proposedFilmID = proposedFilmID
            films = candidates.map(\.id)
            features = candidates.flatMap(\.features.values)
        }

        func vector(_ index: Int) -> StockFeatures {
            let start = index * StockFeatures.count
            guard start + StockFeatures.count <= features.count else {
                return StockFeatures()
            }
            return StockFeatures(
                values: Array(features[start..<start + StockFeatures.count]))
        }

        /// Excludes non-finite observations from learning-rate and shrinkage calculations.
        var isUsable: Bool {
            films.count > 1 && films.contains(chosenFilmID)
                && features.count == films.count * StockFeatures.count
                && features.allSatisfy(\.isFinite)
        }

        /// Downweights accepted recommendations to reduce feedback from the model's own output.
        func weight(now: Date, halflife: TimeInterval) -> Float {
            let agreed = proposedFilmID == chosenFilmID
            let strength: Float = proposedFilmID == nil ? 1
                : (agreed ? kKeptSuggestionWeight : 1)
            let age = max(0, now.timeIntervalSince(recorded))
            return strength * Float(pow(0.5, age / halflife))
        }
    }

    public struct History: Codable, Equatable, Sendable {
        public var version: Int
        public var observations: [Observation]

        public init(version: Int = kVersion, observations: [Observation] = []) {
            self.version = version
            self.observations = observations
        }

        /// Replaces any earlier observation of the same photograph: browsing
        /// the strip and settling is one opinion, not ten.
        public mutating func record(_ observation: Observation) {
            observations.removeAll { $0.photoID == observation.photoID }
            observations.append(observation)
            if observations.count > kMaxObservations {
                observations.removeFirst(observations.count - kMaxObservations)
            }
        }

        /// Keeps the features, changes only the verdict — for a photograph reopened and moved to
        /// another film with no ranking in hand.
        public mutating func revise(photoID: String, chosenFilmID: String,
                                    at date: Date = Date()) {
            guard let index = observations.firstIndex(where: {
                $0.photoID == photoID
            }), observations[index].films.contains(chosenFilmID) else { return }
            observations[index].chosenFilmID = chosenFilmID
            observations[index].recorded = date
        }

        /// An older build's history has feature columns this one cannot fill.
        public var isReadable: Bool { version == kVersion }
    }

    /// Flattened once so the epoch loop allocates nothing: rebuilding feature vectors per epoch was
    /// ~1.7M allocations for a full history.
    struct Batch {
        var vectors: [SIMD16<Float>] = []
        /// Index into `films`, parallel to `vectors`.
        var film: [Int] = []
        /// `[start, end)` in `vectors`, per observation.
        var span: [Range<Int>] = []
        var chosen: [Int] = []
        var weight: [Float] = []
        var films: [String] = []

        init(_ observations: [Observation], now: Date) {
            var index: [String: Int] = [:]
            for observation in observations where observation.isUsable {
                let sample = observation.weight(now: now, halflife: kHalflife)
                guard sample > kNegligible else { continue }
                let start = vectors.count
                var chose = start
                for slot in observation.films.indices {
                    let name = observation.films[slot]
                    if index[name] == nil {
                        index[name] = films.count
                        films.append(name)
                    }
                    vectors.append(observation.vector(slot).storage)
                    film.append(index[name]!)
                    if name == observation.chosenFilmID {
                        chose = vectors.count - 1
                    }
                }
                span.append(start..<vectors.count)
                chosen.append(chose)
                weight.append(sample)
            }
        }

        var isEmpty: Bool { span.isEmpty }
    }

    /// Fits weights to `history` and shrinks them toward `prior`.
    public static func train(_ history: History,
                             now: Date = Date()) -> StockWeights {
        guard history.isReadable else { return prior }
        let batch = Batch(history.observations, now: now)
        guard !batch.isEmpty else { return prior }

        var termVector = SIMD16<Float>.zero
        for index in prior.terms.indices { termVector[index] = prior.terms[index] }
        let priorVector = termVector
        var bias = [Float](repeating: 0, count: batch.films.count)
        var probability = [Float](repeating: 0, count: batch.vectors.count)

        let scale = kRate / Float(batch.span.count)
        for _ in 0..<kEpochs {
            var termGradient = SIMD16<Float>.zero
            var biasGradient = [Float](repeating: 0, count: bias.count)

            for observation in batch.span.indices {
                let span = batch.span[observation]
                let sample = batch.weight[observation]

                var best = Float.infinity
                for slot in span {
                    let score = (termVector * batch.vectors[slot]).sum()
                        + bias[batch.film[slot]]
                    probability[slot] = -score
                    best = min(best, score)
                }
                var sum = 0 as Float
                for slot in span {
                    probability[slot] = exp(probability[slot] + best)
                    sum += probability[slot]
                }
                guard sum > 0, sum.isFinite else { continue }

                let chosen = batch.chosen[observation]
                for slot in span {
                    let residual = sample
                        * ((slot == chosen ? 1 : 0) - probability[slot] / sum)
                    termGradient += batch.vectors[slot] * residual
                    biasGradient[batch.film[slot]] += residual
                }
            }

            termVector -= scale * termGradient
                + kRate * kTermRegularisation * (termVector - priorVector)
            for slot in bias.indices {
                bias[slot] -= scale * biasGradient[slot]
                    + kRate * kBiasRegularisation * bias[slot]
            }
        }

        let trust = batch.weight.reduce(0, +) / (batch.weight.reduce(0, +)
                                                 + kConfidence)
        var shrunk = prior
        for term in shrunk.terms.indices {
            shrunk.terms[term] += trust * (termVector[term] - priorVector[term])
        }
        for (slot, name) in batch.films.enumerated() {
            shrunk.bias[name] = trust * bias[slot]
        }
        return shrunk
    }

    public struct Report: Equatable, Sendable {
        public var observations = 0
        public var learnedTop1 = 0
        public var learnedTop3 = 0
        public var priorTop1 = 0
        public var priorTop3 = 0
        /// "Whatever film you use most" — the bar a per-film bias has to
        /// clear to have earned its parameters.
        public var frequentTop1 = 0

        public var lines: [String] {
            guard observations > 0 else { return ["no observations"] }
            func share(_ hits: Int) -> Double {
                100 * Double(hits) / Double(observations)
            }
            return [
                String(format: "  learned    top1 %5.1f%%  top3 %5.1f%%",
                       share(learnedTop1), share(learnedTop3)),
                String(format: "  prior      top1 %5.1f%%  top3 %5.1f%%",
                       share(priorTop1), share(priorTop3)),
                String(format: "  most-used  top1 %5.1f%%", share(frequentTop1)),
                "  over \(observations) observations",
            ]
        }
    }

    /// Replays the history in order against the model as it stood *before* each observation.
    public static func evaluate(_ history: History) -> Report {
        var report = Report()
        let ordered = history.observations.filter(\.isUsable)
            .sorted { $0.recorded < $1.recorded }
        guard ordered.count > 1 else { return report }

        var seen = History()
        var counts: [String: Int] = [:]

        for observation in ordered {
            let weights = train(seen, now: observation.recorded)
            let candidates = observation.films.enumerated().map { slot, film in
                (film, weights.score(observation.vector(slot), film: film))
            }.sorted { $0.1 < $1.1 }
            let priorRanked = observation.films.enumerated().map { slot, film in
                (film, prior.score(observation.vector(slot), film: film))
            }.sorted { $0.1 < $1.1 }

            report.observations += 1
            if candidates.first?.0 == observation.chosenFilmID {
                report.learnedTop1 += 1
            }
            if candidates.prefix(3).contains(where: {
                $0.0 == observation.chosenFilmID
            }) { report.learnedTop3 += 1 }
            if priorRanked.first?.0 == observation.chosenFilmID {
                report.priorTop1 += 1
            }
            if priorRanked.prefix(3).contains(where: {
                $0.0 == observation.chosenFilmID
            }) { report.priorTop3 += 1 }
            if let favourite = counts.max(by: {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            })?.key, favourite == observation.chosenFilmID {
                report.frequentTop1 += 1
            }

            counts[observation.chosenFilmID, default: 0] += 1
            seen.record(observation)
        }
        return report
    }

    public static let kVersion = 1

    /// Roughly 2 kB an observation, so under a megabyte at the cap.
    public static let kMaxObservations = 400

    /// Taste drifts, so an observation is worth half as much after a year.
    static let kHalflife: TimeInterval = 365 * 24 * 3600
    static let kKeptSuggestionWeight: Float = 0.25

    /// Effective observations at which the learned weights are trusted half as much as the prior.
    static let kConfidence: Float = 24

    static let kEpochs = 400
    static let kRate: Float = 0.15

    /// The bias starts at nothing and is the term most likely to run away, so it is held harder
    /// than the terms.
    static let kTermRegularisation: Float = 0.02
    static let kBiasRegularisation: Float = 0.05

    static let kNegligible: Float = 1e-4
}
