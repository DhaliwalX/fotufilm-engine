import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// One picture measured — a scene going in, or a print coming out.
struct PictureReading {
    var clippedHigh: Float = 0
    var clippedLow: Float = 0

    /// Mean absolute adjacent-pixel step in log2 luminance, stops per pixel.
    var texture: Float = 0

    /// `texture / contrastSpread`.
    var structureWhole: Float = 0
    var structureSubject: Float = 0

    /// Mean `(max - min) / max`.
    var chromaWhole: Float = 0
    var chromaSubject: Float = 0

    /// Mean `(red - blue) / (red + blue)` over lit pixels.
    var warmth: Float = 0

    var chromaMedian: Float = 0
    var chromaHigh: Float = 0

    /// p1–p99 spread of log2 luminance.
    var contrastSpread: Float = 0
}

/// Both conformers are internal and inlined, so `measurePicture` specialises
/// into two concrete loops with no dispatch.
protocol PixelPlane {
    func sample(at index: Int) -> PixelSample
}

struct PixelSample {
    var red: Float
    var green: Float
    var blue: Float
    var luminance: Float
    var pinnedHigh: Bool
    var pinnedLow: Bool
}

/// Scene-linear interleaved RGBA floats in the working space, Rec.2020 primaries.
struct ScenePlane: PixelPlane {
    let pixels: UnsafePointer<Float>
    /// Stored, not read per pixel: a `static let` in another module is a lazy global, so reading it
    /// in the loop is an atomic load a million times.
    let luma: (Float, Float, Float) = ColorScience.luminanceWeights

    @inline(__always)
    func sample(at index: Int) -> PixelSample {
        let base = index * 4
        let red = max(pixels[base], 0)
        let green = max(pixels[base + 1], 0)
        let blue = max(pixels[base + 2], 0)
        let luminance = luma.0 * red + luma.1 * green + luma.2 * blue
        return PixelSample(red: red, green: green, blue: blue,
                           luminance: luminance,
                           pinnedHigh: luminance >= 1, pinnedLow: false)
    }
}

/// A developed print: interleaved RGBA bytes, Display P3 with the sRGB
/// transfer function, linearised through a 256-entry table.
struct PrintPlane: PixelPlane {
    let bytes: UnsafePointer<UInt8>
    let table: UnsafePointer<Float>
    /// A developed print is Display P3, so its luminance reads with the P3 weights.
    let luma: (Float, Float, Float) = ColorScience.displayP3LuminanceWeights

    @inline(__always)
    func sample(at index: Int) -> PixelSample {
        let base = index * 4
        let r8 = bytes[base], g8 = bytes[base + 1], b8 = bytes[base + 2]
        let red = table[Int(r8)]
        let green = table[Int(g8)]
        let blue = table[Int(b8)]
        let luminance = luma.0 * red + luma.1 * green + luma.2 * blue
        let peak = max(r8, max(g8, b8))
        return PixelSample(red: red, green: green, blue: blue,
                           luminance: luminance,
                           pinnedHigh: peak >= kClipHigh,
                           pinnedLow: peak <= kClipLow)
    }
}

/// Scratch for the measuring loop, allocated once per ranking.
final class Workspace {
    let width: Int
    let previousLuminance: UnsafeMutablePointer<Float>
    let previousWeight: UnsafeMutablePointer<Float>
    let spread: UnsafeMutablePointer<Int32>
    let chroma: UnsafeMutablePointer<Int32>
    let decode: UnsafeMutablePointer<Float>

    init(width: Int) {
        let columns = max(width, 1)
        self.width = columns
        previousLuminance = .allocate(capacity: columns)
        previousWeight = .allocate(capacity: columns)
        spread = .allocate(capacity: kSpreadBins)
        chroma = .allocate(capacity: kChromaBins)
        decode = .allocate(capacity: 256)
        previousLuminance.initialize(repeating: 0, count: columns)
        previousWeight.initialize(repeating: 0, count: columns)
        spread.initialize(repeating: 0, count: kSpreadBins)
        chroma.initialize(repeating: 0, count: kChromaBins)
        for code in 0..<256 {
            let v = Float(code) / 255
            decode[code] = v <= 0.04045 ? v / 12.92
                : pow((v + 0.055) / 1.055, 2.4)
        }
    }

    deinit {
        previousLuminance.deallocate()
        previousWeight.deallocate()
        spread.deallocate()
        chroma.deallocate()
        decode.deallocate()
    }

    func reset() {
        spread.update(repeating: 0, count: kSpreadBins)
        chroma.update(repeating: 0, count: kChromaBins)
    }
}

