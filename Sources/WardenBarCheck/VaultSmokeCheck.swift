import Foundation
import WardenBarCore

/// Opt-in, pull-only integration exercise. Reports contain fixed labels, never vault values.
enum VaultSmokeCheck {
    static func run(
        configuration: CLIConfiguration,
        readPassword: () throws -> String
    ) async -> CheckResult {
        let vault = BitwardenVault(configuration: configuration)
        var output = ""
        do {
            let version = try await vault.version()
            output += "CLI version: \(version)\n"
            let status = try await vault.status()
            guard status != .unauthenticated else {
                return CheckResult(exitCode: 1, output: output + "Check: FAILED (log in to the dedicated directory first)\n")
            }
            try Task.checkCancellation()
            var password = try readPassword()
            defer { password = "" }
            try Task.checkCancellation()

            var phase = "Unlock"
            var failure: Error?
            var readSkipped = false
            do {
                try await vault.unlock(masterPassword: password)
                password = ""
                output += "Unlock: passed\n"
                phase = "Sync"
                try await vault.sync()
                output += "Sync: passed\n"
                phase = "Item listing"
                let items = try await vault.items()
                output += "Item listing: passed\n"
                phase = "Password read"
                if let item = items.first {
                    _ = try await vault.password(for: item.id)
                    output += "Password read: passed\n"
                } else {
                    readSkipped = true
                    output += "Password read: skipped (no supported personal login items)\n"
                }
            } catch {
                password = ""
                failure = error
                output += "\(phase): FAILED (\(safeReason(error)))\n"
            }

            // Explicit cleanup is awaited even when the calling task has been cancelled.
            do {
                try await vault.lock()
                output += "Lock: passed\n"
            } catch {
                output += "Lock: FAILED (\(safeReason(error))); backend cleanup must be retried\n"
                return CheckResult(exitCode: 1, output: output)
            }
            if let failure {
                return CheckResult(exitCode: failure is CancellationError ? 130 : 1, output: output)
            }
            if readSkipped { return CheckResult(exitCode: 3, output: output + "Check: incomplete\n") }
            return CheckResult(exitCode: 0, output: output + "Check: passed\n")
        } catch {
            return CheckResult(
                exitCode: error is CancellationError ? 130 : 1,
                output: output + "Check: FAILED (\(safeReason(error)))\n"
            )
        }
    }

    static func safeReason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? CLIProcessError {
            switch error {
            case .nonzeroExit(let code): return "CLI exited with code \(code)"
            case .timedOut: return "CLI timed out"
            case .outputLimitExceeded: return "CLI output limit exceeded"
            case .launchFailed: return "CLI could not start"
            default: return "CLI process failed"
            }
        }
        if error is VaultError { return "vault operation rejected" }
        return "input or configuration failed"
    }
}
