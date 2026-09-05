import Foundation
#if canImport(Security)
import Security
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Register container keys and load bundled and imported profiles without network access.
enum StockPacks {
    private static var booted = false
    private static let lock = NSLock()

    /// Posted when the installed packs changed under a running app — a film pack imported, or the
    /// device's own key arriving after launch and making a locally-sealed pack readable. Whoever
    /// is showing a list of films puts it up again.
    static let installedPacksChanged =
        Notification.Name("fotufilm.installedPacksChanged")

    static func bootstrap() {
        lock.lock()
        defer { lock.unlock() }
        guard !booted else { return }
        booted = true

        let keyring = FilmPackKeyring.shared
        if let vault = try? FilmPackKey(bytes: FilmPackKeyMaterial.vaultKey) {
            keyring.register(vault, kind: .vault, id: FilmPackKeyMaterial.vaultKeyID)
        }
        if let community = try? FilmPackKey(bytes: FilmPackKeyMaterial.communityKey) {
            keyring.register(community, kind: .community,
                             id: FilmPackKeyMaterial.communityKeyID)
        }
        CustomStockStore.publish()
        FilmStockPack.reload()

        // The device's own key is asked for after the app is up, never before it. See
        // `unlockLocalPacksSoon`.
        if hasLocalPack() { unlockLocalPacksSoon() }
    }

    private static func unlockLocalPacksSoon() {
        DispatchQueue.global(qos: .utility).async {
            guard ensureLocalKey() else { return }
            refresh()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: installedPacksChanged,
                                                object: nil)
            }
        }
    }

    @discardableResult
    static func ensureLocalKey() -> Bool {
        let keyring = FilmPackKeyring.shared
        if keyring.newest(kind: .local) != nil { return true }
        guard let local = localKey() else { return false }
        keyring.register(local, kind: .local, id: localKeyID)
        return true
    }

    private static func hasLocalPack() -> Bool {
        CustomStockStore.packFiles().contains { url in
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let head = try? FilmPackContainer.peek(data)
            else { return false }
            return head.kind == .local
        }
    }

    /// Re-read the packs after the custom store has changed.
    static func refresh() {
        CustomStockStore.publish()
        FilmStockPack.reload()
    }

    static let localKeyID: UInt16 = 1

    #if canImport(Security)
    #if FOTUFILM_SOURCE_BUILD
    private static let keychainService = "com.muastudio.fotufilm.source.packs"
    #else
    private static let keychainService = "com.muastudio.fotufilm.packs"
    #endif
    private static let keychainAccount = "local-pack-key"

    private static func localKey() -> FilmPackKey? {
        switch readKeychain() {
        case .found(let bytes):
            return try? FilmPackKey(bytes: bytes)
        case .missing:
            let minted = FilmPackKey.random()
            guard writeKeychain(minted.bytes) else { return nil }
            return minted
        case .refused:
            // There is a key there and this run could not have it — the keychain was locked, or
            // the prompt was denied. Minting a replacement would overwrite the one every film the
            // user has ever saved is sealed with, so go without instead: the films stay on disk
            // and come back the next time the key is readable.
            return nil
        }
    }

    private enum StoredKey {
        case found([UInt8])
        case missing
        case refused
    }

    private static func readKeychain() -> StoredKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .found([UInt8](data))
        }
        return status == errSecItemNotFound ? .missing : .refused
    }

    private static func writeKeychain(_ bytes: [UInt8]) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(bytes),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    #else
    private static func localKey() -> FilmPackKey? { nil }
    #endif
}
