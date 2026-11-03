import WardenBarCore

public protocol VaultBackend: Sendable {
    var state: VaultState { get async }
    func version() async throws -> String
    func status() async throws -> CLIStatus
    func unlock(masterPassword: String) async throws
    func items() async throws -> [VaultItemSummary]
    func folders() async throws -> [VaultFolder]
    func password(for id: String) async throws -> SecretValue
    func totp(for id: String) async throws -> SecretValue
    func details(for id: String) async throws -> [VaultDetailField]
    func fieldValue(for id: String, fieldID: String) async throws -> SecretValue
    func sync() async throws
    func lock() async throws
}

extension BitwardenVault: VaultBackend {}
