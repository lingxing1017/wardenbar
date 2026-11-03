import Foundation

public struct VaultServer: Sendable, Equatable {
    public let url: URL
    public static let us = try! VaultServer(address: "https://vault.bitwarden.com")
    public static let eu = try! VaultServer(address: "https://vault.bitwarden.eu")

    public init(address: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\\" || $0 == "\t" }),
              var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())) else {
            throw CLILoginError.invalidServer
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw CLILoginError.invalidServer }
        self.url = url
    }
}

public enum CLITwoFactorMethod: Int, Sendable, CaseIterable { case authenticator = 0, email = 1, yubikey = 3 }
