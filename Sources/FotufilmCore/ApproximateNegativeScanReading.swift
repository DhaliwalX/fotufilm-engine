import Foundation
import FotufilmHalide

extension ApproximateNegativeScan {
    /// FOTUFILM_CONFIG_SCAN_READING for a print span handed `scan`'s linear scan RGB, all zero
    /// for one handed densities. The kernels read the scan as `density(of:)` does, and a sample it
    /// cannot place prints black.
    public static func packedReading(_ scan: ApproximateNegativeScan?) -> [Float] {
        var slots = [Float](repeating: 0, count: Int(FOTUFILM_CONFIG_SCAN_READING_COUNT))
        guard let scan else { return slots }
        slots[0] = 1
        for c in 0..<3 {
            slots[1 + c] = scan.border[c]
            slots[4 + c] = scan.baseDensity[c]
            slots[7 + c] = Float(scan.recordChannels[c])
            slots[10 + c] = scan.gains[c]
            slots[13 + c] = scan.minimumSample[c]
            slots[16 + c] = scan.maximumSample[c]
        }
        return slots
    }
}
