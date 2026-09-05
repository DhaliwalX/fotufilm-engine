// Public container keys provide format compatibility, not confidentiality or
// purchase verification. Pack downloads are authorized by the website.
enum FilmPackKeyMaterial {
    static let vaultKeyID: UInt16 = 0
    static let vaultKey = [UInt8](repeating: 0, count: 32)
    static let communityKeyID: UInt16 = 0
    static let communityKey = [UInt8](repeating: 0, count: 32)
}
