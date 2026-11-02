import Darwin
import Foundation

enum TerminalInputError: Error {
    case terminalRequired
    case invalidInput
}

enum SecureTerminal {
    static func readPassword() throws -> String {
        guard isatty(STDIN_FILENO) == 1 else { throw TerminalInputError.terminalRequired }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw TerminalInputError.terminalRequired }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON)
        hidden.c_lflag |= tcflag_t(ISIG)
        withUnsafeMutableBytes(of: &hidden.c_cc) { controls in
            controls[Int(VMIN)] = 0
            controls[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else { throw TerminalInputError.terminalRequired }
        defer {
            if tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) != 0 {
                fputs("Warning: could not restore terminal settings.\n", Darwin.stderr)
            }
        }
        // Bound input explicitly; noncanonical mode avoids the kernel dropping an oversized line.
        var buffer = [CChar](repeating: 0, count: Int(MAX_CANON))
        defer {
            buffer.withUnsafeMutableBytes { bytes in
                _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }
        // Prompt only after echo is disabled. Polling lets Task cancellation restore the TTY.
        try FileHandle.standardError.write(contentsOf: Data("Master password (hidden): ".utf8))
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        var length = 0
        while true {
            try Task.checkCancellation()
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw TerminalInputError.invalidInput
            }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count == 1 else { throw TerminalInputError.invalidInput }
            if byte == 10 || byte == 13 {
                let password = buffer.withUnsafeBytes { bytes in
                    String(bytes: bytes.prefix(length), encoding: .utf8)
                }
                guard length > 0, let password else { throw TerminalInputError.invalidInput }
                try Task.checkCancellation()
                try FileHandle.standardError.write(contentsOf: Data("\nRunning read-only vault checks...\n".utf8))
                return password
            }
            if byte == 8 || byte == 127 {
                // Erase an entire UTF-8 code point, without echoing characters or masks.
                while length > 0 {
                    length -= 1
                    let removed = UInt8(bitPattern: buffer[length])
                    buffer[length] = 0
                    if removed & 0xC0 != 0x80 { break }
                }
                continue
            }
            if byte == 21 {
                buffer.withUnsafeMutableBytes { bytes in
                    _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
                }
                length = 0
                continue
            }
            guard byte != 0, byte != 4, length < buffer.count - 2 else { throw TerminalInputError.invalidInput }
            buffer[length] = CChar(bitPattern: byte)
            length += 1
        }
    }
}

/// Converts terminal interruption into Task cancellation so the workflow can await locking.
final class SignalCancellation {
    private var sources: [DispatchSourceSignal] = []
    private var restorers: [() -> Void] = []

    init(cancel: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            let previous = Darwin.signal(number, SIG_IGN)
            restorers.append { _ = Darwin.signal(number, previous) }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: cancel)
            source.resume()
            sources.append(source)
        }
    }

    func restore() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        restorers.forEach { $0() }
        restorers.removeAll()
    }

    deinit { restore() }
}
