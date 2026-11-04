import AppKit
import SwiftUI
import XCTest
import WardenBarCore
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
        await backend.delayUnlock()
        let unlocking = Task { await store.unlock(masterPassword: "synthetic-master") }
        for _ in 0..<100 {
            if await backend.unlockStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.phase, .unlocking)
        try await render(store, name: "unlocking-narrow", dark: true, width: PopoverWidth.minimum)
        await backend.resumeUnlock()
        await unlocking.value
        try await render(store, name: "list", dark: false)
        try await render(store, name: "list-narrow", dark: false, width: PopoverWidth.minimum)
        try await render(store, name: "list-wide", dark: false, width: PopoverWidth.maximum)
        try await render(store, name: "system-only", dark: true, width: PopoverWidth.minimum, policy: .systemOnly)
        let settings = AutoLockSettingsView(policy: .constant(.idle(minutes: 17)), onClose: {}, onInteract: {})
            .frame(width: 280, height: 420)
            .background(Color(nsColor: .windowBackgroundColor))
        try await renderView(settings, name: "lock-settings", dark: false, width: 280, height: 420)
        store.select("one")
        try await render(store, name: "detail-dark", dark: true)
        store.select(nil)
        await backend.useLongMetadata()
        await store.sync()
        store.folderFilter = .folder("folder")
        try await render(store, name: "long-list", dark: false, width: PopoverWidth.minimum)
        store.folderFilter = .all
        await backend.useMixedRecords()
        await store.sync()
        try await render(store, name: "mixed-narrow", dark: false, width: PopoverWidth.minimum)
        store.typeFilter = .card
        try await render(store, name: "card-filter", dark: true, width: PopoverWidth.minimum)
        store.typeFilter = nil
        for id in ["card", "identity", "note", "ssh"] {
            store.select(id)
            try await render(store, name: "detail-" + id, dark: id == "ssh" || id == "card", width: PopoverWidth.minimum)
        }
        await store.lock().value
    }

    func testFirstRunAndKnownChallengeFormsRenderWithSyntheticData() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for canCopy in [false, true] {
            let actions = TerminalLoginActions(method: .constant(.apiKey), canCopy: canCopy, onCopy: {})
                .padding(16).frame(width: PopoverWidth.minimum, height: 72)
                .background(Color(nsColor: .windowBackgroundColor))
            try await renderView(actions, name: canCopy ? "terminal-copy-enabled" : "terminal-copy-disabled", dark: !canCopy, width: PopoverWidth.minimum, height: 72)
        }
        for challenge: CLILoginChallenge in [.twoFactor, .newDevice, .clientSecret] {
            let board = NSPasteboard(name: .init("WardenBarOnboard-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let backend = ControlledVault()
            await backend.useUnauthenticatedProfile()
            await backend.requireLoginCode(challenge)
            let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board), cliExecutable: URL(fileURLWithPath: "/synthetic/bw"))
            await store.start()
            if challenge == .twoFactor {
                try await render(store, name: "first-run-narrow", dark: false, width: PopoverWidth.minimum)
                try await render(store, name: "first-run-dark", dark: true)
            }
            let signingIn = Task { await store.login(server: .us, email: "synthetic@example.invalid", masterPassword: "synthetic-master", method: .authenticator) }
            for _ in 0..<100 {
                if store.loginChallenge != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(store.loginChallenge, challenge)
            try await render(store, name: "first-run-" + String(describing: challenge), dark: true, width: PopoverWidth.minimum)
            await store.lock().value
            await signingIn.value
        }
    }

    private func render(_ store: VaultStore, name: String, dark: Bool, width: Double = PopoverWidth.defaultValue, policy: AutoLockPolicy = .idle(minutes: 5)) async throws {
        let view = ResizableVaultPopover(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil, savedWidth: .constant(width), lockPolicy: .constant(policy))
        try await renderView(view, name: name, dark: dark, width: width, height: 520)
    }

    private func renderView<V: View>(_ view: V, name: String, dark: Bool, width: Double, height: Double) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
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
