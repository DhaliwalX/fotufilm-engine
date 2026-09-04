import Foundation

#if canImport(CoreMedia)
import CoreMedia
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(CoreMedia)
public enum VideoDecodeDepth {

    /// Bits per component the codec actually stores.
    public static func bitsPerComponent(
        _ description: CMFormatDescription
    ) -> Int {
        if let bits = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_BitsPerComponent
        ) as? NSNumber {
            return bits.intValue
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch subtype {
        case kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422HQ:
            return 10
        case kCMVideoCodecType_AppleProRes4444,
             kCMVideoCodecType_AppleProRes4444XQ:
            return 12
        default:
            break
        }
        let hev1 = FourCharCode(0x68657631)
        if subtype == kCMVideoCodecType_HEVC || subtype == hev1
            || subtype == kCMVideoCodecType_DolbyVisionHEVC {
            if let atoms = CMFormatDescriptionGetExtension(
                   description,
                   extensionKey:
                       kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
               ) as? [String: Any],
               let record = atoms["hvcC"] as? Data, record.count > 17 {
                return Int(record[record.startIndex + 17] & 0x07) + 8
            }
        }
        return 8
    }

    /// Whether a track stores more than eight bits per component. This is precision only; transfer
    /// tags separately determine whether the represented light is HDR.
    public static func isDeep(_ descriptions: [CMFormatDescription]) -> Bool {
        descriptions.contains { bitsPerComponent($0) > 8 }
    }

    /// Which path a develop takes through the engine.
    public struct Road: Equatable, Sendable {
        /// Decode to full float rather than to 8-bit BGRA.
        public var deepInput: Bool
        /// Run the engine's realtime schedule rather than its reference one:
        /// reduced-precision intermediate storage, tabulated curves, the
        /// table-driven grain draw.
        public var realtimeSchedule: Bool

        /// Public because Swift's synthesized memberwise initializer is internal.
        public init(deepInput: Bool, realtimeSchedule: Bool) {
            self.deepInput = deepInput
            self.realtimeSchedule = realtimeSchedule
        }

        /// CoreVideo pixel format requested by every decoder on this path.
        public var pixelFormat: OSType {
            deepInput ? kCVPixelFormatType_128RGBAFloat : kCVPixelFormatType_32BGRA
        }
    }

    /// Selects decode depth and render schedule from source and delivery properties.
    public static func road(
        hdr: Bool, log: Bool, sourceHDR: Bool = false,
        sourceFormats: [CMFormatDescription]
    ) -> Road {
        let deep = isDeep(sourceFormats) || log || sourceHDR
        return Road(deepInput: deep || hdr, realtimeSchedule: !deep)
    }
}
#endif
