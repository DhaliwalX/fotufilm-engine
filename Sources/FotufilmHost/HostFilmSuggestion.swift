import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmStockMatch)
import FotufilmStockMatch
#endif

/// What the host has learned of one person's film choices, as the Mac app's
/// `StockPreferenceStore` keeps it: the history of photographs and the films they settled on,
/// the weights trained from it, and the last ranking of each open photograph, which is what a
/// choice is recorded against.
final class HostFilmPreferences {
    private let file: URL?
    private let lock = NSLock()
    private var history = StockPreference.History()
    private var trained = StockPreference.prior
    private var loaded = false
    private var rankings: [String: StockRanking.Ranking] = [:]

    /// `file` nil keeps everything in memory.
    init(file: URL?) { self.file = file }

    /// Beside the host's other per-user state, never synced: a model of one person on one device.
    static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Fotufilm Desktop/StockPreference.json")
    }

    var weights: StockWeights {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return trained
    }

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return history.observations.count
    }

    /// Keeps a photograph's ranking until its choice is recorded.
    func remember(_ ranking: StockRanking.Ranking, for photoID: String) {
        lock.lock()
        rankings[photoID] = ranking
        lock.unlock()
    }

    /// The film a photograph settled on, against its ranking when it had one.
    func record(photoID: String, chosenFilmID: String) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        guard !chosenFilmID.isEmpty else { return }
        let before = history
        if let ranking = rankings[photoID], ranking.ordered.count > 1 {
            history.record(StockPreference.Observation(
                photoID: photoID, chosenFilmID: chosenFilmID,
                proposedFilmID: ranking.best?.id,
                candidates: ranking.ordered.map { ($0.id, $0.features) }))
        } else {
            history.revise(photoID: photoID, chosenFilmID: chosenFilmID)
        }
        guard history != before else { return }
        trained = StockPreference.train(history)
        persistLocked()
    }

    /// Back to the hand-set weights, and the file gone.
    func forget() {
        lock.lock()
        defer { lock.unlock() }
        loaded = true
        history = StockPreference.History()
        trained = StockPreference.prior
        rankings = [:]
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(StockPreference.History.self, from: data),
              stored.isReadable else { return }
        history = stored
        trained = StockPreference.train(history)
    }

    private func persistLocked() {
        guard let file, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension HostService {
    /// Ranks every installed film for a photograph as the Mac app's Choose Film Per Photo does:
    /// the framed scene at the scoring size, its subjects when the platform finds them, and each
    /// film developed over it, weighted by what this person has chosen before.
    func suggestFilm(_ parameters: [String: Any]) throws -> [String: Any] {
        var body = parameters
        body["viewport"] = nil
        body["maxEdge"] = StockRanking.scoringLongEdge
        let prepared = try prepare(JSONSerialization.data(withJSONObject: body))
        let (width, height) = prepared.sizes.output
        let scene = try framedScene(prepared)
        let coverage = subjectCoverage(parameters, width: width, height: height)
        guard let reading = scene.withUnsafeBufferPointer({
            StockRanking.read(linearRGBA: $0.baseAddress!, width: width, height: height,
                              subjectCoverage: coverage)
        }) else { throw HostEngine.Failure(description: "The photograph could not be read.") }

        let params = (parameters["edit"] as? [String: Any])?["params"] ?? [String: Any]()
        // Every installed film, or the ones the page names.
        let ids = (parameters["films"] as? [String]).map { Set($0) }
        let films = engine.stockIDs.filter { ids?.contains($0) ?? true }.compactMap { id in
            engine.stock(id).map { StockRanking.Film(id: id, name: $0.name, stock: $0) }
        }
        prebuildTables(films, params: params, contentHeadroom: prepared.image.contentHeadroom,
                       width: StockRanking.scoringLongEdge, height: StockRanking.scoringLongEdge)
        let ranking = StockRanking.rank(scene: reading, films: films,
                                        weights: filmPreferences.weights) { film, bytes, w, h in
            // Each film at its own defaults, with the photograph's light and colour settings.
            guard let request = try? JSONSerialization.data(withJSONObject: [
                    "edit": ["stock": film.id, "params": params],
                    "profileRequest": ["controls": [String: Any]()],
                  ]),
                  let edit = try? JSONDecoder().decode(WebNativeEdit.self, from: request)
            else { return false }
            return (try? engine.develop(scene, width: w, height: h,
                                        contentHeadroom: prepared.image.contentHeadroom,
                                        edit: edit,
                                        into: .init(maxEdge: 0, format: .rgba8DisplayP3,
                                                    pixels: UnsafeMutableRawPointer(bytes.baseAddress!),
                                                    rowBytes: w * 4, capacity: bytes.count))) != nil
        }
        if let photoID = parameters["photoID"] as? String {
            filmPreferences.remember(ranking, for: photoID)
        }
        var answer: [String: Any] = [
            "ordered": ranking.ordered.map { ["id": $0.id, "name": $0.name, "score": $0.total] },
            "summary": ranking.summary,
        ]
        if let best = ranking.best { answer["best"] = best.id }
        return answer
    }

    /// Builds every film's tables under this photograph's light at once. The warm-up built them
    /// under the default light; a photograph's own light is a table per film, which one core
    /// would build one film after another.
    private func prebuildTables(_ films: [StockRanking.Film], params: Any, contentHeadroom: Float,
                                width: Int, height: Int) {
        DispatchQueue.concurrentPerform(iterations: films.count) { index in
            let film = films[index]
            guard let request = try? JSONSerialization.data(withJSONObject: [
                    "edit": ["stock": film.id, "params": params],
                    "profileRequest": ["controls": [String: Any]()],
                  ]),
                  let edit = try? JSONDecoder().decode(WebNativeEdit.self, from: request),
                  let options = try? engine.options(edit, stock: film.stock,
                                                    contentHeadroom: contentHeadroom)
            else { return }
            _ = try? FilmEngineInvocation(validating: film.stock, options: options,
                                          width: width, height: height)
        }
    }

    /// Where the subjects stand, at the scoring size: the platform's detector reads a larger copy
    /// of the framed picture, as the Mac app reads a 720-pixel proxy.
    private func subjectCoverage(_ parameters: [String: Any], width: Int, height: Int) -> [Float]? {
        guard HostPlatform.current.subjects != nil else { return nil }
        var body = parameters
        body["viewport"] = nil
        body["maxEdge"] = 720
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let prepared = try? prepare(data),
              let scene = try? framedScene(prepared),
              let subject = subjects(scene, width: prepared.sizes.output.0,
                                     height: prepared.sizes.output.1, image: prepared.image)
        else { return nil }
        return subject.weights(at: nil, width: width, height: height, softness: 0)
    }
}
