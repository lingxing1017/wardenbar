import Darwin
import Foundation
import WardenBarCore

struct CheckResult: Sendable {
    let exitCode: Int32
    let output: String
}

enum CheckCommand {
    static let help = """
    Usage: wardenbar-check [--exercise] [--cli /absolute/path/bw] [--data-dir /dedicated/directory]

    Checks CLI version and login status. Never prints vault contents or credentials.
    Uses ~/Library/Application Support/WardenBar/CLI by default.
    Choose a trusted CLI binary; detection is not a provenance or license audit.

    First login must be completed separately in the same dedicated data directory:
      BITWARDENCLI_APPDATA_DIR="<dedicated-directory>" "<trusted-bw-path>" login
    Configure the intended server in that directory before logging in.
    Default mode does not unlock, sync, or read items.
    --exercise requires a local terminal and asks for the master password without echo.
    It tests unlock, pull-only sync, one personal login password read, and backend lock.
    It never creates, edits or deletes items, and never prints passwords or item content.
    An empty supported list reports an incomplete check (exit 3).

    """

    static func run(
        arguments: [String], readPassword: () throws -> String = SecureTerminal.readPassword
    ) async -> CheckResult {
        if arguments == ["--help"] { return CheckResult(exitCode: 0, output: help) }
        var options: [String: URL] = [:]
        var index = 0
        var exercise = false
        while index < arguments.count {
            let key = arguments[index]
            if key == "--exercise", !exercise {
                exercise = true
                index += 1
                continue
            }
            guard ["--cli", "--data-dir"].contains(key), options[key] == nil,
                  index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                return CheckResult(exitCode: 2, output: "Invalid arguments. Run wardenbar-check --help.\n")
            }
            options[key] = URL(fileURLWithPath: arguments[index + 1])
            index += 2
        }
        do {
            let configuration = try CLIConfiguration.discover(
                executable: options["--cli"], dataDirectory: options["--data-dir"]
            )
            if exercise {
                return await VaultSmokeCheck.run(configuration: configuration, readPassword: readPassword)
            }
            let vault = BitwardenVault(configuration: configuration)
            let version = try await vault.version()
            let status = try await vault.status()
            return CheckResult(exitCode: 0, output: "CLI version: \(version)\nVault status: \(status.rawValue)\n")
        } catch CLIConfigurationError.executableUnavailable {
            return CheckResult(exitCode: 1, output: "Bitwarden CLI unavailable. Install a trusted build or specify --cli.\n")
        } catch CLIConfigurationError.unsafeDataDirectory {
            return CheckResult(exitCode: 1, output: "Cannot prepare a private CLI data directory.\n")
        } catch CLIProcessError.nonzeroExit(let code) {
            return CheckResult(exitCode: 1, output: "Bitwarden CLI command failed (exit code \(code)).\n")
        } catch CLIProcessError.timedOut {
            return CheckResult(exitCode: 1, output: "Bitwarden CLI timed out.\n")
        } catch is CancellationError {
            return CheckResult(exitCode: 130, output: "Check cancelled.\n")
        } catch {
            return CheckResult(exitCode: 1, output: "CLI check failed. Raw CLI output has been withheld.\n")
        }
    }
}

@main
enum WardenBarCheck {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let check = Task { await CheckCommand.run(arguments: arguments) }
        let interruption = SignalCancellation { check.cancel() }
        let result = await check.value
        interruption.restore()
        let stream = result.exitCode == 0 ? FileHandle.standardOutput : .standardError
        try? stream.write(contentsOf: Data(result.output.utf8))
        exit(result.exitCode)
    }
}
