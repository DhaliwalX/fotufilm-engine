#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Print frames drawn by `PrintFrameRenderer` through Core Graphics, as the Mac app draws them.
struct CoreGraphicsFrameCompositor: HostFrameCompositor {
    func frame(_ pixels: [UInt8], width: Int, height: Int,
               configuration: PrintFrameConfiguration) -> (pixels: [UInt8], width: Int, height: Int)? {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let framed = PrintFrameRenderer.render(image, configuration: configuration)
        else { return nil }
        return Self.flatten(framed, space: space)
    }

    static func flatten(_ image: CGImage, space: CGColorSpace) -> (pixels: [UInt8], width: Int, height: Int)? {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
#endif
