import Foundation
import Security

nonisolated enum Keychain: Sendable {
    static func genericPassword(service: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw UsageProviderError.needsAuth(
                "macOS refused the keychain read; choose Always Allow when asked"
            )
        default:
            throw UsageProviderError.unavailable("keychain read failed: OSStatus \(status)")
        }
    }
}
