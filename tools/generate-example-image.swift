import AppKit
import Foundation

// A reproducible color/gradient chart. No photography or external assets are used.
let output = CommandLine.arguments[1]
let width = 2048
let height = 1152
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24)!
let colors: [[UInt8]] = [[220, 65, 45], [240, 185, 35], [70, 180, 95],
                        [45, 170, 210], [70, 90, 210], [180, 70, 185]]
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 3
        for channel in 0..<3 {
            let value: UInt8
            if y < height / 2 {
                let color = colors[min(colors.count - 1, x * colors.count / width)][channel]
                value = UInt8(Float(color) * (0.25 + 0.75 * Float(y) / Float(height / 2)))
            } else {
                let gradient = Float(x) / Float(width - 1)
                value = UInt8(255 * (y < height * 3 / 4 ? gradient : pow(gradient, 2.2)))
            }
            bitmap.bitmapData![offset + channel] = value
        }
    }
}
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
