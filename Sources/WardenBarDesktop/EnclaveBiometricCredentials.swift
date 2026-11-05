import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The Keychain stores only an encrypted envelope. Decryption requires an
/// operation by a device-bound Secure Enclave key protected by the current
/// biometric set, including in locally signed builds without access-group rights.
@MainActor
public final class KeychainBiometricCredentials: BiometricCredentials {
    private var context: LAContext?
    private let service = "app.wardenbar.quick-unlock.v1"
    public init() {}

    public var isAvailable: Bool {
        let context = LAContext()
        return SecureEnclave.isAvailable && context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID
    }

    public func save(_ password: Data, account: String) async throws {
        let context = makeContext(reason: "启用 WardenBar 指纹解锁")
        self.context = context
        defer { self.context = nil }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: context.localizedReason) else {
            throw QuickUnlockError.biometricUnavailable
        }
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                          [.biometryCurrentSet, .privateKeyUsage], nil) else {
            throw QuickUnlockError.storageFailure
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: control, authenticationContext: context)
        let envelope = try BiometricCredentialEnvelope.seal(password, recipient: key.publicKey, secureKey: key.dataRepresentation, account: account)
        let data = try JSONEncoder().encode(envelope)
        let query = base(account)
        try await Task.detached {
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecSuccess { return }
            guard updated == errSecItemNotFound else { throw QuickUnlockError.storageFailure }
            var added = query
            added[kSecValueData as String] = data
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw QuickUnlockError.storageFailure }
        }.value
    }

    public func read(account: String) async throws -> Data {
        let context = makeContext(reason: "解锁 WardenBar 密码库")
        self.context = context
        defer { self.context = nil }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try await Task.detached {
            var value: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else {
                throw QuickUnlockError.storageFailure
            }
            let envelope = try JSONDecoder().decode(BiometricCredentialEnvelope.self, from: data)
            guard envelope.version == 1 else { throw QuickUnlockError.storageFailure }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.secureKey, authenticationContext: context)
            let sender = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.senderPublicKey)
            // The Secure Enclave enforces biometric approval for this operation.
            let shared = try key.sharedSecretFromKeyAgreement(with: sender)
            return try envelope.open(sharedSecret: shared, account: account)
        }.value
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuickUnlockError.storageFailure }
    }
    public func cancel() { context?.invalidate() }

    private func makeContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return context
    }
    private func base(_ account: String) -> [String: Any] {
        // The ordinary macOS Keychain stores the opaque key blob and ciphertext.
        // Reading these bytes does not bypass the Secure Enclave's access control.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

struct BiometricCredentialEnvelope: Codable {
    let version: Int
    let secureKey: Data
    let senderPublicKey: Data
    let salt: Data
    let ciphertext: Data

    static func seal(_ plaintext: Data, recipient: P256.KeyAgreement.PublicKey, secureKey: Data, account: String) throws -> Self {
        let sender = P256.KeyAgreement.PrivateKey()
        let shared = try sender.sharedSecretFromKeyAgreement(with: recipient)
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("WardenBar Touch ID v1".utf8), outputByteCount: 32)
        let ciphertext = try AES.GCM.seal(plaintext, using: key, authenticating: Data(account.utf8)).combined!
        return Self(version: 1, secureKey: secureKey, senderPublicKey: sender.publicKey.rawRepresentation, salt: salt, ciphertext: ciphertext)
    }

    func open(sharedSecret: SharedSecret, account: String) throws -> Data {
        let key = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("WardenBar Touch ID v1".utf8), outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: Data(account.utf8))
    }
}
