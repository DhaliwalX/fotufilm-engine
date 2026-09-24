#if canImport(CoreGraphics)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The part of `PrintEncoding` that hands pixels to Core Graphics and Core Image. Everything here
/// is a delivery concern — wrapping memory as an image and naming a colour space — rather than
/// image formation, so the portable half stands without it.
extension PrintEncoding {
    /// Writes a developed 16-bit RGB image losslessly, retaining its color-space profile.
    /// Reject an already reduced source rather than labeling an 8-bit image a 16-bit master.
    public static func writeTIFF(_ image: CGImage, to url: URL,
                                 properties: [String: Any] = [:]) -> Bool {
        guard image.bitsPerComponent == 16, image.colorSpace?.model == .rgb,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { return false }
        var carried = properties
        carried[kCGImagePropertyDepth as String] = 16
        var tiff = carried[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression as String] = 5 // Lossless LZW.
        carried[kCGImagePropertyTIFFDictionary as String] = tiff
        CGImageDestinationAddImage(destination, image, carried as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }


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
        guard width > 0, height > 0, width <= Int.max / height / 8 else { return nil }
        let byteCount = width * height * 8
        guard buffer.byteCount >= byteCount else { return nil }
        buffer.flush(byteOffset: 0, byteCount: byteCount)
        let owner = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(
            dataInfo: owner.toOpaque(),
            data: buffer.baseAddress, size: byteCount,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<MappedBuffer>.fromOpaque(info).release()
            }
        ) else {
            owner.release()
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
