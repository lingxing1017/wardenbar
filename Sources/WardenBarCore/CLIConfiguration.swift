import Darwin
import Foundation

public enum CLIConfigurationError: Error, Equatable {
    case executableUnavailable
    case unsafeDataDirectory
}

/// Runtime paths only. Credentials and session keys never belong in configuration.
public struct CLIConfiguration: Sendable {
    public let executable: URL
    public let dataDirectory: URL

    public static func discover(
        executable: URL? = nil,
        dataDirectory: URL? = nil,
        candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/bw"),
            URL(fileURLWithPath: "/usr/local/bin/bw")
        ]
    ) throws -> CLIConfiguration {
        let choices = executable.map { [$0] } ?? candidates
        guard let binary = choices.first(where: { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: url.path)
        }) else {
            throw CLIConfigurationError.executableUnavailable
        }
        let directory = dataDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WardenBar/CLI", isDirectory: true)
        guard directory.isFileURL else { throw CLIConfigurationError.unsafeDataDirectory }
        return CLIConfiguration(executable: binary.standardizedFileURL, dataDirectory: directory.standardizedFileURL)
    }

    /// Does not adopt the terminal CLI's default authentication directory.
    public func prepareDataDirectory() throws {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: dataDirectory.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CLIConfigurationError.unsafeDataDirectory
            }
        }
        do {
            try manager.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
        } catch {
            throw CLIConfigurationError.unsafeDataDirectory
        }
    }

    /// Allowlist instead of inheriting BW_SESSION, debug flags or Node injection options.
    public func environment(parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            result[key] = parent[key]
        }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        result["BITWARDENCLI_APPDATA_DIR"] = dataDirectory.path
        return result
    }
}
