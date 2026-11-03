import AppKit
import SwiftUI
import XCTest
@testable import WardenBarApp
@testable import WardenBarCore
@testable import WardenBarDesktop

@MainActor
final class ScrollRegressionTests: XCTestCase {
    func testListKeepsItsOffsetAfterReturningFromDetails() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard(name: .init("WardenBarScroll-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let backend = ControlledVault()
        await backend.useScrollingRecords()
        let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board))
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: VaultPopoverView(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil).frame(width: 320, height: 520))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        defer { window.orderOut(nil) }
        try await settle(host)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 270))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 100)
        store.select("row5")
        try await settle(host)
        store.select(nil)
        try await settle(host)
        let returned = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(returned === scroll)
        XCTAssertEqual(returned.contentView.bounds.origin.y, offset, accuracy: 1)
        await store.lock().value
        try await settle(host)
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
