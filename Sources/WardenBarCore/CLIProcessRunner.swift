import Darwin
import Foundation

/// Deliberately excludes raw stderr, stdout, paths and invocation environments.
public enum CLIProcessError: Error, Equatable {
    case invalidLimits
    case launchFailed
    case ioFailed
    case inputClosed
    case timedOut
    case outputLimitExceeded
    case nonzeroExit(Int32)
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

/// Executes a trusted binary directly. Output stays in memory and is never logged.
public struct CLIProcessRunner: Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data? = nil,
        timeout: TimeInterval = 30,
        outputLimit: Int = 16 * 1024 * 1024
    ) async throws -> Data {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, outputLimit > 0 else { throw CLIProcessError.invalidLimits }
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try execute(
                            executable: executable, arguments: arguments, environment: environment,
                            input: input ?? Data(), timeout: timeout, outputLimit: outputLimit,
                            cancellation: cancellation
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(
        executable: URL, arguments: [String], environment: [String: String],
        input: Data, timeout: TimeInterval, outputLimit: Int, cancellation: CancellationFlag
    ) throws -> Data {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        var inputClosed = false
        defer {
            stop(process)
            for handle in [stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting,
                           stdin.fileHandleForReading] {
                try? handle.close()
            }
            if !inputClosed { try? stdin.fileHandleForWriting.close() }
        }
        do { try process.run() } catch { throw CLIProcessError.launchFailed }

        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        let inFD = stdin.fileHandleForWriting.fileDescriptor
        for descriptor in [outFD, errFD, inFD] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw CLIProcessError.ioFailed
            }
        }
        guard fcntl(inFD, F_SETNOSIGPIPE, 1) >= 0 else { throw CLIProcessError.ioFailed }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var totalBytes = 0
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 8192)

        func drain(_ descriptor: Int32, keep: Bool) throws {
            // Limit each turn so a continuously writing child cannot starve cancellation.
            for _ in 0..<16 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { return }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    if errno == EINTR { continue }
                    throw CLIProcessError.ioFailed
                }
                guard count <= outputLimit - totalBytes else { throw CLIProcessError.outputLimitExceeded }
                totalBytes += count
                if keep { output.append(contentsOf: buffer.prefix(count)) }
            }
        }

        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CLIProcessError.timedOut }
            try drain(outFD, keep: true)
            try drain(errFD, keep: false)

            if !inputClosed {
                if offset < input.count {
                    let written = input.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: offset), min(8192, input.count - offset))
                    }
                    if written > 0 { offset += written }
                    else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw CLIProcessError.inputClosed
                    }
                }
                if offset == input.count {
                    try? stdin.fileHandleForWriting.close()
                    inputClosed = true
                }
            }

            if !process.isRunning {
                // Read all buffered output after exit, without waiting for inherited pipe FDs.
                var previous: Int
                repeat {
                    previous = totalBytes
                    try drain(outFD, keep: true)
                    try drain(errFD, keep: false)
                } while totalBytes > previous
                if cancellation.isCancelled { throw CancellationError() }
                guard process.terminationStatus == 0 else {
                    throw CLIProcessError.nonzeroExit(process.terminationStatus)
                }
                guard offset == input.count else { throw CLIProcessError.inputClosed }
                return output
            }
            usleep(5_000)
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
