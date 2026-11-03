import Foundation

public enum VaultState: Sendable, Equatable {
    case unauthenticated, locked, unlocking, unlocked, locking, lockFailed
}

public enum CLIStatus: String, Decodable, Sendable {
    case unauthenticated, locked, unlocked
}

public enum VaultError: Error, Equatable {
    case locked
    case busy
    case sessionChanged
    case invalidPassword
    case invalidResponse
    case itemUnavailable
}

/// Prevents accidental exposure through interpolation, debug logging and reflection.
/// Swift String/Data still do not guarantee zeroization of temporary copies.
public struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String
    init(_ value: String) { self.value = value }
    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(value) }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Metadata only. No password, seed, notes or custom fields are retained here.
public struct VaultItemSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let username: String?
    public let uris: [String]
    public let favorite: Bool
    public let folderID: String?
    public var hasPassword: Bool = true
    public var hasTOTP: Bool = false
    public var type: VaultItemType = .login
    public var subtitle: String?
    public var primaryFieldID: String?
}

public struct VaultFolder: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
}

struct WireItem: Decodable {
    struct Login: Decodable {
        struct URI: Decodable { let uri: String? }
        let username: String?
        let uris: [URI]?
        let password: String?
        let totp: String?
    }
    let id: String
    let name: String
    let type: Int
    let reprompt: Int?
    let organizationId: String?
    let deletedDate: String?
    let favorite: Bool?
    let folderId: String?
    let login: Login?
    let card: Card?
    let identity: Identity?
    let secureNote: SecureNote?
    let sshKey: SSHKey?
    let notes: String?
    let fields: [CustomField]?

    var isSupported: Bool {
        isSupportedRecord && type == 1
    }

    var summary: VaultItemSummary {
        VaultItemSummary(
            id: id, name: name, username: login?.username,
            uris: login?.uris?.compactMap(\.uri) ?? [],
            favorite: favorite ?? false, folderID: folderId,
            hasPassword: type == 1 && login?.password?.isEmpty == false,
            hasTOTP: type == 1 && login?.totp?.isEmpty == false,
            type: VaultItemType(rawValue: type) ?? .login,
            subtitle: recordSubtitle, primaryFieldID: primaryFieldID
        )
    }
}

struct WireItemDetail: Decodable {
    private enum Keys: String, CodingKey { case login }
    private struct Password: Decodable { let password: String? }
    let metadata: WireItem
    let password: String?

    init(from decoder: Decoder) throws {
        metadata = try WireItem(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        password = try container.decodeIfPresent(Password.self, forKey: .login)?.password
    }
}
