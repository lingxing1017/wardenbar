import AppKit
import SwiftUI
import XCTest
@testable import WardenBarApp
@testable import WardenBarDesktop

@MainActor
private final class WidthPreference: ObservableObject {
    @Published var value: Double = 320
}

@MainActor
private struct LiveWidthHarness: View {
    @ObservedObject var preference: WidthPreference
    let store: VaultStore
    var body: some View {
        ResizableVaultPopover(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil, savedWidth: $preference.value)
    }
}

@MainActor
final class NativeRenderTests: XCTestCase {
    func testLiveWidthChangesResizeThePanelInsteadOfClippingItsContent() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard(name: .init("WardenBarLiveWidth-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: ControlledVault(), clipboard: ClipboardService(pasteboard: board))
        let preference = WidthPreference()
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LiveWidthHarness(preference: preference, store: store))
        // Reproduce a menu-bar host whose native frame does not automatically follow content.
        host.sizingOptions = []
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        let top = panel.frame.maxY
        for width in [480.0, 280.0, 360.0] {
            preference.value = width
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(panel.contentRect(forFrameRect: panel.frame).width, CGFloat(width), accuracy: 0.5)
            XCTAssertEqual(host.bounds.width, CGFloat(width), accuracy: 0.5)
            XCTAssertEqual(panel.frame.maxY, top, accuracy: 0.5)
        }
        panel.orderOut(nil)
    }

    func testLockedListAndDetailRenderWithSyntheticData() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard(name: .init("WardenBarRender-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let backend = ControlledVault()
        let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board))
        await store.start()
        try await render(store, name: "locked", dark: false)
        try await render(store, name: "locked-narrow", dark: false, width: PopoverWidth.minimum)
        await store.unlock(masterPassword: "synthetic-master")
        try await render(store, name: "list", dark: false)
        try await render(store, name: "list-narrow", dark: false, width: PopoverWidth.minimum)
        try await render(store, name: "list-wide", dark: false, width: PopoverWidth.maximum)
        store.select("one")
        try await render(store, name: "detail-dark", dark: true)
        store.select(nil)
        await backend.useLongMetadata()
        await store.sync()
        store.folderFilter = .folder("folder")
        try await render(store, name: "long-list", dark: false, width: PopoverWidth.minimum)
        await store.lock().value
    }

    private func render(_ store: VaultStore, name: String, dark: Bool, width: Double = PopoverWidth.defaultValue) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = ResizableVaultPopover(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil, savedWidth: .constant(width))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 520)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, CGFloat(width), accuracy: 0.5)
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
