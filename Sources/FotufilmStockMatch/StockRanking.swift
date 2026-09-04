import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Picks the film a photograph opens on: develop it on all of them at 160 px and rank by what
/// survived.
public enum StockRanking {

    /// A film to be considered.
    public struct Film: Sendable {
        public let id: String
        public let name: String
        public let stock: FilmStock

        public init(id: String, name: String, stock: FilmStock) {
            self.id = id
            self.name = name
            self.stock = stock
        }
    }

    /// Fill `rgba8` — exactly `width * height * 4` bytes, Display P3, alpha
    /// ignored — and return whether it worked.
    public typealias Develop = (
        _ film: Film,
        _ rgba8: UnsafeMutableBufferPointer<UInt8>,
        _ width: Int, _ height: Int
    ) -> Bool

    /// One film's standing, kept in pieces so `explanation` can say why.
    public struct Candidate: Identifiable, Sendable {
        public let id: String
        public let name: String
        /// Raw and whole, because this is also the training example `StockPreference` records.
        public let features: StockFeatures
        /// Carried alongside so the explanation describes the decision that
        /// was taken, not the one the default weights would have taken.
        public let weights: StockWeights

        public var total: Float { weights.score(features, film: id) }

        public init(id: String, name: String, features: StockFeatures,
                    weights: StockWeights) {
            self.id = id
            self.name = name
            self.features = features
            self.weights = weights
        }

        /// Every term's contribution, in a fixed order, including the film's own learned bias.
        public var terms: [(name: String, value: Float)] {
            var listed = StockFeatures.Term.allCases.map { term in
                (term.name,
                 (term.rawValue < weights.terms.count
                  ? weights.terms[term.rawValue] : 0) * features[term])
            }
            listed.append(("this film itself", weights.bias[id] ?? 0))
            return listed
        }

        /// The largest single reason this film scored where it did.
        public var explanation: String {
            guard let worst = terms.max(by: { abs($0.value) < abs($1.value) }),
                  abs(worst.value) > 0.01
            else { return "nothing this film costs it" }
            return worst.name
        }

        /// Which term separated this film from `other` by the most.
        public func decidingTerm(against other: Candidate) -> String? {
            let mine = terms, theirs = other.terms
            guard mine.count == theirs.count else { return nil }
            var widest: (name: String, gap: Float)?
            for index in mine.indices {
                let gap = abs(mine[index].value - theirs[index].value)
                if gap > (widest?.gap ?? 0) {
                    widest = (mine[index].name, gap)
                }
            }
            guard let widest, widest.gap > 0.005 else { return nil }
            return widest.name
        }
    }

    /// `best` is nil when nothing was eligible — an empty pack, or a colour photograph against a
    /// monochrome-only one — and the caller then leaves the edit's own stock alone.
    public struct Ranking: Sendable {
        public let ordered: [Candidate]
        public var best: Candidate? { ordered.first }

        public init(ordered: [Candidate]) { self.ordered = ordered }

        /// One line for the log: what was chosen, what it beat, by how much.
        public var summary: String {
            guard let best else { return "no eligible film" }
            guard ordered.count > 1 else { return "\(best.name), unopposed" }
            let runnerUp = ordered[1]
            let margin = runnerUp.total - best.total
            let line = String(format: "%@ over %@ by %.2f",
                              best.name, runnerUp.name, margin)
            guard let deciding = best.decidingTerm(against: runnerUp)
            else { return line + " (nothing much between them)" }
            return line + " (\(deciding) decided it)"
        }
    }

    /// The long edge every candidate develops at.
    public static let scoringLongEdge = 160

    /// The scene, measured once and asked of every film.
    public struct SceneReading: Sendable {
        public let description: StockMatch.SceneDescription
        public let width: Int
        public let height: Int
        /// Detector coverage at the scene's own resolution.
        public let subjectCoverage: [Float]?
        let picture: PictureReading
    }

    /// Reads a scene-linear frame: interleaved RGBA floats, Rec.2020 primaries.
    public static func read(
        linearRGBA pixels: UnsafePointer<Float>,
        width: Int, height: Int,
        subjectCoverage: [Float]? = nil
    ) -> SceneReading? {
        guard width > 0, height > 0 else { return nil }

        var tone = ToneBaseMeasurement(frameWidth: width, frameHeight: height,
                                       balance: SIMD3(1, 1, 1),
                                       exposureGain: 1)
        tone.add(linearRGBA: pixels, rows: 0..<height)

        var coverage: [Float]?
        var subjectFraction: Float?
        if let subjectCoverage, subjectCoverage.count == width * height {
            let claimed = subjectCoverage.reduce(0, +) / Float(width * height)
            if claimed > kSubjectFloor, claimed < kSubjectCeiling {
                coverage = subjectCoverage
                subjectFraction = claimed
            }
        }

        let workspace = Workspace(width: width)
        let picture = coverage.withUnsafeBufferPointerOrNil { weights in
            measurePicture(ScenePlane(pixels: pixels),
                           width: width, height: height,
                           subject: weights, workspace: workspace)
        }

        let description = StockMatch.SceneDescription(
            regionStops: tone.regionStops(),
            chromaMedian: picture.chromaMedian,
            chromaHigh: picture.chromaHigh,
            specularFraction: picture.clippedHigh,
            textureEnergy: picture.texture,
            subjectFraction: subjectFraction)

        return SceneReading(description: description, width: width,
                            height: height, subjectCoverage: coverage,
                            picture: picture)
    }

