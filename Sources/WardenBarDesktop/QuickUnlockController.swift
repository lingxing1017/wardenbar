import Combine
import CommonCrypto
import CryptoKit
import Foundation

public enum QuickUnlockError: Error, LocalizedError {
    case notConfigured, invalidPassword, invalidPIN, pinRequiresMasterPassword
    case biometricUnavailable, changed, storageFailure

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先解锁密码库并设置解锁方式"
        case .invalidPassword: return "主密码不正确，请重试"
        case .invalidPIN: return "PIN 码不正确，请重试；连续输错 5 次后需使用主密码"
        case .pinRequiresMasterPassword: return "请先使用主密码解锁，再使用 PIN 码"
        case .biometricUnavailable: return "Touch ID 不可用，请使用主密码解锁"
        case .changed: return "密码库状态已变化，请重试"
        case .storageFailure: return "无法访问受保护的解锁凭据，请使用主密码或重新设置"
        }
    }
}

@MainActor
public protocol BiometricCredentials: AnyObject {
    var isAvailable: Bool { get }
    func save(_ password: Data, account: String) async throws
    func read(account: String) async throws -> Data
    func remove(account: String) throws
    func cancel()
}

/// Secrets never enter published state or defaults. A PIN capsule lives only in
/// this process; its wrapping key is persisted only encrypted by the master password.
@MainActor
public final class QuickUnlockController: ObservableObject {
    @Published public private(set) var touchIDEnabled = false
    @Published public private(set) var pinConfigured = false
    @Published public private(set) var pinReady = false
    @Published public private(set) var isBusy = false
    public var touchIDAvailable: Bool { credentials.isAvailable }
    public var isBound: Bool { account != nil }

    private struct PINRecord: Codable {
        let version: Int
        let masterSalt: Data
        let pinSalt: Data
        let protectedKey: Data
    }
    private let defaults: UserDefaults
    private let credentials: any BiometricCredentials
    private let profile: String
    private var account: String?
    private var revision: UInt64 = 0
    private var authorizationSalt = Data()
    private var authorization: Data?
    private var capsule: Data?
    private var processKey = SymmetricKey(size: .bits256)
    private var failedPINs = 0

    public init(defaults: UserDefaults = .standard, credentials: any BiometricCredentials, profile: String) {
        self.defaults = defaults
        self.credentials = credentials
        self.profile = profile
    }

    public func bind(account identity: String?) {
        let scoped = identity.map { Self.digest(Data((profile + "\0" + $0).utf8)).map { String(format: "%02x", $0) }.joined() }
        guard scoped != account else { return }
        revokeAuthorization()
        account = scoped
        capsule = nil
        pinReady = false
        failedPINs = 0
        processKey = SymmetricKey(size: .bits256)
        pinConfigured = record() != nil
        touchIDEnabled = scoped.map { defaults.bool(forKey: "quickUnlock.touchID." + $0) } ?? false
    }

    /// Call only after a successful backend unlock, never on an authentication UI result.
    public func recordUnlocked(password: String, manual: Bool) {
        guard account != nil else { return }
        authorizationSalt = Self.randomData()
        authorization = Self.digest(authorizationSalt + Data(password.utf8))
        guard manual, let record = record() else { return }
        do {
            let key = try Self.derive(password, salt: record.masterSalt)
            let pinKey = try AES.GCM.open(AES.GCM.SealedBox(combined: record.protectedKey), using: key)
            try armPIN(password: password, pinKey: pinKey)
        } catch {
            // A changed master password cannot reuse an old PIN enrollment.
            disablePIN()
        }
    }

    public func configurePIN(_ pin: String, password: String) throws {
        try requireAuthorization(password)
        guard Self.validPIN(pin) else { throw QuickUnlockError.invalidPIN }
        let masterSalt = Self.randomData(), pinSalt = Self.randomData()
        let pinKey = try Self.derive(pin, salt: pinSalt).withUnsafeBytes { Data($0) }
        let protected = try AES.GCM.seal(pinKey, using: Self.derive(password, salt: masterSalt)).combined!
        let value = PINRecord(version: 1, masterSalt: masterSalt, pinSalt: pinSalt, protectedKey: protected)
        let encoded = try JSONEncoder().encode(value)
        try armPIN(password: password, pinKey: pinKey)
        defaults.set(encoded, forKey: pinStorageKey)
        pinConfigured = true
    }

