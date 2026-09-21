import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The browser samples this native table in scene-linear light before crop and film.
/// Only lens metadata enters the settings worker, never image pixels.
public struct WebLensRequest: Decodable {
    public var adjustment: LensAdjustment
    public var amount: Float?
    public var profile: LensProfile?
    public var shot: LensShot?
    /// A small TIFF containing only the source's lens opcode and crop tags.
    public var embeddedTIFF: Data?
    public var deliveredSize: [Float]?

    public struct Plan: Encodable {
        public var table: [Float]
        public var measurement: String
        public var profileID: String?
        public var note: String
        public var declined: [String]
        public var identity: Bool
    }

    public func plan() throws -> Plan {
        let values = [adjustment.distortion, adjustment.vignetting,
                      adjustment.redCyan, adjustment.blueYellow]
        guard values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
              (amount ?? 1).isFinite, (0...1).contains(amount ?? 1),
              (embeddedTIFF?.count ?? 0) <= 1024 * 1024 else {
            throw WebLensError.invalidSettings
        }
        if let deliveredSize {
            guard deliveredSize.count == 2, deliveredSize.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 120_000_000 })
            else { throw WebLensError.invalidSettings }
        }
        let dimensions = deliveredSize.map { SIMD2<Float>($0[0], $0[1]) }
        var stages: [LensCorrection] = []
        var measurement = "none", declined: [String] = []
        var note = shot == nil ? "This file didn’t record which lens took it. Use the sliders below."
            : "No profile for \(shot!.lensModel). Use the sliders below."
        if let profile {
            let validated = try WebLensCatalogueRequest.validated(profile)
            stages.append(validated.correction(focalLength: shot?.focalLength,
                                               aperture: shot?.aperture).scaled(by: amount ?? 1))
            measurement = "profile"
            note = profile.model
        } else if let embeddedTIFF, let embedded = DNGOpcodes.read(embeddedTIFF, deliveredSize: dimensions) {
            declined = embedded.declined
            if !embedded.correction.isIdentity {
                stages.append(embedded.correction.scaled(by: amount ?? 1))
                measurement = "embedded"
                note = "Using the correction stored in the file by the camera."
            }
        }
        stages.append(adjustment.correction)
        let stack = LensCorrectionStack(stages)
        let table = stack.resamplingTable()
        guard table.allSatisfy(\.isFinite) else { throw WebLensError.invalidSettings }
        return Plan(table: table, measurement: measurement, profileID: profile?.id,
                    note: ([note] + declined).joined(separator: " "), declined: declined,
                    identity: stack.isIdentity)
    }

    public func prepare() throws -> Data {
        let table = try plan().table
        var data = Data(capacity: table.count * 4)
        for value in table {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Import validation and metadata matching share the native catalogue semantics.
public struct WebLensCatalogueRequest: Decodable {
    public var profiles: [LensProfile]
    public var shot: LensShot?
    public var profileID: String?

    static func validated(_ profile: LensProfile) throws -> LensProfile {
        guard !profile.id.isEmpty, !profile.model.isEmpty,
              profile.cropFactor.isFinite, profile.cropFactor > 0,
              !profile.calibrations.isEmpty,
              profile.calibrations.allSatisfy({ calibration in
                  calibration.focalLength.isFinite && calibration.focalLength > 0
                    && (calibration.aperture == nil ||
                        (calibration.aperture!.isFinite && calibration.aperture! > 0))
              }) else { throw WebLensError.invalidProfile }
        let sorted = LensProfile(id: profile.id, maker: profile.maker, model: profile.model,
            mount: profile.mount, cropFactor: profile.cropFactor,
            calibrations: profile.calibrations, source: profile.source)
        for calibration in sorted.calibrations {
            let correction = LensCorrection(distortion: calibration.distortion,
                vignetting: calibration.vignetting, lateralChroma: calibration.lateralChroma)
            let table = LensCorrectionStack([correction]).resamplingTable()
            guard table.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw WebLensError.invalidProfile
            }
        }
        return sorted
    }

    public func prepare(matching: Bool) throws -> Data {
        let validated = try profiles.map(Self.validated)
        guard Set(validated.map(\.id)).count == validated.count else {
            throw WebLensError.duplicateProfile
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if matching {
            let catalogue = LensCatalogue(profiles: validated)
            let profile = profileID.map { id in validated.first { $0.id == id } }
                ?? shot.flatMap { catalogue.match($0) }
            return try encoder.encode(profile)
        }
        return try encoder.encode(validated)
    }
}

private enum WebLensError: Error, CustomStringConvertible {
    case invalidSettings, invalidProfile, duplicateProfile
    var description: String {
        switch self {
        case .invalidSettings: return "Lens correction values are outside the supported range."
        case .invalidProfile: return "A lens profile has invalid or missing measured coefficients."
        case .duplicateProfile: return "The catalogue contains more than one profile with the same ID."
        }
    }
}

/// One protocol for native-reference checks and the browser's isolated WASI reactor.
public enum WebRenderRequest {
    public static func prepare(_ data: Data) throws -> Data {
        struct Envelope: Decodable { var kind: String? }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.kind {
        case "lens": return try decoder.decode(WebLensRequest.self, from: data).prepare()
        case "lens-plan":
            return try JSONEncoder().encode(decoder.decode(WebLensRequest.self, from: data).plan())
        case "lens-catalogue", "lens-match":
            return try decoder.decode(WebLensCatalogueRequest.self, from: data)
                .prepare(matching: envelope.kind == "lens-match")
        case nil, "film": return try decoder.decode(WebProfileRequest.self, from: data).prepare()
        default: throw InvalidRequest.unknownKind
        }
    }
    private enum InvalidRequest: Error { case unknownKind }
}
