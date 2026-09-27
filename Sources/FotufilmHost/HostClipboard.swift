import Foundation

/// Puts a developed still on the platform's clipboard. Each platform supplies one; the host asks
/// `HostExport.clipboard`.
protocol HostClipboard {
    /// Copies the still and returns the size copied, which a print frame makes larger.
    func copy(_ still: HostStill) throws -> (width: Int, height: Int)
}

extension HostExport {
    /// The platform's clipboard, or nil where this build has none.
    static var clipboard: HostClipboard? {
        #if canImport(AppKit)
        return PasteboardClipboard()
        #else
        return nil
        #endif
    }
}
