import Foundation

struct TransportExposureTables: Sendable {
    let core: [SpectralLUT]
    let saturated: [SpectralLUT]

    func table(component: Int, interpolation t: Float) -> SpectralLUT {
        let a = core[component], b = saturated[component]
        if t == 0 { return a }
        if t == 1 { return b }
        return SpectralLUT(dimension: a.dimension,
                           values: zip(a.values, b.values).map { (1-t) * $0 + t * $1 })
    }
}
