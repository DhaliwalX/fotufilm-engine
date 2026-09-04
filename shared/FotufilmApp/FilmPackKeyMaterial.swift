// Public example-pack key. This is not an official Fotufilm pack key.
// Sealing keeps source builds compatible with the shipping container format;
// it provides no confidentiality for these source-readable examples.
enum FilmPackKeyMaterial {
    static let vaultKeyID: UInt16 = 0
    static let vaultKey = [UInt8](repeating: 0, count: 32)
    static let communityKeyID: UInt16 = 0
    static let communityKey: [UInt8] = []
}