@inline(__always)
func measurePicture<Plane: PixelPlane>(
    _ plane: Plane, width: Int, height: Int,
    subject: UnsafePointer<Float>?,
    workspace: Workspace
) -> PictureReading {
    guard width > 0, height > 0, workspace.width >= width else {
        return PictureReading()
    }
    workspace.reset()

    let aboveL = workspace.previousLuminance
    let aboveW = workspace.previousWeight
    let spread = workspace.spread
    let chromaBins = workspace.chroma
    let hasSubject = subject != nil

    var high = 0, low = 0
    var chromaSum = 0.0
    var chromaSubjectSum = 0.0, chromaSubjectTotal = 0.0
    var gradientSum = 0.0, gradientTotal = 0.0
    var gradientSubjectSum = 0.0, gradientSubjectTotal = 0.0
    var gatedChroma = 0
    var warmthSum = 0.0

    let scale = Float(kSpreadBins) / (kSpreadCeiling - kSpreadFloor)

    for y in 0..<height {
        let row = y * width
        var leftLuminance: Float = 0
        var leftWeight: Float = 0
        for x in 0..<width {
            let index = row + x
            let pixel = plane.sample(at: index)
            if pixel.pinnedHigh { high += 1 }
            if pixel.pinnedLow { low += 1 }

            let logLuminance = log2(max(pixel.luminance, kLuminanceFloor))
            let bin = Int((logLuminance - kSpreadFloor) * scale)
            spread[min(kSpreadBins - 1, max(0, bin))] += 1

            let peak = max(pixel.red, max(pixel.green, pixel.blue))
            let dip = min(pixel.red, min(pixel.green, pixel.blue))
            let saturation = peak > 0 ? (peak - dip) / peak : 0
            chromaSum += Double(saturation)
            if pixel.luminance > kChromaLuminanceFloor {
                let slot = min(kChromaBins - 1,
                               max(0, Int(saturation * Float(kChromaBins))))
                chromaBins[slot] += 1
                gatedChroma += 1
                let warm = pixel.red + pixel.blue
                if warm > 0 {
                    warmthSum += Double((pixel.red - pixel.blue) / warm)
                }
            }

            let weight = hasSubject ? subject![index] : 1
            if hasSubject {
                chromaSubjectSum += Double(saturation) * Double(weight)
                chromaSubjectTotal += Double(weight)
            }

            if x > 0 {
                let step = Double(abs(leftLuminance - logLuminance))
                gradientSum += step
                gradientTotal += 1
                if hasSubject, leftWeight > 0 {
                    gradientSubjectSum += step * Double(leftWeight)
                    gradientSubjectTotal += Double(leftWeight)
                }
            }
            if y > 0 {
                let step = Double(abs(aboveL[x] - logLuminance))
                gradientSum += step
                gradientTotal += 1
                let above = aboveW[x]
                if hasSubject, above > 0 {
                    gradientSubjectSum += step * Double(above)
                    gradientSubjectTotal += Double(above)
                }
            }

            leftLuminance = logLuminance
            leftWeight = weight
            aboveL[x] = logLuminance
            aboveW[x] = weight
        }
    }

    let count = width * height
    var reading = PictureReading()
    reading.clippedHigh = Float(high) / Float(count)
    reading.clippedLow = Float(low) / Float(count)
    reading.chromaWhole = Float(chromaSum / Double(count))
    reading.chromaSubject = chromaSubjectTotal > 0
        ? Float(chromaSubjectSum / chromaSubjectTotal) : reading.chromaWhole
    reading.texture = gradientTotal > 0
        ? Float(gradientSum / gradientTotal) : 0
    reading.warmth = gatedChroma > 0
        ? Float(warmthSum / Double(gatedChroma)) : 0
    reading.chromaMedian = chromaPercentile(chromaBins, samples: gatedChroma,
                                            0.5)
    reading.chromaHigh = chromaPercentile(chromaBins, samples: gatedChroma,
                                          0.95)

    reading.contrastSpread = spreadStops(spread, samples: count, scale: scale)
    if reading.contrastSpread > kSpreadGuard {
        reading.structureWhole = reading.texture / reading.contrastSpread
        let subjectTexture = gradientSubjectTotal > 0
            ? Float(gradientSubjectSum / gradientSubjectTotal)
            : reading.texture
        reading.structureSubject = subjectTexture / reading.contrastSpread
    }
    return reading
}

/// The p1–p99 spread.
func spreadStops(_ histogram: UnsafePointer<Int32>,
                 samples: Int, scale: Float) -> Float {
    guard samples > 1 else { return 0 }

    func percentile(_ q: Float) -> Float {
        let target = q * Float(samples - 1)
        var seen = 0
        for bin in 0..<kSpreadBins {
            let here = Int(histogram[bin])
            if here == 0 { continue }
            if Float(seen + here) > target {
                let within = (target - Float(seen)) / Float(here)
                return kSpreadFloor + (Float(bin) + within) / scale
            }
            seen += here
        }
        return kSpreadCeiling
    }
    return max(0, percentile(0.99) - percentile(0.01))
}

func chromaPercentile(_ histogram: UnsafePointer<Int32>,
                      samples: Int, _ q: Float) -> Float {
    guard samples > 0 else { return 0 }
    let target = Int(q * Float(samples))
    var seen = 0
    for bin in 0..<kChromaBins {
        seen += Int(histogram[bin])
        if seen >= target { return (Float(bin) + 0.5) / Float(kChromaBins) }
    }
    return 1
}

let kLuminanceFloor: Float = 1e-5
let kChromaLuminanceFloor: Float = 0.004

let kClipHigh: UInt8 = 254
let kClipLow: UInt8 = 1

let kChromaBins = 64

/// The floor sits just under `log2(kLuminanceFloor)` so the clamp lands inside the first bin; the
/// ceiling is nine stops over mid-grey.
let kSpreadFloor: Float = -17
let kSpreadCeiling: Float = 9
let kSpreadBins = 2048

let kSpreadGuard: Float = 1e-3
