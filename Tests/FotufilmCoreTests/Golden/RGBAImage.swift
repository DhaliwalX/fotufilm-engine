import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmCore
@testable import FotufilmImaging

struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 255, count: width * height * 4)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static let colorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

    init(print buffer: ImageBuffer) {
        self.width = buffer.width
        self.height = buffer.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let shouldered =
                    ColorScience.displayShoulder(buffer.planes[channel][i])
                let encoded = PrintEncoding.encode(shouldered)
                bytes[i * 4 + channel] =
                    UInt8(max(0, min(255, (encoded * 255).rounded())))
            }
        }
        self.pixels = bytes
    }

    var sceneLinear: ImageBuffer {
        var buffer = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                buffer.planes[channel][i] =
                    ColorScience.srgbToLinear(Float(pixels[i * 4 + channel]) / 255)
            }
        }
        return buffer
    }

    func pngData() throws -> Data {
        var bytes = pixels
        // Keep the bitmap storage alive until ImageIO has finished encoding it.
        return try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Self.colorSpace, bitmapInfo: Self.bitmapInfo.rawValue),
                  let image = context.makeImage() else {
                throw GoldenError.cannotEncode
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil) else {
                throw GoldenError.cannotEncode
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw GoldenError.cannotEncode
            }
            return data as Data
        }
    }

    static func read(_ url: URL) throws -> RGBAImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GoldenError.cannotRead(url)
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
                throw GoldenError.cannotRead(url)
            }
            context.draw(image,
                         in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return RGBAImage(width: width, height: height, pixels: bytes)
    }

    static func amplifiedDifference(_ a: RGBAImage, _ b: RGBAImage,
                                    gain: Int = 32) -> RGBAImage {
        var out = RGBAImage(width: a.width, height: a.height)
        for i in 0..<(a.width * a.height) {
            for channel in 0..<3 {
                let delta = abs(Int(a.pixels[i * 4 + channel])
                                - Int(b.pixels[i * 4 + channel]))
                out.pixels[i * 4 + channel] = UInt8(min(255, delta * gain))
            }
        }
        return out
    }

}

enum GoldenError: Error, CustomStringConvertible {
    case cannotEncode
    case cannotRead(URL)

    var description: String {
        switch self {
        case .cannotEncode:
            return "could not encode a PNG"
        case .cannotRead(let url):
            return "could not read an image at \(url.path)"
        }
    }
}
