import Foundation
@testable import FotufilmCore

enum CatalogueStocks {
    struct Entry {
        let id: String
        let stock: FilmStock
    }

    private static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The published catalogue always takes part; another stock directory joins it when
    /// `FOTUFILM_STOCKS` names one, the same variable the engine's own loader honours.
    static var directories: [URL] {
        let published = repositoryRoot.appendingPathComponent("Sources/FotufilmCore/Stocks",
                                                              isDirectory: true)
        var list = [published]
        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_STOCKS"] {
            let calibrated = URL(fileURLWithPath: configured, isDirectory: true)
            if calibrated.standardizedFileURL != published.standardizedFileURL {
                list.append(calibrated)
            }
        }
        return list
    }

    static var all: [Entry] {
        var entries: [Entry] = []
        for directory in directories {
            guard let definitions =
                    try? FilmStockPack.load(directory: directory) else {
                continue
            }
            for (id, definition) in definitions {
                entries.append(Entry(id: id, stock: definition.stock))
            }
        }
        return entries.sorted { $0.id < $1.id }
    }
}
