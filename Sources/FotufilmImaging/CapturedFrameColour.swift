#if canImport(CoreVideo)
import CoreVideo
import Foundation

/// Validates captured-frame colour attachments for a requested decoding. The transfer attachment
/// that selects a decoding must be present; descriptive matrix and primaries attachments may be
/// absent but must agree when present.
public enum CapturedFrameColour {
    /// How the samples are to be read.
    public enum Reading: Equatable, Sendable {
        case hlg
        case appleLog
    }

    /// The attachments a frame carries, as strings, so the rule can be stated and tested without
    /// a `CVPixelBuffer` to hang them on.
    public struct Attachments: Equatable, Sendable {
        public var yCbCrMatrix: String?
        public var colorPrimaries: String?
        public var transferFunction: String?
        public var logTransferFunction: String?

        public init(yCbCrMatrix: String? = nil, colorPrimaries: String? = nil,
                    transferFunction: String? = nil,
                    logTransferFunction: String? = nil) {
            self.yCbCrMatrix = yCbCrMatrix
            self.colorPrimaries = colorPrimaries
            self.transferFunction = transferFunction
            self.logTransferFunction = logTransferFunction
        }
    }

    /// Core Video's own spellings, so a caller never restates one.
    public static var rec2020Matrix: String {
        kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
    }
    public static var rec2020Primaries: String {
        kCVImageBufferColorPrimaries_ITU_R_2020 as String
    }
    public static var hlgTransferFunction: String {
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    }
    @available(iOS 17.2, macOS 14.2, *)
    public static var appleLogTransferFunction: String {
        kCVImageBufferLogTransferFunction_AppleLog as String
    }

    public static func isCompatible(_ attachments: Attachments,
                                    with reading: Reading) -> Bool {
        // Describes a frame the format check has already settled.
        guard agrees(attachments.yCbCrMatrix, rec2020Matrix) else { return false }
        switch reading {
        case .hlg:
            // A frame that states a camera log transfer is not an HLG frame, whatever else it says.
            guard attachments.logTransferFunction == nil else { return false }
            return agrees(attachments.colorPrimaries, rec2020Primaries)
                && states(attachments.transferFunction, hlgTransferFunction)
        case .appleLog:
            guard #available(iOS 17.2, macOS 14.2, *) else { return false }
            return states(attachments.logTransferFunction, appleLogTransferFunction)
        }
    }

    /// May be absent; must agree when present.
    private static func agrees(_ actual: String?, _ expected: String) -> Bool {
        actual == nil || actual == expected
    }

    /// Must be present, and must agree.
    private static func states(_ actual: String?, _ expected: String) -> Bool {
        actual == expected
    }
}
#endif
