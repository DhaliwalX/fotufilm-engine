import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A bounded settings request. It never receives image pixels or asks the host for network access.
public struct WebProfileRequest: Decodable {
    public let stock: FilmStockDefinition
    public let width: Int
    public let height: Int
    public let filters: [String]?
    public let filterMetering: String?
    public let format: String?
    public let medium: String?
    public let sceneKelvin: Float?
    public let sceneHighlightStops: Float?
    public let sceneChannelMedians: [Float]?
    public let sceneToneStops: [Float]?
    public let controls: [String: Value]
    /// Set for a scanned negative read as `stock`: the profile reads the framed scan as the
    /// film and prints it (`NegativeScanPrint.Reading`), metered on the frame's highlights. The
    /// scan stays in the rendering worker; the kernels read its pixels.
    public let negative: Negative?

    public struct Negative: Decodable {
        /// Clear film as linear Rec. 2020 scan RGB.
        public let border: [Float]
        /// The framed picture's densest end (`ApproximateNegativeScan.denseEnd`), nil for a frame
        /// too small to read: the reading is then unbalanced.
        public let denseEnd: [Float]?
        /// The edit's `ev`, `temperature` and `tint`, in the web's units: the light controls an
        /// enlarger or a scan carries into the print. The rest finish the print at render time.
        public let light: [String: Double]?

        /// The keys `light` may hold.
        static let lightKeys: Set<String> = ["ev", "temperature", "tint"]
    }

    public enum Value: Decodable {
        case number(Double), flag(Bool), choice(String), curve([Double])
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
            else if let number = try? value.decode(Double.self), number.isFinite {
                self = .number(number)
            } else if let text = try? value.decode(String.self) { self = .choice(text) }
            else { self = .curve(try value.decode([Double].self)) }
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public func prepare() throws -> Data {
        let (stock, options) = try configured()
        return try WebFilmProfile.prepare(stock: stock, options: options, width: width, height: height)
    }

    /// The request's edit as one document: top-level choices become the controls they stand for.
    public var document: EditDocument {
        EditDocument(webControls: controls, format: format, medium: medium, filters: filters,
                     filterMetering: filterMetering, sceneKelvin: sceneKelvin)
    }

    public func configured() throws -> (FilmStock, FotufilmEngine.Options) {
        var stock = try self.stock.validated().stock
        if let unknown = controls.keys.first(where: { EditorControlField(rawValue: $0) == nil }) {
            throw Failure(description: "Unsupported profile control: \(unknown)")
        }
        var document = self.document
        if let light = negative?.light {
            guard light.keys.allSatisfy(Negative.lightKeys.contains),
                  light.values.allSatisfy(\.isFinite) else {
                throw Failure(description: "Invalid negative light.")
            }
            for (key, field, canonical) in WebNativeEdit.sliders {
                if let value = light[key] { document[field] = .number(canonical(value)) }
            }
        }
        var options: FotufilmEngine.Options
        do {
            options = try document.options(for: stock, nativeFormatID: self.stock.nativeFormatID)
        } catch let failure as EditDocument.Failure {
            throw Failure(description: failure.description)
        }
        if let sceneHighlightStops {
            guard sceneHighlightStops.isFinite, (-64...64).contains(sceneHighlightStops) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneHighlightStops = sceneHighlightStops
        }
        if let sceneChannelMedians {
            guard sceneChannelMedians.count == 3,
                  sceneChannelMedians.allSatisfy({ $0.isFinite && (-64...64).contains($0) }) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneChannelMedians = SIMD3(sceneChannelMedians[0], sceneChannelMedians[1],
                                                sceneChannelMedians[2])
        }
        if let sceneToneStops {
            guard sceneToneStops.count == 3,
                  sceneToneStops.allSatisfy({ $0.isFinite && (-64...64).contains($0) }) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneToneStops = SIMD3(sceneToneStops[0], sceneToneStops[1], sceneToneStops[2])
        }
        if let negative {
            stock = try NegativeScanPrint.film(stock)
            let border = negative.border
            guard border.count == 3, border.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw Failure(description: "Pick clear, unexposed film.")
            }
            let balance = try negative.denseEnd.map { dense -> ApproximateNegativeScan.Balance in
                guard dense.count == 3 else { throw Failure(description: "Invalid scene measurement.") }
                return ApproximateNegativeScan.balance(stock: stock,
                                                       denseEnd: SIMD3(dense[0], dense[1], dense[2]))
            } ?? .neutral
            // Exposure and development, which transport belongs to, already happened to the film.
            stock.layeredTransport = nil
            options = try NegativeScanPrint.Reading(
                stock: stock, border: SIMD3(border[0], border[1], border[2]), balance: balance)
                .printing(options, stock: stock)
        }
        return (stock, options)
    }
}
