import AppKit
import XCTest
@testable import WardenBarDesktop

@MainActor
final class ClipboardServiceTests: XCTestCase {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("WardenBarTest-" + UUID().uuidString))
    }

    func testOwnedCopyExpires() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: board, expiry: 0.03)
        try clipboard.copy("synthetic-value")
        XCTAssertEqual(board.string(forType: .string), "synthetic-value")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(board.string(forType: .string))
    }

    func testExpiryAndLockPreserveNewerUserCopy() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: board, expiry: 0.03)
        try clipboard.copy("synthetic-value")
        board.clearContents()
        board.setString("user-copy", forType: .string)
        try await Task.sleep(nanoseconds: 150_000_000)
        clipboard.clearIfOwned()
        XCTAssertEqual(board.string(forType: .string), "user-copy")
    }

    func testNewCopyIsNotClearedByOldTimer() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: board, expiry: 0.15)
        try clipboard.copy("first")
        try await Task.sleep(nanoseconds: 100_000_000)
        try clipboard.copy("second")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(board.string(forType: .string), "second")
        clipboard.clearIfOwned()
        XCTAssertNil(board.string(forType: .string))
    }
}
