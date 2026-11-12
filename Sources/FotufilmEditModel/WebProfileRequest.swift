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
    /// Set for a piece of film larger than the photograph, which the request's size includes: how
    /// far the film reaches beyond the photograph on each side (`UnexposedEdge`). The scene's
    /// measurements are the photograph's own.
    public let unexposedEdge: UnexposedEdge.Margins?

    public struct Negative: Decodable {
        /// Clear film as linear Rec. 2020 scan RGB.
        public let border: [Float]
        /// The framed picture's densest end (`ApproximateNegativeScan.denseEnd`), nil for a frame
        /// too small to read: the reading is then unbalanced. With `roll` it is the frame's own,
        /// before the roll's colour.
        public let denseEnd: [Float]?
        /// The edit's `ev`, `temperature` and `tint`, in the web's units: the light controls an
        /// enlarger or a scan carries into the print. The rest finish the print at render time.
        public let light: [String: Double]?
        /// How far the reading undoes the dyes' crosstalk (`NegativeScanCrosstalk.range`); nil
        /// reads each record from its own channel in the first reading, and separates the dyes
        /// all the way in the current one.
        public let crosstalk: Float?
        /// The light the scan was made under (`NegativeScanCrosstalk.Light`); nil is white light.
        public let scanLight: NegativeScanCrosstalk.Light?
        /// Which reading the edit was made with, what took the scan, what the frame is balanced
        /// on, a neutral picked on it and the roll it belongs to, as the edit keeps them
        /// (`WebNativeEdit.Negative`).
        public let reading: Int?
        public let camera: String?
        public let balance: ApproximateNegativeScan.BalanceMode?
        public let neutral: [Float]?
        public let roll: ApproximateNegativeScan.RollBalance?
        /// What the scan's file says of its camera and decoder, which the current reading's
        /// setup is made of.
        public let source: NegativeScanSource?
        /// The measured channels of the camera `source` names, as one record of the cameras the
        /// desktop app carries (`CameraSpectralProfileStore.register(rawtoaces:)`): the browser
        /// carries none inside the builder, and sends the record of a camera it has.
        public let cameraProfile: String?
        /// The stray light the reading takes off the scan, linear scan RGB like `border`, as
        /// the browser resolved it from the edit's flare and what the frame and the scan show
        /// (`WebNativeEdit.Negative.strayLight`). `border` still carries it; `denseEnd` is net
        /// of it. Nil takes none off, and the first reading never does.
        public let strayLight: [Float]?

        /// The keys `light` may hold.
        static let lightKeys: Set<String> = ["ev", "temperature", "tint"]

        /// The request's reading as an edit keeps it, with what the frame measures.
        struct Measured {
            var edit: WebNativeEdit.Negative
            var border: SIMD3<Float>
            var denseEnd: SIMD3<Float>?
            /// The scan's stray light, none on the first reading.
            var flare: SIMD3<Float> = .zero
        }

        /// Makes `record`'s camera one a reading can resolve.
        static func register(cameraProfile record: String?) {
            if let record { CameraSpectralProfileStore.register(rawtoaces: Data(record.utf8)) }
        }

        func measured() throws -> Measured {
            Self.register(cameraProfile: cameraProfile)
            guard border.count == 3, border.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw Failure(description: "Pick clear, unexposed film.")
            }
            if let crosstalk {
                guard crosstalk.isFinite, NegativeScanCrosstalk.range.contains(crosstalk) else {
                    throw Failure(description: "Invalid crosstalk correction.")
                }
            }
            if let reading, reading < 1 { throw Failure(description: "Invalid negative reading.") }
            if let neutral {
                guard neutral.count == 3, neutral.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    throw Failure(description: "Invalid picked neutral.")
                }
            }
            let dense = try denseEnd.map { dense -> SIMD3<Float> in
                guard dense.count == 3 else { throw Failure(description: "Invalid scene measurement.") }
                return SIMD3(dense[0], dense[1], dense[2])
            }
            let edit = WebNativeEdit.Negative(
                roll: roll, crosstalk: crosstalk, scanLight: scanLight, reading: reading,
                camera: camera, balance: balance, neutral: neutral)
            var flare = SIMD3<Float>.zero
            if let strayLight {
                guard strayLight.count == 3, (0..<3).allSatisfy({
                    strayLight[$0].isFinite && strayLight[$0] >= 0
                        && strayLight[$0] <= ApproximateNegativeScan.flareLimit * border[$0]
                }) else { throw Failure(description: "Invalid stray light.") }
                if edit.readsModel { flare = SIMD3(strayLight[0], strayLight[1], strayLight[2]) }
            }
            return Measured(edit: edit, border: SIMD3(border[0], border[1], border[2]),
                            denseEnd: dense, flare: flare)
        }
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
        if let edge = unexposedEdge {
            guard negative == nil, min(edge.left, edge.right, edge.top, edge.bottom, edge.carrier) >= 0,
                  edge.left + edge.right < width, edge.top + edge.bottom < height else {
                throw Failure(description: "Invalid film beyond the photograph.")
            }
            options.unexposedEdge = UnexposedEdge.Develop(
                margins: edge, sceneHighlightStops: options.sceneHighlightStops,
                sceneChannelMedians: options.sceneChannelMedians,
                sceneToneStops: options.sceneToneStops)
        }
        if let negative {
            stock = try NegativeScanPrint.film(stock)
            let measured = try negative.measured()
            let balance = measured.edit.balance(
                stock: stock, border: measured.border, denseEnd: measured.denseEnd,
                source: negative.source, flare: measured.flare)
            // Exposure and development, which transport belongs to, already happened to the film.
            stock.layeredTransport = nil
            options = try NegativeScanPrint.Reading(
                stock: stock, border: measured.border, balance: balance, flare: measured.flare)
                .printing(options, stock: stock)
        }
        return (stock, options)
    }
}
