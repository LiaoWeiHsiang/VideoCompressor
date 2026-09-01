import Foundation
import Security

/// Holds the Immich server address and API key.
///
/// The key goes in the Keychain, never in `UserDefaults` or the queue file: those are
/// plain files inside the app container, readable from a device backup. The server address
/// is not a secret and lives in `UserDefaults` so it survives a Keychain reset.
enum ImmichCredentialStore {

    private static let service = "com.weihsiangliao.VideoCompressor.immich"
    private static let account = "apiKey"
    private static let serverKey = "immich.serverURL"

    // MARK: - Server address

    static var serverURLString: String {
        get { UserDefaults.standard.string(forKey: serverKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverKey) }
    }

    // MARK: - API key

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(base as CFDictionary)

            guard let newValue, !newValue.isEmpty else { return }
            var insert = base
            insert[kSecValueData as String] = Data(newValue.utf8)
            // The key is only needed while the app is running in the foreground or
            // uploading, so it never has to be readable on a locked device — and
            // ThisDeviceOnly keeps it out of backups that move to another phone.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Complete credentials, or nil when either half is missing.
    static var credentials: ImmichClient.Credentials? {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil,
              let key = apiKey
        else { return nil }
        return ImmichClient.Credentials(serverURL: url, apiKey: key)
    }

    static var isConfigured: Bool { credentials != nil }

    static func clear() {
        apiKey = nil
        serverURLString = ""
    }
}
