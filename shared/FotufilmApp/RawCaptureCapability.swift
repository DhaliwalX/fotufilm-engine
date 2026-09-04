import Foundation

/// Caches whether any camera on this device supports Apple ProRAW.
/// `AVCapturePhotoOutput` reports support only after a camera is attached to the session.
enum RawCaptureCapability {
    private static let key = "fotufilm.proraw-supported"

    /// Nil until the camera has configured a lens at least once.
    nonisolated static var known: Bool? {
        UserDefaults.standard.object(forKey: key) as? Bool
    }

    nonisolated static func remember(_ supported: Bool) {
        // Once any camera reports ProRAW support, retain true for the device.
        if supported {
            UserDefaults.standard.set(true, forKey: key)
        } else if known == nil {
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    /// Whether a page selling the feature should mention it. Unknown counts as
    /// worth mentioning — the alternative is hiding a feature most phones have
    /// from everyone who has not opened the camera yet — and the copy beside it
    /// is written to stay true on a phone that turns out not to have it.
    nonisolated static var worthOffering: Bool { known != false }
}
