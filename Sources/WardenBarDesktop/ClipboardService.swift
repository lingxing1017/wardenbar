import AppKit
import Foundation

public enum ClipboardError: Error { case writeFailed }

@MainActor
public final class ClipboardService {
    private let pasteboard: NSPasteboard
    private let expiry: TimeInterval
    private var ownedChange: Int?
    private var generation: UInt64 = 0
    private var cleanup: Task<Void, Never>?

    public init(pasteboard: NSPasteboard = .general, expiry: TimeInterval = 30) {
        self.pasteboard = pasteboard
        self.expiry = max(0, expiry)
    }

    public func copy(_ value: String) throws {
        cleanup?.cancel()
        generation &+= 1
        let token = generation
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        // Best-effort conventions for clipboard managers, not a confidentiality guarantee.
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        ownedChange = nil
        guard pasteboard.writeObjects([item]) else { throw ClipboardError.writeFailed }
        ownedChange = pasteboard.changeCount
        let delay = UInt64(min(expiry, 86_400) * 1_000_000_000)
        cleanup = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.generation == token else { return }
            self.clearIfOwned()
        }
    }

    public func clearIfOwned() {
        cleanup?.cancel()
        cleanup = nil
        generation &+= 1
        if let ownedChange, pasteboard.changeCount == ownedChange { pasteboard.clearContents() }
        ownedChange = nil
    }

    deinit { cleanup?.cancel() }
}
