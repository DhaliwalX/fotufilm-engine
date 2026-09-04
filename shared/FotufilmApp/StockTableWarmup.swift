import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// Builds the spectral LUTs every stock develops through, ahead of anything asking for one.
enum StockTableWarmup {
    private static var started = false

    /// Idempotent, and safe to call from anywhere: the second caller finds the work already
    /// running, and `SpectralRuntime` is its own lock besides.
    @MainActor static func begin() {
        guard !started else { return }
        started = true

        let paper = PrintPaper.editorDefault
        var seen = Set<UInt64>()
        let stocks = StockPreset.all.map(\.stock).filter {
            seen.insert(SpectralRuntime.cacheIdentifier(for: $0,
                                                        paper: paper)).inserted
        }
        guard !stocks.isEmpty else { return }

        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for stock in stocks {
                    group.addTask { _ = SpectralRuntime.tables(for: stock,
                                                               paper: paper) }
                }
            }
            compileSchedules()
        }
    }

    private static func compileSchedules() {
        guard let engine = HalideMetalFilmRenderer.shared else { return }
        let options = EditState().options
        var seen = Set<Int32>()
        for preset in StockPreset.all {
            let mask = FilmEngineInvocation(
                stock: preset.stock, options: options,
                width: previewWidth, height: previewHeight).featureMask
            guard seen.insert(mask).inserted else { continue }
            engine.prepare(stock: preset.stock, options: options,
                           frameWidth: previewWidth, frameHeight: previewHeight)
        }
    }

    private static let previewWidth = 192
    private static let previewHeight = 128
}
