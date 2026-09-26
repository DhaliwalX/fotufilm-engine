#if canImport(Metal)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension HalideMetalFilmRenderer {
    /// Prints a scanned negative a band at a time. `readScan` fills rows of linear scan RGBA;
    /// the border calibration turns each sample into the film's record densities and the print
    /// stage develops them, so neither the densities nor the print is ever held whole.
    /// Samples outside the film's density range, commonly the holder, print black.
    @discardableResult
    public func printScan(
        width: Int, height: Int, stock: FilmStock,
        options: FotufilmEngine.Options, calibration: ApproximateNegativeScan,
        shouldContinue: (() -> Bool)? = nil,
        readScan: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        var options = options
        options.stage = .print
        // Exposure and development already happened to the scanned film.
        var film = stock
        film.layeredTransport = nil
        let base = SIMD3(calibration.baseDensity[0], calibration.baseDensity[1],
                         calibration.baseDensity[2])
        var invalid = [Bool](repeating: false, count: width * height)
        var scratch = [Float]()
        return invalid.withUnsafeMutableBufferPointer { invalid in
            developStreaming(
                width: width, height: height, stock: film, options: options,
                shouldContinue: shouldContinue,
                readRows: { rows, into in
                    readScan(rows, into)
                    let first = rows.lowerBound * width
                    Self.concurrentRows(rows.count) { band in
                        for pixel in band.lowerBound * width..<band.upperBound * width {
                            let i = pixel * 4
                            let sample = SIMD3(into[i], into[i + 1], into[i + 2])
                            let density = calibration.density(of: sample)
                            invalid[first + pixel] = density == nil
                            let d = density ?? base
                            into[i] = d.x
                            into[i + 1] = d.y
                            into[i + 2] = d.z
                            into[i + 3] = 1
                        }
                    }
                },
                writeRows: { rows, from in
                    let first = rows.lowerBound * width, count = rows.count * width
                    guard invalid[first..<(first + count)].contains(true) else {
                        return writeRows(rows, from)
                    }
                    scratch.removeAll(keepingCapacity: true)
                    scratch.append(contentsOf: from)
                    for pixel in 0..<count where invalid[first + pixel] {
                        scratch[pixel * 4] = 0
                        scratch[pixel * 4 + 1] = 0
                        scratch[pixel * 4 + 2] = 0
                    }
                    scratch.withUnsafeBufferPointer { writeRows(rows, $0) }
                })
        }
    }

    /// Runs `body` over bands of `count` rows on the host's worker pool.
    private static func concurrentRows(_ count: Int, _ body: (Range<Int>) -> Void) {
        let band = 64
        let bands = (count + band - 1) / band
        guard bands > 1 else { return body(0..<count) }
        DispatchQueue.concurrentPerform(iterations: bands) { index in
            body(index * band..<min(count, (index + 1) * band))
        }
    }
}
#endif
