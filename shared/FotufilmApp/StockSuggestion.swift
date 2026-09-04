import CoreGraphics
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmStockMatch)
import FotufilmStockMatch
#endif

/// The app's side of choosing a film per photograph: the wiring, and nothing
/// that decides which film wins.
enum StockSuggestion {

    typealias Candidate = StockRanking.Candidate
    typealias Ranking = StockRanking.Ranking

    static let scoringLongEdge = StockRanking.scoringLongEdge

    /// Decode a scoring-sized scene, measure it, develop the pack over it, rank.
    static func choose(
        source: PhotoSource,
        state: EditState,
        subject: SubjectMask.Reading? = nil,
        candidates: [StockPreset] = StockPreset.all,
        weights: StockWeights = StockPreference.prior,
        isCancelled: () -> Bool = { false }
    ) -> Ranking? {
        guard let scene = FilmRender.scene(source: source, state: state,
                                           longEdge: scoringLongEdge)
        else { return nil }
        if isCancelled() { return nil }
        let reading = subject ?? self.subject(in: source)
        if isCancelled() { return nil }
        guard let measured = read(scene, subject: reading) else { return nil }
        if isCancelled() { return nil }
        return rank(scene: scene, state: state, description: measured,
                    candidates: candidates,
                    weights: weights, isCancelled: isCancelled)
    }

    /// Copies the scene's full-precision floats once for the whole ranking.
    static func read(_ scene: FilmRender.Scene,
                     subject: SubjectMask.Reading? = nil)
        -> StockRanking.SceneReading? {
        guard scene.width > 0, scene.height > 0 else { return nil }
        let coverage = subject?.coverage(width: scene.width,
                                         height: scene.height)
        var linear = [Float](repeating: 0,
                             count: scene.width * scene.height * 4)
        scene.withPixels { source in
            linear.withUnsafeMutableBufferPointer { destination in
                FilmRender.expand(source, rows: 0..<scene.height,
                                  width: scene.width, into: destination)
            }
        }
        return linear.withUnsafeBufferPointer { pixels in
            StockRanking.read(linearRGBA: pixels.baseAddress!,
                              width: scene.width, height: scene.height,
                              subjectCoverage: coverage)
        }
    }

    /// Runs the ranking, with `FilmRender` as the develop.
    static func rank(
        scene: FilmRender.Scene,
        state: EditState,
        description: StockRanking.SceneReading,
        candidates: [StockPreset] = StockPreset.all,
        weights: StockWeights = StockPreference.prior,
        isCancelled: () -> Bool = { false }
    ) -> Ranking {
        StockRanking.rank(
            scene: description,
            films: candidates.map {
                StockRanking.Film(id: $0.id, name: $0.name, stock: $0.stock)
            },
            printCorrection: Float(state.printCorrection),
            weights: weights,
            isCancelled: isCancelled
        ) { film, bytes, width, height in
            var develop = state
            develop.stockID = film.id
            guard let developed = FilmRender.develop(scene, state: develop,
                                                     dynamicRange: .sdr)
            else { return false }
            return draw(developed.image.image, into: bytes,
                        width: width, height: height)
        }
    }

    /// A developed print, flattened into the module's byte buffer. `draw` scales if the develop
    /// ever comes back at another size, which keeps the module's fill-exactly-this-many-bytes
    /// promise unbreakable from here.
    static func draw(_ image: CGImage,
                     into bytes: UnsafeMutableBufferPointer<UInt8>,
                     width: Int, height: Int) -> Bool {
        guard let base = bytes.baseAddress,
              bytes.count >= width * height * 4,
              let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width,
                                       height: height))
        return true
    }

    /// Nil is an ordinary answer — an empty sky, a flat wall — and means the
    /// ranking weights the whole frame evenly.
    static func subject(in source: PhotoSource) -> SubjectMask.Reading? {
        guard let proxy = subjectProxy(of: source) else { return nil }
        return SubjectMask.detect(in: proxy)
    }

    /// Split from `subject(in:)` so the benchmark can time the decode apart from the inference.
    static func subjectProxy(of source: PhotoSource) -> CGImage? {
        FilmRender.displayProxy(of: source, longEdge: kSubjectProxyLongEdge)
    }

    private static let kSubjectProxyLongEdge = 720
}