    public func disablePIN() {
        guard account != nil else { return }
        defaults.removeObject(forKey: pinStorageKey)
        capsule = nil
        pinReady = false
        pinConfigured = false
        failedPINs = 0
        processKey = SymmetricKey(size: .bits256)
    }

    public func passwordForPIN(_ pin: String) throws -> String {
        guard pinReady, let capsule, let record = record() else { throw QuickUnlockError.pinRequiresMasterPassword }
        do {
            guard Self.validPIN(pin) else { throw QuickUnlockError.invalidPIN }
            let pinKey = try Self.derive(pin, salt: record.pinSalt).withUnsafeBytes { Data($0) }
            let password = try AES.GCM.open(AES.GCM.SealedBox(combined: capsule), using: capsuleKey(pinKey))
            guard let value = String(data: password, encoding: .utf8), !value.isEmpty else { throw QuickUnlockError.invalidPIN }
            failedPINs = 0
            return value
        } catch {
            failedPINs += 1
            if failedPINs >= 5 { self.capsule = nil; pinReady = false; processKey = SymmetricKey(size: .bits256) }
            throw pinReady ? QuickUnlockError.invalidPIN : QuickUnlockError.pinRequiresMasterPassword
        }
    }

    public func enableTouchID(password: String) async throws {
        try requireAuthorization(password)
        guard credentials.isAvailable, let account, !isBusy else { throw QuickUnlockError.biometricUnavailable }
        let token = revision
        isBusy = true
        defer { isBusy = false }
        try await credentials.save(Data(password.utf8), account: account)
        guard revision == token, self.account == account else {
            try? credentials.remove(account: account)
            throw QuickUnlockError.changed
        }
        defaults.set(true, forKey: "quickUnlock.touchID." + account)
        touchIDEnabled = true
    }

    public func disableTouchID() throws {
        guard let account, !isBusy else { throw QuickUnlockError.changed }
        try credentials.remove(account: account)
        defaults.removeObject(forKey: "quickUnlock.touchID." + account)
        touchIDEnabled = false
    }

    public func passwordForTouchID() async throws -> String {
        guard touchIDEnabled, let account, !isBusy else { throw QuickUnlockError.notConfigured }
        let token = revision
        isBusy = true
        defer { isBusy = false }
        let data = try await credentials.read(account: account)
        guard revision == token, self.account == account else { throw QuickUnlockError.changed }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else { throw QuickUnlockError.storageFailure }
        return password
    }

    public func revokeAuthorization() {
        cancelPendingAuthentication()
        authorization = nil
        authorizationSalt = Data()
    }

    public func cancelPendingAuthentication() {
        revision &+= 1
        credentials.cancel()
    }

    private var pinStorageKey: String { "quickUnlock.pin." + (account ?? "unbound") }
    private func record() -> PINRecord? {
        guard account != nil, let data = defaults.data(forKey: pinStorageKey),
              let value = try? JSONDecoder().decode(PINRecord.self, from: data), value.version == 1,
              value.masterSalt.count == 32, value.pinSalt.count == 32 else { return nil }
        return value
    }
    private func requireAuthorization(_ password: String) throws {
        guard account != nil, let authorization else { throw QuickUnlockError.changed }
        let candidate = Self.digest(authorizationSalt + Data(password.utf8))
        guard zip(candidate, authorization).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { throw QuickUnlockError.invalidPassword }
    }
    private func armPIN(password: String, pinKey: Data) throws {
        processKey = SymmetricKey(size: .bits256)
        capsule = try AES.GCM.seal(Data(password.utf8), using: capsuleKey(pinKey)).combined
        failedPINs = 0
        pinReady = true
    }
    private func capsuleKey(_ pinKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pinKey),
                              salt: processKey.withUnsafeBytes { Data($0) }, info: Data("WardenBar PIN capsule v1".utf8), outputByteCount: 32)
    }
    private static func validPIN(_ pin: String) -> Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    private static func randomData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        var output = Data(count: 32)
        let result = output.withUnsafeMutableBytes { target in
            salt.withUnsafeBytes { saltBytes in
                bytes.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000,
                                        target.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard result == kCCSuccess else { throw QuickUnlockError.storageFailure }
        return SymmetricKey(data: output)
    }
}
