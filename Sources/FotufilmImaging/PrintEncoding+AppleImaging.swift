#if canImport(CoreGraphics)
import CoreGraphics
import CoreImage
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The part of `PrintEncoding` that hands pixels to Core Graphics and Core Image. Everything here
/// is a delivery concern — wrapping memory as an image and naming a colour space — rather than
/// image formation, so the portable half stands without it.
extension PrintEncoding {

    /// Wraps a finished 16-bit RGBA buffer as a CGImage without copying it.
    public static func makeImage(
        takingOwnershipOf pixels: UnsafeMutableBufferPointer<UInt16>,
        width: Int, height: Int, colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let base = pixels.baseAddress, width > 0, height > 0,
              pixels.count >= width * height * 4 else {
            pixels.deallocate()
            return nil
        }
        guard let provider = CGDataProvider(
            dataInfo: nil, data: base, size: pixels.count * 2,
            releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }
        ) else {
            pixels.deallocate()
            return nil
        }
        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace,
            bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The same, for a print written into a `MappedBuffer`.
    public static func makeImage(
        takingOwnershipOf buffer: MappedBuffer,
        width: Int, height: Int, colorSpace: CGColorSpace
    ) -> CGImage? {
        let byteCount = width * height * 8
        guard width > 0, height > 0, buffer.byteCount >= byteCount else {
            return nil
        }
        buffer.flush(byteOffset: 0, byteCount: byteCount)
        guard let provider = CGDataProvider(
            dataInfo: Unmanaged.passRetained(buffer).toOpaque(),
            data: buffer.baseAddress, size: byteCount,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<MappedBuffer>.fromOpaque(info).release()
            }
        ) else { return nil }
        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace,
            bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The Core Graphics tag corresponding to an engine output-converter contract.
    public static func colorSpace(for output: FilmOutputColorSpace) -> CGColorSpace? {
        switch output.rawValue {
        case FilmOutputColorSpace.linearDisplayP3.rawValue:
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case FilmOutputColorSpace.displayP3.rawValue:
            return CGColorSpace(name: CGColorSpace.displayP3)
        case FilmOutputColorSpace.linearSRGB.rawValue:
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case FilmOutputColorSpace.sRGB.rawValue:
            return CGColorSpace(name: CGColorSpace.sRGB)
        case FilmOutputColorSpace.rec709.rawValue:
            return CGColorSpace(name: CGColorSpace.itur_709)
        case FilmOutputColorSpace.linearRec2020.rawValue:
            return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        case FilmOutputColorSpace.rec2020HLG.rawValue:
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        default:
            return nil
        }
    }

}
#endif
