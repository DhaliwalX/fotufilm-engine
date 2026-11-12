import Foundation
import FotufilmHalide

extension ApproximateNegativeScan {
    /// FOTUFILM_CONFIG_SCAN_READING and FOTUFILM_CONFIG_SCAN_CROSSTALK, which follows it, for a
    /// print span handed `scan`'s linear scan RGB; all zero for one handed densities. The kernels
    /// read the scan as `density(of:)` does, and a sample it cannot place prints black. The
    /// clear film is net of the scan's stray light, which `packedBalance` carries.
    public static func packedReading(_ scan: ApproximateNegativeScan?) -> [Float] {
        var slots = [Float](repeating: 0, count: Int(FOTUFILM_CONFIG_SCAN_READING_COUNT
                                                    + FOTUFILM_CONFIG_SCAN_CROSSTALK_COUNT))
        guard let scan else { return slots }
        slots[0] = 1
        for c in 0..<3 {
            slots[1 + c] = scan.border[c] - scan.flare[c]
            slots[4 + c] = scan.baseDensity[c]
            slots[7 + c] = Float(scan.recordChannels[c])
            slots[10 + c] = scan.gains[c]
            slots[13 + c] = scan.minimumSample[c]
            slots[16 + c] = scan.maximumSample[c]
        }
        let crosstalk = Int(FOTUFILM_CONFIG_SCAN_CROSSTALK - FOTUFILM_CONFIG_SCAN_READING)
        for record in 0..<3 {
            for channel in 0..<3 { slots[crosstalk + record * 3 + channel] = scan.weights[record][channel] }
        }
        return slots
    }

    /// FOTUFILM_CONFIG_SCAN_FLARE and FOTUFILM_CONFIG_SCAN_BALANCE, which follows it: the stray
    /// light `scan` takes off each sample, and its balance record by record; all zero for a span
    /// handed densities.
    public static func packedBalance(_ scan: ApproximateNegativeScan?) -> [Float] {
        precondition(balanceSamples == Int(FOTUFILM_SCAN_BALANCE_SAMPLES)
                     && balanceRange == 0...Float(FOTUFILM_SCAN_BALANCE_MAX)
                     && FOTUFILM_CONFIG_SCAN_BALANCE
                         == FOTUFILM_CONFIG_SCAN_FLARE + FOTUFILM_CONFIG_SCAN_FLARE_COUNT)
        guard let scan else {
            return [Float](repeating: 0, count: Int(FOTUFILM_CONFIG_SCAN_FLARE_COUNT
                                                    + FOTUFILM_CONFIG_SCAN_BALANCE_COUNT))
        }
        return scan.flare + scan.balance.flatMap { $0 }
    }
}
