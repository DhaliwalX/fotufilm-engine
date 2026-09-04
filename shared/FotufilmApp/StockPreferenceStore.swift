import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmStockMatch)
import FotufilmStockMatch
#endif

@MainActor
final class StockPreferenceStore {

    static let shared = StockPreferenceStore()

    /// What the ranking should score with. `StockPreference.prior` until
    /// there is enough history to move it.
    var weights: StockWeights {
        load()
        return trained
    }

    private var trained: StockWeights = StockPreference.prior
    private var history = StockPreference.History()
    private var loaded = false
    private var writer: Task<Void, Never>?

    var observationCount: Int {
        load()
        return history.observations.count
    }

    var hasLearnedAnything: Bool { observationCount > 0 }

    /// Idempotent, and cheap after the first call.
    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode(
                StockPreference.History.self, from: data),
              stored.isReadable
        else { return }
        history = stored
        retrain()
    }

    private func persist() {
        let snapshot = history
        writer?.cancel()
        writer = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let directory = Self.file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// The film a photograph settled on.
    func record(photoID: String, chosenFilmID: String,
                ranking: StockSuggestion.Ranking?, proposedFilmID: String?) {
        load()
        guard !chosenFilmID.isEmpty else { return }
        guard let ranking, ranking.ordered.count > 1 else {
            let before = history
            history.revise(photoID: photoID, chosenFilmID: chosenFilmID)
            guard history != before else { return }
            retrain()
            persist()
            return
        }
        history.record(StockPreference.Observation(
            photoID: photoID, chosenFilmID: chosenFilmID,
            proposedFilmID: proposedFilmID,
            candidates: ranking.ordered.map { ($0.id, $0.features) }))
        retrain()
        persist()
    }

    /// Back to the hand-set weights, and the file gone.
    func forget() {
        loaded = true
        history = StockPreference.History()
        trained = StockPreference.prior
        writer?.cancel()
        writer = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// How the learned weights are doing against the prior and against
    /// "always the film you use most", replayed in order.
    var report: StockPreference.Report {
        load()
        return StockPreference.evaluate(history)
    }

    private func retrain() {
        trained = StockPreference.train(history)
    }

    /// Beside the shelf but never inside it: this is a model of one person on one device, and
    /// syncing it would carry taste between them.
    private nonisolated static var file: URL {
        EditLibrary.localRoot.deletingLastPathComponent()
            .appendingPathComponent("StockPreference.json")
    }
}
