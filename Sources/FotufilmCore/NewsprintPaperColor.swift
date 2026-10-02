import Foundation

/// An opaque sRGB paper color, stored as #RRGGBB and rendered in display-linear P3.
public struct NewsprintPaperColor: Equatable, Sendable {
    private let value: UInt32

    public init?(hex: String) {
        guard hex.count == 7, hex.first == "#",
              hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.value = value
    }

    public var hex: String { String(format: "#%06x", value) }

    public var linearRGB: SIMD3<Float> {
        let rgb = SIMD3<Float>(Float((value >> 16) & 255), Float((value >> 8) & 255),
                               Float(value & 255)) / 255
        return ColorScience.linearSRGBToDisplayP3(SIMD3(
            ColorScience.srgbToLinear(rgb.x), ColorScience.srgbToLinear(rgb.y),
            ColorScience.srgbToLinear(rgb.z)))
    }
}
