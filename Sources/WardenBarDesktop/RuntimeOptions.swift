import Foundation

public struct RuntimeOptions {
    public let cli: URL?
    public let dataDirectory: URL
    public init(cli: URL? = nil, dataDirectory: URL? = nil) {
        self.cli = cli
        self.dataDirectory = dataDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WardenBar/CLI", isDirectory: true)
    }

    public static func parse(_ arguments: [String]) throws -> RuntimeOptions {
        var options: [String: URL] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--cli", "--data-dir"].contains(key), options[key] == nil,
                  index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                throw RuntimeOptionsError.invalidArguments
            }
            options[key] = URL(fileURLWithPath: arguments[index + 1])
            index += 2
        }
        return RuntimeOptions(cli: options["--cli"], dataDirectory: options["--data-dir"])
    }
}

public enum RuntimeOptionsError: Error { case invalidArguments }
