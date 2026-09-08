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

    static var directories: [(GoldenStore.Visibility, URL)] {
        [(.published,
          repositoryRoot.appendingPathComponent("Sources/FotufilmCore/Stocks",
                                                isDirectory: true)),
         (.calibrated,
          repositoryRoot.appendingPathComponent("stocks-private",
                                                isDirectory: true))]
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
