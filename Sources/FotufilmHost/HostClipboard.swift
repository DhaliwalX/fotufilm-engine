import Foundation

/// Puts a developed still on the platform's clipboard (`HostPlatform.clipboard`).
protocol HostClipboard {
    /// Copies the still and returns the size copied, which a print frame makes larger.
    func copy(_ still: HostStill) throws -> (width: Int, height: Int)
}
