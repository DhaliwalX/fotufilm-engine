import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if os(iOS)
import AVFoundation
#endif

/// Forwards the engine's Apple Log curve and provides the AVFoundation capability probes. Apple
/// Log 2 shares the curve and every constant here; only its recorded gamut differs.
enum AppleLog {
    static func linear(_ code: Float) -> Float { AppleLogCurve.linear(code) }

    static var diffuseWhite: Float { AppleLogCurve.diffuseWhite }
    static var peakReflectance: Float { AppleLogCurve.peakReflectance }
    static var sceneScale: Float { AppleLogCurve.sceneScale }
    static var headroom: Float { AppleLogCurve.headroom }
    static var metalFunction: String { AppleLogCurve.metalFunction }

#if os(iOS)
    /// Whether this phone's rear camera will hand over *this* log signal — iPhone 15 Pro and later,
    /// and only on some of their formats.
    static let isSupportedByCamera: Bool = {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else { return false }
        return device.formats.contains {
            $0.supportedColorSpaces.contains(.appleLog)
        }
    }()

    /// Whether the rear camera offers Apple Log 2 on any format — iPhone 17 Pro on iOS 26.
    static let isLog2SupportedByCamera: Bool = {
        guard #available(iOS 26.0, *),
              let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back)
        else { return false }
        return device.formats.contains {
            $0.supportedColorSpaces.contains(.appleLog2)
        }
    }()
#endif
}
