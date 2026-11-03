import AppKit
import SwiftUI
import XCTest
@testable import WardenBarApp
@testable import WardenBarDesktop

@MainActor
final class NativeRenderTests: XCTestCase {
    func testLockedListAndDetailRenderWithSyntheticData() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard(name: .init("WardenBarRender-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: ControlledVault(), clipboard: ClipboardService(pasteboard: board))
        await store.start()
        try await render(store, name: "locked", dark: false)
        await store.unlock(masterPassword: "synthetic-master")
        try await render(store, name: "list", dark: false)
        store.select("one")
        try await render(store, name: "detail-dark", dark: true)
        await store.lock().value
    }

    private func render(_ store: VaultStore, name: String, dark: Bool) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = VaultPopoverView(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil)
            .frame(width: 390, height: 520).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 520)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = appRoot.appendingPathComponent(".build/visual-check", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        window.orderOut(nil)
    }
}
