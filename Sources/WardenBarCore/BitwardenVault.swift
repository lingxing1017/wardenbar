import Foundation

/// Owns the in-memory session. All data commands are exclusive; locking preempts them.
public actor BitwardenVault {
    public private(set) var state: VaultState = .locked
    private let configuration: CLIConfiguration
    private let runner = CLIProcessRunner()
    private let timeout: TimeInterval
    private var session: SecretValue?
    private var authorizedIDs = Set<String>()
    private var generation: UInt64 = 0
    private var nextOperation: UInt64 = 0
    private var operation: (id: UInt64, task: Task<Data, Error>)?

    public init(configuration: CLIConfiguration, timeout: TimeInterval = 30) {
        self.configuration = configuration
        self.timeout = timeout
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
            // Without BW_SESSION, coarse status cannot prove a failed backend lock was repaired.
            if state != .lockFailed {
                state = reported == .unauthenticated ? .unauthenticated : .locked
            }
        } else if session == nil {
            throw VaultError.invalidResponse
        }
        return reported
    }

    public func unlock(masterPassword: String) async throws {
        guard state != .unlocking && state != .locking, operation == nil else { throw VaultError.busy }
        guard state != .unlocked else { throw VaultError.busy }
        guard !masterPassword.isEmpty, !masterPassword.contains("\0") else { throw VaultError.invalidPassword }
        generation &+= 1
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
        let token = generation
        let data = try await perform(["list", "items"], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        let items = try decode([WireItem].self, from: data).filter(\.isSupported)
        authorizedIDs = Set(items.map(\.id))
        return items.map(\.summary)
    }

    public func password(for id: String) async throws -> SecretValue {
        try requireReady()
        guard authorizedIDs.contains(id), UUID(uuidString: id) != nil else { throw VaultError.itemUnavailable }
        let token = generation
        // Read JSON to preserve password whitespace and recheck reprompt/ownership at use time.
        let data = try await perform(["get", "item", id], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        let item = try decode(WireItemDetail.self, from: data)
        guard item.metadata.id == id, item.metadata.isSupported, let password = item.password else {
            authorizedIDs.remove(id)
            throw VaultError.itemUnavailable
        }
        return SecretValue(password)
    }

    public func sync() async throws {
        try requireReady()
        let token = generation
        _ = try await perform(["sync"], authenticated: true)
        guard token == generation, state == .unlocked else { throw VaultError.sessionChanged }
        authorizedIDs.removeAll()
    }

    /// Local access is revoked before any await. Backend failure remains visible in state.
    /// Once started, cleanup runs even if the caller cancels its task.
    public func lock() async throws {
        guard state != .locking else { throw VaultError.busy }
        generation &+= 1
        session = nil
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
        _ arguments: [String], authenticated: Bool = false, masterPassword: String? = nil
    ) async throws -> Data {
        guard operation == nil, state != .locking else { throw VaultError.busy }
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
        let timeout = self.timeout
        let task = Task {
            try await runner.run(
                executable: configuration.executable, arguments: arguments + ["--nointeraction"],
                environment: environment, timeout: timeout
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw VaultError.invalidResponse }
    }
}
