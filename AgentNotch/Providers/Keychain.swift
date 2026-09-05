import Foundation
import Security

nonisolated enum Keychain: Sendable {
    private static let gate = NSLock()

    static func data(
        service: String,
        account: String? = nil,
        dataProtection: Bool = true
    ) throws -> Data? {
        gate.lock()
        defer { gate.unlock() }
        if dataProtection {
            if let data = try copyMatching(
                service: service, account: account, dataProtection: true)
            {
                return data
            }
            guard
                let data = try copyMatching(
                    service: service, account: account, dataProtection: false)
            else {
                return nil
            }
            if let account {
                _ = addOrUpdateDataProtection(data, service: service, account: account)
            }
            return data
        }
        return try copyMatching(service: service, account: account, dataProtection: false)
    }

    static func set(_ data: Data, service: String, account: String) throws {
        gate.lock()
        defer { gate.unlock() }
        if addOrUpdateDataProtection(data, service: service, account: account) {
            return
        }
        try addOrUpdateFileBased(data, service: service, account: account)
    }

    static func delete(service: String, account: String) {
        gate.lock()
        defer { gate.unlock() }
        SecItemDelete(query(service: service, account: account, dataProtection: true) as CFDictionary)
        var fileBased = query(service: service, account: account, dataProtection: false)
        fileBased[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        let quiet = SecItemDelete(fileBased as CFDictionary)
        if quiet != errSecSuccess && quiet != errSecItemNotFound {
            SecItemDelete(
                query(service: service, account: account, dataProtection: false) as CFDictionary)
        }
    }

    private static func addOrUpdateDataProtection(
        _ data: Data, service: String, account: String
    ) -> Bool {
        let base = query(service: service, account: account, dataProtection: true)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func addOrUpdateFileBased(
        _ data: Data, service: String, account: String
    ) throws {
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Agent Notch Claude" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw UsageProviderError.unavailable("keychain access failed: OSStatus \(accessStatus)")
        }
        let base = query(service: service, account: account, dataProtection: false)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccess: access,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw UsageProviderError.unavailable("keychain update failed: OSStatus \(updateStatus)")
        }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccess] = access
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw UsageProviderError.unavailable("keychain write failed: OSStatus \(addStatus)")
        }
    }

    private static func copyMatching(
        service: String,
        account: String?,
        dataProtection: Bool
    ) throws -> Data? {
        var matching = query(service: service, account: account, dataProtection: dataProtection)
        matching[kSecReturnData] = true
        matching[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(matching as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw UsageProviderError.needsAuth("macOS refused the keychain read")
        default:
            throw UsageProviderError.unavailable("keychain read failed: OSStatus \(status)")
        }
    }

    private static func query(
        service: String,
        account: String?,
        dataProtection: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }
}