    /// Develops `scene` on every eligible film and ranks them.
    public static func rank(
        scene: SceneReading,
        films: [Film],
        printCorrection: Float = 0.05,
        weights: StockWeights = StockPreference.prior,
        isCancelled: () -> Bool = { false },
        develop: Develop
    ) -> Ranking {
        let width = scene.width, height = scene.height
        let count = width * height
        guard count > 0 else { return Ranking(ordered: []) }

        var bytes = [UInt8](repeating: 0, count: count * 4)
        let workspace = Workspace(width: width)
        var ordered: [Candidate] = []
        ordered.reserveCapacity(films.count)

        scene.subjectCoverage.withUnsafeBufferPointerOrNil { mask in
            for film in films {
                if isCancelled() { break }
                let analytic = StockMatch.analytic(
                    scene: scene.description, stock: film.stock,
                    printCorrection: printCorrection)
                guard analytic.isEligible else { continue }
                var features = analytic.features

                var developed = false
                var reading = PictureReading()
                bytes.withUnsafeMutableBufferPointer { buffer in
                    guard develop(film, buffer, width, height) else { return }
                    developed = true
                    reading = measurePicture(
                        PrintPlane(bytes: buffer.baseAddress!,
                                   table: workspace.decode),
                        width: width, height: height,
                        subject: mask, workspace: workspace)
                }
                guard developed else { continue }

                addLoss(of: reading, against: scene.picture,
                        specularFraction: scene.description.specularFraction,
                        weighted: mask != nil, to: &features)
                ordered.append(Candidate(id: film.id, name: film.name,
                                         features: features, weights: weights))
            }
        }

        ordered.sort { $0.total < $1.total }
        return Ranking(ordered: ordered)
    }

    /// Losses are averaged between the whole frame and the subject-weighted reading, so a film that
    /// keeps the background and wrecks the face cannot hide behind the background's area.
    static func addLoss(of print: PictureReading, against scene: PictureReading,
                        specularFraction: Float, weighted: Bool,
                        to features: inout StockFeatures) {
        func losses(_ printStructure: Float, _ sceneStructure: Float,
                    _ printChroma: Float, _ sceneChroma: Float)
            -> (structure: Float, chroma: Float) {
            let structure = sceneStructure > kStructureFloor
                ? max(0, 1 - printStructure / sceneStructure) : 0
            let chroma = sceneChroma > kChromaFloor
                ? max(0, 1 - printChroma / sceneChroma) : 0
            return (structure, chroma)
        }

        let whole = losses(print.structureWhole, scene.structureWhole,
                           print.chromaWhole, scene.chromaWhole)
        if weighted {
            let focused = losses(print.structureSubject, scene.structureSubject,
                                 print.chromaSubject, scene.chromaSubject)
            features[.structureLoss] = (whole.structure + focused.structure) / 2
            features[.chromaLoss] = (whole.chroma + focused.chroma) / 2
        } else {
            features[.structureLoss] = whole.structure
            features[.chromaLoss] = whole.chroma
        }

        features[.clipping] = max(0, print.clippedHigh - specularFraction)
            + max(0, print.clippedLow - kBlackAllowance)

        func ratio(_ print: Float, _ scene: Float, floor: Float) -> Float {
            scene > floor ? print / scene - 1 : 0
        }
        features[.chromaDelta] = ratio(print.chromaWhole, scene.chromaWhole,
                                       floor: kChromaFloor)
        features[.structureDelta] = ratio(print.structureWhole,
                                          scene.structureWhole,
                                          floor: kStructureFloor)
        features[.contrastDelta] = ratio(print.contrastSpread,
                                         scene.contrastSpread,
                                         floor: kStructureFloor)
        features[.warmthDelta] = print.warmth - scene.warmth
    }

    /// Stops charged for a whole frame of each loss.
    static let kClipWeight: Float = 8
    static let kStructureWeight: Float = 2
    static let kChromaWeight: Float = 1.5

    /// Black allowed before any is charged — film has a toe, and the same
    /// reasoning gives `AutoAdjustment` its half-stop shadow margin.
    static let kBlackAllowance: Float = 0.02

    static let kStructureFloor: Float = 1e-3
    static let kChromaFloor: Float = 1e-3
    static let kSubjectFloor: Float = 0.02
    static let kSubjectCeiling: Float = 0.9
}

extension Optional where Wrapped == [Float] {
    @inline(__always)
    func withUnsafeBufferPointerOrNil<R>(
        _ body: (UnsafePointer<Float>?) -> R
    ) -> R {
        guard let self else { return body(nil) }
        return self.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
