import CoreGraphics
import Foundation
import Observation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The open photograph developed on every stock in the pack, for the film column.
@MainActor
@Observable
final class StockPreviewCache {
    private(set) var images: [String: PlatformImage] = [:]

    private var key: EditState?
    private var token: UUID?
    private var task: Task<Void, Never>?

    /// Long edge of a preview.
    private nonisolated static let longEdge = 192

    func refresh(source: PhotoSource?, state: EditState, token: UUID) {
        guard let source else {
            task?.cancel()
            images = [:]
            key = nil
            return
        }
        var wanted = state
        wanted.stockID = ""
        guard wanted != key || token != self.token || images.isEmpty else { return }
        key = wanted
        self.token = token

        task?.cancel()
        let ids = FilmChoice.editorWall.map(\.id)
        let longEdge = Self.longEdge
        task = Task { [weak self] in
            guard let scene = await Task.detached(priority: .utility, operation: {
                FilmRender.scene(source: source, state: wanted, longEdge: longEdge)
            }).value else { return }
            for id in ids {
                if Task.isCancelled { return }
                var stockState = wanted
                stockState.stockID = id
                let developed = await Task.detached(priority: .utility) {
                    FilmRender.develop(scene, state: stockState)?.image.image
                }.value
                guard !Task.isCancelled, let self, let developed else { continue }
                images[id] = PlatformImage.from(developed)
            }
        }
    }
}

/// The same photograph as each gauge would have given it, for the format grid.
@MainActor
@Observable
final class GaugePreviewCache {
    private(set) var images: [String: PlatformImage] = [:]

    private var key: EditState?
    private var token: UUID?
    private var detail: Bool?
    private var task: Task<Void, Never>?

    private nonisolated static let longEdge = 168
    /// A quarter of the frame each way, taken from the middle.
    private nonisolated static let detailRect = CGRect(x: 0.375, y: 0.375,
                                                       width: 0.25, height: 0.25)

    func refresh(source: PhotoSource?, state: EditState, token: UUID,
                 detail: Bool) {
        guard let source else {
            task?.cancel()
            images = [:]
            key = nil
            return
        }
        var wanted = state
        wanted.followStockGauge()
        if detail { wanted.crop = Self.detailRect }
        guard wanted != key || token != self.token || detail != self.detail
                || images.isEmpty else { return }
        key = wanted
        self.token = token
        self.detail = detail

        task?.cancel()
        let ids = FilmFormat.presets.map(\.id)
        let longEdge = Self.longEdge
        task = Task { [weak self] in
            guard let scene = await Task.detached(priority: .utility, operation: {
                FilmRender.scene(source: source, state: wanted, longEdge: longEdge)
            }).value else { return }
            for id in ids {
                if Task.isCancelled { return }
                var gaugeState = wanted
                gaugeState.selectFormat(id)
                let developed = await Task.detached(priority: .utility) {
                    FilmRender.develop(scene, state: gaugeState)?.image.image
                }.value
                guard !Task.isCancelled, let self, let developed else { continue }
                images[id] = PlatformImage.from(developed)
            }
        }
    }
}
