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

    func testUniformRowsKeepScrollRangeAndThumbSizeStable() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (width, count) in [(280.0, 14), (320.0, 60), (480.0, 775)] {
            let board = NSPasteboard(name: .init("WardenBarScrollRange-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let backend = ControlledVault()
            await backend.useScrollingRecords(count: count)
            let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board))
            await store.start()
            await store.unlock(masterPassword: "synthetic-master")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
            let host = NSHostingView(rootView: VaultPopoverView(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil).frame(width: width, height: 520))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            defer { window.orderOut(nil) }
            try await settle(host)
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            let initialHeight = try XCTUnwrap(scroll.documentView).frame.height
            let initialThumb = try XCTUnwrap(scroll.verticalScroller).knobProportion
            let travel = initialHeight - scroll.contentView.bounds.height
            for fraction in [0.12, 0.48, 0.78, 1.0, 0.18] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: travel * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(host)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertEqual(scroll.documentView!.frame.height, initialHeight, accuracy: 1)
                XCTAssertEqual(scroll.verticalScroller!.knobProportion, initialThumb, accuracy: 0.001)
                let offset = scroll.contentView.bounds.origin.y
                try await settle(host)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5)
                XCTAssertEqual(scroll.verticalScroller!.knobProportion, initialThumb, accuracy: 0.001)
            }
            await store.lock().value
        }
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
