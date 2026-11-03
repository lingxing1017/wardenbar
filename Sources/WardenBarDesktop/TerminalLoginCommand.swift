import Foundation
import WardenBarCore

public enum TerminalLoginMethod: String, CaseIterable, Sendable {
    case standard, apiKey, sso
    public var arguments: [String] {
        switch self {
        case .standard: return []
        case .apiKey: return ["--apikey"]
        case .sso: return ["--sso"]
        }
    }
}

public enum TerminalLoginCommand {
    /// Contains no account identifiers, passwords, codes or session keys.
    public static func make(executable: URL, dataDirectory: URL, server: VaultServer, method: TerminalLoginMethod) -> String {
        let prefix = "env BITWARDENCLI_APPDATA_DIR=" + quote(dataDirectory.path) + " " + quote(executable.path)
        return prefix + " config server " + quote(server.url.absoluteString) + " &&\n" + prefix + " login" + method.arguments.map { " " + quote($0) }.joined()
    }
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
