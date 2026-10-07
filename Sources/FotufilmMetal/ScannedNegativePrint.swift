#if canImport(Metal)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension HalideMetalFilmRenderer {
    /// Prints a scanned negative a band at a time. `readScan` fills rows of linear scan RGBA,
    /// which the kernels read as the film's record densities by the border calibration
    /// (`FotufilmEngine.Options.scanReading`) and print, so neither the densities nor the print
    /// is ever held whole. Samples outside the film's density range, commonly the holder, print
    /// black.
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
        options.scanReading = calibration
        // Exposure and development already happened to the scanned film.
        var film = stock
        film.layeredTransport = nil
        return developStreaming(width: width, height: height, stock: film, options: options,
                                shouldContinue: shouldContinue, readRows: readScan,
                                writeRows: writeRows)
    }
}
#endif
