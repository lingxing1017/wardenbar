import Foundation
import OSLog

public enum VaultReadPolicy: Sendable { case onDemand, sessionSnapshot }

/// Owns the in-memory session. All data commands are exclusive; locking preempts them.
public actor BitwardenVault {
    public private(set) var state: VaultState = .locked
    private let configuration: CLIConfiguration
    private let runner = CLIProcessRunner()
    private let timeout: TimeInterval
    private let readPolicy: VaultReadPolicy
    private let clock: @Sendable () -> Date
    private struct SnapshotSecrets: Sendable {
        let password: SecretValue?
        let seed: SecretValue?
        let fields: [VaultDetailField]
    }
    private var snapshot: [String: SnapshotSecrets] = [:]
    private var session: SecretValue?
    private var authorizedIDs = Set<String>()
    private var generation: UInt64 = 0
    private var nextOperation: UInt64 = 0
    private var operation: (id: UInt64, task: Task<Data, Error>)?

    public init(configuration: CLIConfiguration, timeout: TimeInterval = 30, readPolicy: VaultReadPolicy = .onDemand, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.timeout = timeout
        self.readPolicy = readPolicy
        self.clock = clock
    }

    public func version() async throws -> String {
        guard state != .unlocking else { throw VaultError.busy }
        let data = try await perform(["--version"])
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalidResponse }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^[0-9]{4}\.[0-9]{1,2}\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
                            options: .regularExpression) != nil else { throw VaultError.invalidResponse }
        return version
    }

    public func status() async throws -> CLIStatus {
        guard state != .unlocking else { throw VaultError.busy }
        struct Response: Decodable { let status: CLIStatus }
        let token = generation
        let data = try await perform(["status"], authenticated: session != nil)
        guard token == generation else { throw VaultError.sessionChanged }
        let reported = try decode(Response.self, from: data).status
        if reported != .unlocked {
            generation &+= 1
            session = nil
            authorizedIDs.removeAll()
            snapshot.removeAll()
            // Without BW_SESSION, coarse status cannot prove a failed backend lock was repaired.
            if state != .lockFailed {
                state = reported == .unauthenticated ? .unauthenticated : .locked
            }
        } else if session == nil {
            throw VaultError.invalidResponse
        }
        return reported
    }

    public func login(server: VaultServer, masterPassword: String, method: CLITwoFactorMethod, dialogue: CLILoginDialogue) async throws {
        guard state == .unauthenticated, operation == nil else { throw VaultError.busy }
        guard !masterPassword.isEmpty, !masterPassword.contains("\0") else { throw VaultError.invalidPassword }
        // Recheck the dedicated profile before changing its configured server.
        guard try await status() == .unauthenticated else { throw VaultError.busy }
        generation &+= 1
        let token = generation
        state = .unlocking
        snapshot.removeAll()
        authorizedIDs.removeAll()
        do {
            _ = try await perform(["config", "server", server.url.absoluteString])
            guard token == generation, state == .unlocking else { throw VaultError.sessionChanged }
            let data = try await perform(
                ["login", "--passwordenv", "BW_UNLOCK_PASSWORD", "--method", String(method.rawValue), "--raw"],
                masterPassword: masterPassword, interaction: dialogue, timeoutOverride: max(timeout, 180)
            )
            guard token == generation, state == .unlocking else { throw VaultError.sessionChanged }
            guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalidResponse }
            let key = text.trimmingCharacters(in: .newlines)
            guard let decoded = Data(base64Encoded: key), decoded.count >= 16 else { throw VaultError.invalidResponse }
            session = SecretValue(key)
            state = .unlocked
        } catch {
            if token == generation { try? await lock() }
            throw error
        }
    }

    public func unlock(masterPassword: String) async throws {
        guard state != .unlocking && state != .locking, operation == nil else { throw VaultError.busy }
        guard state != .unlocked else { throw VaultError.busy }
        guard !masterPassword.isEmpty, !masterPassword.contains("\0") else { throw VaultError.invalidPassword }
        generation &+= 1
        snapshot.removeAll()
        authorizedIDs.removeAll()
        let token = generation
        state = .unlocking
        do {
            let data = try await perform(
                ["unlock", "--passwordenv", "BW_UNLOCK_PASSWORD", "--raw"],
                masterPassword: masterPassword
            )
            guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalidResponse }
            let key = text.trimmingCharacters(in: .newlines)
            guard let decoded = Data(base64Encoded: key), decoded.count >= 16 else {
                throw VaultError.invalidResponse
            }
            guard token == generation else { throw VaultError.sessionChanged }
            session = SecretValue(key)
            state = .unlocked
        } catch {
            if token == generation {
                // A successful command with malformed output might still have unlocked the backend.
                try? await lock()
            }
            throw error
        }
    }

    public func items() async throws -> [VaultItemSummary] {
        try requireReady()
        authorizedIDs.removeAll()
        snapshot.removeAll()
        let token = generation
        let data = try await perform(["list", "items"], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        let items = try decode([WireItem].self, from: data).filter {
            readPolicy == .sessionSnapshot ? $0.isSupportedRecord : $0.isSupported
        }
        authorizedIDs = Set(items.map(\.id))
        if readPolicy == .sessionSnapshot {
            // Only allowlisted personal records survive the response's transient lifetime.
            for item in items {
                snapshot[item.id] = SnapshotSecrets(
                    password: item.type == 1 ? item.login?.password.map(SecretValue.init) : nil,
                    seed: item.type == 1 ? item.login?.totp.map(SecretValue.init) : nil,
                    fields: item.detailFields
                )
            }
        }
        return items.map(\.summary)
    }

    public func folders() async throws -> [VaultFolder] {
        struct WireFolder: Decodable { let id: String?; let name: String }
        try requireReady()
        let token = generation
        let data = try await perform(["list", "folders"], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        // CLI versions may include a synthetic "no folder" entry with an empty/null ID.
        // The UI already supplies its own localized unfiled filter.
        return try decode([WireFolder].self, from: data).compactMap {
            guard let id = $0.id, UUID(uuidString: id) != nil else { return nil }
            return VaultFolder(id: id, name: $0.name)
        }
    }

    public func totp(for id: String) async throws -> SecretValue {
        if readPolicy == .sessionSnapshot {
            let started = ProcessInfo.processInfo.systemUptime
            defer { Self.recordDuration("snapshot_totp", since: started) }
            guard let seed = try snapshotEntry(for: id).seed else { throw VaultError.itemUnavailable }
            return try seed.withValue { try LocalTOTP.generate(seed: $0, at: clock()) }
        }
        let token = generation
        let item = try await detail(for: id)
        guard item.metadata.summary.hasTOTP else { throw VaultError.itemUnavailable }
        let data = try await perform(["get", "totp", id], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalidResponse }
        let code = text.trimmingCharacters(in: .newlines)
        let pattern = item.metadata.login?.totp?.hasPrefix("steam://") == true
            ? #"^[23456789BCDFGHJKMNPQRTVWXY]{5}$"# : #"^[0-9]{6,10}$"#
        guard code.range(of: pattern, options: .regularExpression) != nil else { throw VaultError.invalidResponse }
        return SecretValue(code)
    }

    public func password(for id: String) async throws -> SecretValue {
        if readPolicy == .sessionSnapshot {
            let started = ProcessInfo.processInfo.systemUptime
            defer { Self.recordDuration("snapshot_password", since: started) }
            guard let password = try snapshotEntry(for: id).password else { throw VaultError.itemUnavailable }
            return password
        }
        let item = try await detail(for: id)
        guard let password = item.password else { throw VaultError.itemUnavailable }
        return SecretValue(password)
    }

    public func details(for id: String) async throws -> [VaultDetailField] {
        if readPolicy == .sessionSnapshot { return try snapshotEntry(for: id).fields }
        return try await detail(for: id).metadata.detailFields
    }

    public func fieldValue(for id: String, fieldID: String) async throws -> SecretValue {
        let token = generation
        let fields = try await details(for: id)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        guard let field = fields.first(where: { $0.id == fieldID }) else { throw VaultError.itemUnavailable }
        return field.value
    }

    private func snapshotEntry(for id: String) throws -> SnapshotSecrets {
        // Read-only folder requests may be in flight. Snapshot mutation always revokes entries first.
        guard state == .unlocked, session != nil else { throw VaultError.locked }
        guard authorizedIDs.contains(id), let entry = snapshot[id] else { throw VaultError.itemUnavailable }
        return entry
    }

    private func detail(for id: String) async throws -> WireItemDetail {
        try requireReady()
        guard authorizedIDs.contains(id), UUID(uuidString: id) != nil else { throw VaultError.itemUnavailable }
        let token = generation
        // Read JSON to preserve password whitespace and recheck reprompt/ownership at use time.
        let data = try await perform(["get", "item", id], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        let item = try decode(WireItemDetail.self, from: data)
        guard item.metadata.id == id, item.metadata.isSupported else {
            authorizedIDs.remove(id)
            throw VaultError.itemUnavailable
        }
        return item
    }

    public func sync() async throws {
        try requireReady()
        if readPolicy == .sessionSnapshot {
            snapshot.removeAll()
            authorizedIDs.removeAll()
        }
        let token = generation
        _ = try await perform(["sync"], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        authorizedIDs.removeAll()
    }

    /// Local access is revoked before any await. Backend failure remains visible in state.
    /// Once started, cleanup runs even if the caller cancels its task.
    public func lock() async throws {
        guard state != .locking else { throw VaultError.busy }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Self.recordDuration("lock", since: started) }
        generation &+= 1
        session = nil
        snapshot.removeAll()
        authorizedIDs.removeAll()
        state = .locking
        let previous = operation
        previous?.task.cancel()
        if let previous { _ = await previous.task.result }
        operation = nil
        nextOperation &+= 1
        let id = nextOperation
        let configuration = self.configuration
        let runner = self.runner
        let timeout = self.timeout
        let task = Task {
            try configuration.prepareDataDirectory()
            return try await runner.run(
                executable: configuration.executable, arguments: ["lock", "--nointeraction"],
                environment: configuration.environment(), timeout: timeout
            )
        }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        do {
            _ = try await task.value
            state = .locked
        } catch {
            state = .lockFailed
            throw error
        }
    }

    private func requireReady() throws {
        guard state == .unlocked, session != nil else { throw VaultError.locked }
        guard operation == nil else { throw VaultError.busy }
    }

    private func perform(
        _ arguments: [String], authenticated: Bool = false, masterPassword: String? = nil,
        interaction: (any CLIProcessInteraction)? = nil, timeoutOverride: TimeInterval? = nil
    ) async throws -> Data {
        guard operation == nil, state != .locking else { throw VaultError.busy }
        let started = ProcessInfo.processInfo.systemUptime
        // Only fixed verbs, never paths, item IDs, CLI output or credentials.
        let category = ["login", "config", "unlock", "status", "list", "get", "sync", "--version"].contains(arguments.first ?? "") ? arguments[0] : "other"
        defer { Self.recordDuration(category, since: started) }
        try Task.checkCancellation()
        try configuration.prepareDataDirectory()
        var environment = configuration.environment()
        if authenticated {
            guard let session else { throw VaultError.locked }
            session.withValue { environment["BW_SESSION"] = $0 }
        }
        environment["BW_UNLOCK_PASSWORD"] = masterPassword
        let token = generation
        nextOperation &+= 1
        let id = nextOperation
        let runner = self.runner
        let configuration = self.configuration
        let timeout = timeoutOverride ?? self.timeout
        let task = Task {
            try await runner.run(
                executable: configuration.executable, arguments: arguments + (interaction == nil ? ["--nointeraction"] : []),
                environment: environment, interaction: interaction, timeout: timeout
            )
        }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        do {
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard token == generation else { throw VaultError.sessionChanged }
            try Task.checkCancellation()
            return data
        } catch {
            guard token == generation else { throw VaultError.sessionChanged }
            throw error
        }
    }

    private static func recordDuration(_ category: String, since start: TimeInterval) {
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        Logger(subsystem: "org.wardenbar.WardenBar", category: "performance")
            .info("CLI operation=\(category, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw VaultError.invalidResponse }
    }
}
