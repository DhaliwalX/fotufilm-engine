import Foundation
@testable import FotufilmCore

enum GoldenStocks {
    // Preserve the established image baselines. Other released profiles are rendered
    // into the review sheet and covered by catalogue-wide CPU/Metal parity tests.
    static let requiredGoldenIDs: Set<String> = [
        "gold200", "trix400", "provia100f",
        "example-negative-400", "example-monochrome-100", "example-reversal-64",
    ]

    struct Entry {
        let id: String
        let stock: FilmStock
        let visibility: GoldenStore.Visibility
    }

    private static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The published catalogue always takes part; a calibrated stock directory joins it when
    /// `FOTUFILM_STOCKS` names one, the same variable the engine's own loader honours.
    static var directories: [(GoldenStore.Visibility, URL)] {
        let published = repositoryRoot.appendingPathComponent("Sources/FotufilmCore/Stocks",
                                                              isDirectory: true)
        var list: [(GoldenStore.Visibility, URL)] = [(.published, published)]
        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_STOCKS"] {
            let calibrated = URL(fileURLWithPath: configured, isDirectory: true)
            if calibrated.standardizedFileURL != published.standardizedFileURL {
                list.append((.calibrated, calibrated))
            }
        }
        return list
    }

    static var all: [Entry] {
        var entries: [Entry] = []
        for (visibility, directory) in directories {
            guard let definitions =
                    try? FilmStockPack.load(directory: directory) else {
                continue
            }
            for (id, definition) in definitions {
                entries.append(Entry(id: id, stock: definition.stock,
                                     visibility: visibility))
            }
        }
        return entries.sorted { $0.id < $1.id }
    }

    static var fileCount: Int {
        directories.reduce(into: 0) { total, pair in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: pair.1, includingPropertiesForKeys: nil)) ?? []
            total += files.filter { $0.pathExtension == "json" }.count
        }
    }
}
