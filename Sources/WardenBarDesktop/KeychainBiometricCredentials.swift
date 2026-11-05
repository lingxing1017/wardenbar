import Foundation
import LocalAuthentication
import Security

/// Device-only Keychain data, released by the current enrolled biometric set.
/// The credential itself is access controlled; a successful UI prompt is not a bypass.
@MainActor
public final class KeychainBiometricCredentials: BiometricCredentials {
    private var context: LAContext?
    private let service = "app.wardenbar.quick-unlock.v1"
    public init() {}

    public var isAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID
    }

    public func save(_ password: Data, account: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        self.context = context
        defer { self.context = nil }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "启用 WardenBar 指纹解锁") else {
            throw QuickUnlockError.biometricUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw QuickUnlockError.storageFailure
        }
        // Delete/add instead of updating ACLs in place; a failed write never enables the preference.
        try remove(account: account)
        var query = base(account)
        query[kSecAttrAccessControl as String] = control
        query[kSecUseAuthenticationContext as String] = context
        query[kSecValueData as String] = password
        let result = SecItemAdd(query as CFDictionary, nil)
        guard result == errSecSuccess else { throw QuickUnlockError.storageFailure }
    }

    public func read(account: String) async throws -> Data {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedReason = "解锁 WardenBar 密码库"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        self.context = context
        defer { self.context = nil }
        var query = base(account)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Security may wait for Touch ID; keep the main actor free for lock/cancel events.
        let result: Data = try await Task.detached {
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            guard status == errSecSuccess, let data = value as? Data else {
                throw QuickUnlockError.biometricUnavailable
            }
            return data
        }.value
        return result
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuickUnlockError.storageFailure }
    }

    public func cancel() { context?.invalidate() }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
}
