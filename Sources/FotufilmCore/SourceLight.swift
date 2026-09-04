import Foundation

/// Which kind of light a frame's numbers describe — the engine's input contract, stated instead of
/// implied. Everything upstream of layer exposure keys off this; everything downstream never needs
/// to know.
public enum LightDomain: Equatable, Codable, Sendable {
    /// Linear responses of a specific camera's colour channels, before any rendering. Not a
    /// colorimetric space: two cameras' `cameraLinear` values are not comparable without their
    /// profiles.
    case cameraLinear(profileID: String)
    /// Colorimetric scene-linear RGB in a named space. The compatibility path, and what today's
    /// decode paths produce.
    case sceneLinear(colorSpace: SceneColorSpace)
    /// Coefficients of a spectral reconstruction model, resolved through the named profile.
    case spectralCoefficients(profileID: String)
    /// Exposure already integrated against one film stock's layer sensitivities. Meaningless
    /// without the stock it was integrated for, so the stock travels in the domain.
    case filmLayerExposure(stockID: String)
}

/// The colorimetric spaces `LightDomain.sceneLinear` can name.
public enum SceneColorSpace: String, CaseIterable, Codable, Sendable {
    case displayP3Linear
    case rec2020Linear
    case rec709Linear
}

/// The transfer function a source's code values were written with, named so it can be inverted
/// exactly — never approximated through a display rendering.
public enum SourceTransferFunction: String, CaseIterable, Codable, Sendable {
    case linear
    case sRGB
    case hlg
    case pq
    case appleLog
    case sLog3
    case sLog2
    case fLog
    case fLog2
}

/// The camera behind a frame, as far as the file says.
public struct CameraIdentity: Equatable, Codable, Sendable {
    public var make: String?
    public var model: String?
    /// Key into the camera spectral profile store, when one is known.
    public var spectralProfileID: String?

    public init(make: String? = nil, model: String? = nil,
                spectralProfileID: String? = nil) {
        self.make = make
        self.model = model
        self.spectralProfileID = spectralProfileID
    }
}

/// Capture exposure, as far as the file says. All optional: RAW and log carry some of these, a
/// bare still often none.
public struct ExposureMetadata: Equatable, Codable, Sendable {
    /// Shutter duration in seconds.
    public var time: Float?
    /// f-number (T-stop when the lens states one; `isTStop` says which).
    public var aperture: Float?
    public var isTStop: Bool
    /// ISO or exposure index the capture was rated at.
    public var speed: Float?
    /// Neutral-density filtration ahead of the lens, in stops.
    public var ndStops: Float?

    public init(time: Float? = nil, aperture: Float? = nil, isTStop: Bool = false,
                speed: Float? = nil, ndStops: Float? = nil) {
        self.time = time
        self.aperture = aperture
        self.isTStop = isTStop
        self.speed = speed
        self.ndStops = ndStops
    }
}

/// The rule that pins relative exposure to the numbers: what an 18% reflector decodes to, and what
/// value the engine calls full scale.
public struct ExposureNormalization: Equatable, Codable, Sendable {
    /// The decoded value of an 18% grey card.
    public var midGrey: Float
    /// The decoded value of a 90% diffuse white card — the engine's 1.0.
    public var diffuseWhite: Float

    /// The house rule every current path follows: reflectance units, diffuse white on 1.0 after
    /// the 1/0.9 scale.
    public static let sceneReflectance = ExposureNormalization(
        midGrey: 0.18, diffuseWhite: 0.9)

    public init(midGrey: Float, diffuseWhite: Float) {
        self.midGrey = midGrey
        self.diffuseWhite = diffuseWhite
    }
}

/// Portable source-light metadata used by the engine instead of an implicit linear Rec.2020 input.
/// Platform-specific extraction belongs in the imaging layer.
public struct SourceLight: Equatable, Codable, Sendable {
    public var domain: LightDomain
    public var transferFunction: SourceTransferFunction
    /// The source gamut, when the domain is colorimetric; nil for `cameraLinear`, whose channels
    /// have no primaries.
    public var primaries: CameraGamut.Primaries?
    public var camera: CameraIdentity?
    /// Code-value floor and ceiling, when the source states them (RAW, legal-range video).
    public var blackLevel: Float?
    public var saturationLevel: Float?
    /// The illuminant the file believes the scene was lit by.
    public var asShotIlluminant: WhiteBalance?
    public var exposure: ExposureMetadata?
    public var normalization: ExposureNormalization

    public init(domain: LightDomain,
                transferFunction: SourceTransferFunction,
                primaries: CameraGamut.Primaries? = nil,
                camera: CameraIdentity? = nil,
                blackLevel: Float? = nil,
                saturationLevel: Float? = nil,
                asShotIlluminant: WhiteBalance? = nil,
                exposure: ExposureMetadata? = nil,
                normalization: ExposureNormalization = .sceneReflectance) {
        self.domain = domain
        self.transferFunction = transferFunction
        self.primaries = primaries
        self.camera = camera
        self.blackLevel = blackLevel
        self.saturationLevel = saturationLevel
        self.asShotIlluminant = asShotIlluminant
        self.exposure = exposure
        self.normalization = normalization
    }
}
