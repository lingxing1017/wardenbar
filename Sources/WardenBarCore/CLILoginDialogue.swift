import Foundation

public enum CLILoginChallenge: Sendable, Hashable { case twoFactor, newDevice, clientSecret }
public enum CLILoginError: Error, Equatable { case invalidInput, invalidServer, unsupportedChallenge }

public protocol CLIProcessInteraction: Sendable {
    func nextInput() -> Data?
    func receiveStderr(_ data: Data) throws
}

/// Only recognized prompts cross into the UI. Raw CLI output and pending input stay private.
public final class CLILoginDialogue: CLIProcessInteraction, @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private let email: SecretValue
    private let onChallenge: @Sendable (CLILoginChallenge) -> Void
    private var buffer = Data()
    private var input: [Data] = []
    private var sentEmail = false
    private var seen = Set<CLILoginChallenge>()
    private var waiting: CLILoginChallenge?

    public init(email: String, onChallenge: @escaping @Sendable (CLILoginChallenge) -> Void) throws {
        guard email.contains("@"), email.utf8.count <= 320, Self.validLine(email) else { throw CLILoginError.invalidInput }
        self.email = SecretValue(email)
        self.onChallenge = onChallenge
    }

    public func nextInput() -> Data? {
        lock.withLock { input.isEmpty ? nil : input.removeFirst() }
    }

    @discardableResult
    public func submit(_ value: String) -> Bool {
        lock.withLock {
            guard waiting != nil, Self.validLine(value), value.utf8.count <= 4096 else { return false }
            input.append(Data((value + "\n").utf8))
            waiting = nil
            return true
        }
    }

    public func receiveStderr(_ data: Data) throws {
        let challenge: CLILoginChallenge? = try lock.withLock {
            buffer.append(data)
            if buffer.count > 16384 { buffer = buffer.suffix(8192) }
            let text = String(decoding: buffer, as: UTF8.self)
                .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            if text.contains("Two-step login method:") || text.contains("Master password:") || text.contains("client_id:") {
                throw CLILoginError.unsupportedChallenge
            }
            if !sentEmail, text.contains("Email address:") {
                sentEmail = true
                input.append(email.withValue { Data(($0 + "\n").utf8) })
            }
            let prompts: [(String, CLILoginChallenge)] = [
                ("Two-step login code:", .twoFactor),
                ("New device verification required. Enter OTP sent to login email:", .newDevice),
                ("client_secret:", .clientSecret)
            ]
            for (prompt, kind) in prompts where !seen.contains(kind) && text.contains(prompt) {
                guard waiting == nil else { throw CLILoginError.unsupportedChallenge }
                seen.insert(kind)
                waiting = kind
                return kind
            }
            return nil
        }
        if let challenge { onChallenge(challenge) }
    }

    private static func validLine(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
    public var description: String { "<redacted login dialogue>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
