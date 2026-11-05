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
private final class LoginModePreference: ObservableObject {
    @Published var mode = AccountLoginMode.app
    @Published var server = AccountServerSelection(choice: .custom, customAddress: "")
}

@MainActor
private struct LoginModeHarness: View {
    @ObservedObject var preference: LoginModePreference
    let store: VaultStore
    var body: some View {
        AccountSetupView(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), mode: $preference.mode, serverSelection: $preference.server)
            .frame(width: 280, height: 424)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class NativeRenderTests: XCTestCase {
    func testSettingsHintUsesExistingHeaderSpaceWithoutLayoutChanges() async throws {
        let baseline = NSHostingView(rootView: HStack(spacing: 8) {
            Button {} label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            Text("设置").font(.title2.weight(.semibold))
        }.padding(.bottom, 24).frame(width: 280, alignment: .leading))
        baseline.layoutSubtreeIfNeeded()
        for locked in [false, true] {
            let heading = SettingsHeading(isLocked: locked, onClose: {})
                .frame(width: 280, alignment: .leading)
            let host = NSHostingView(rootView: heading)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, baseline.fittingSize.height, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.width, baseline.fittingSize.width, accuracy: 0.5)
            try await renderView(heading, name: locked ? "settings-heading-locked" : "settings-heading-unlocked", dark: true, width: 280, height: baseline.fittingSize.height)
        }
    }

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
        let settings = SettingsView(store: store, policy: .constant(.idle(minutes: 17)), focusAutoLock: false, onClose: {})
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

    func testQuickUnlockSettingsRenderAtNarrowWidths() async throws {
        let board = NSPasteboard(name: .init("WardenBarQuickRender-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let quick = QuickUnlockController(defaults: UserDefaults(suiteName: "QuickRender-" + UUID().uuidString)!, credentials: MemoryBiometricCredentials(), profile: "synthetic")
        let store = VaultStore(backend: ControlledVault(), clipboard: ClipboardService(pasteboard: board), quickUnlock: quick)
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        try quick.configurePIN("123456", password: "synthetic-master")
        try await quick.enableTouchID(password: "synthetic-master")
        for width in [280.0, 312.0] {
            let view = SettingsView(store: store, policy: .constant(.systemOnly), focusAutoLock: false, onClose: {})
                .frame(width: width, height: 424).background(Color(nsColor: .windowBackgroundColor))
            try await renderView(view, name: "settings-\(Int(width))", dark: true, width: width, height: 424)
        }
        let setup = QuickUnlockSetupView(store: store, quick: quick, kind: .pin, onClose: {})
        try await renderView(setup, name: "pin-setup", dark: false, width: 300, height: 340)
        await store.lock().value
        let lockedSettings = SettingsView(store: store, policy: .constant(.systemOnly), focusAutoLock: false, onClose: {})
            .frame(width: 312, height: 424).background(Color(nsColor: .windowBackgroundColor))
        try await renderView(lockedSettings, name: "settings-locked-312", dark: true, width: 312, height: 424)
        try await render(store, name: "quick-unlock", dark: true, width: 312)
    }

    func testInvalidCustomMinutesKeepTheDisplayedEffectivePolicy() async throws {
        let board = NSPasteboard(name: .init("SettingsValidation-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: ControlledVault(), clipboard: ClipboardService(pasteboard: board))
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let preferences = AutoLockPreferences(defaults: UserDefaults(suiteName: "SettingsValidation-" + UUID().uuidString)!)
        preferences.policy = .idle(minutes: 17)
        let view = SettingsView(store: store, policy: Binding(get: { preferences.policy }, set: { preferences.policy = $0 }), focusAutoLock: false, onClose: {})
        let host = NSHostingView(rootView: view.frame(width: 312, height: 424))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 312, height: 424), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let field = try XCTUnwrap(all(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "分钟" })
        func accessibilityStrings(_ node: NSObject, depth: Int = 0) -> [String] {
            guard depth < 20 else { return [] }
            var values: [String] = []
            for key in ["accessibilityLabel", "accessibilityValue"] where node.responds(to: NSSelectorFromString(key)) {
                if let value = node.value(forKey: key) as? String { values.append(value) }
            }
            if node.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = node.value(forKey: "accessibilityChildren") as? [NSObject] {
                values += children.flatMap { accessibilityStrings($0, depth: depth + 1) }
            }
            return values
        }
        for invalid in ["0", "", "1441"] {
            field.stringValue = invalid
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(preferences.policy, .idle(minutes: 17))
            XCTAssertTrue(accessibilityStrings(host).contains("17 分钟"), "Displayed policy must match the effective 17-minute policy")
        }
        field.stringValue = "19"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(preferences.policy, .idle(minutes: 19))
        await store.lock().value
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(field.isEnabled, "Settings remain visible but become read-only when locked")
        field.stringValue = "30"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(preferences.policy, .idle(minutes: 19), "A late edit after locking must not persist")
    }

    func testFirstRunAndKnownChallengeFormsRenderWithSyntheticData() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let explanations = [false, true].map { valid in
            NSHostingView(rootView: TerminalLoginExplanation(serverIsValid: valid).frame(width: PopoverWidth.minimum - 32))
        }
        for view in explanations { view.layoutSubtreeIfNeeded() }
        XCTAssertGreaterThan(explanations[0].fittingSize.height, 0)
        XCTAssertEqual(explanations[0].fittingSize.height, explanations[1].fittingSize.height, accuracy: 0.5)
        for canCopy in [false, true] {
            let actions = VStack(alignment: .leading, spacing: 10) {
                TerminalLoginExplanation(serverIsValid: canCopy)
                TerminalLoginActions(method: .constant(.apiKey), canCopy: canCopy, onCopy: {})
            }
                .padding(16).frame(width: PopoverWidth.minimum, height: 120)
                .background(Color(nsColor: .windowBackgroundColor))
            try await renderView(actions, name: canCopy ? "terminal-copy-enabled" : "terminal-copy-disabled", dark: !canCopy, width: PopoverWidth.minimum, height: 120)
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

    func testLoginModeSwitchRetainsEmailAndClearsMasterPassword() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let board = NSPasteboard(name: .init("WardenBarLoginModes-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let backend = ControlledVault()
        await backend.useUnauthenticatedProfile()
        let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board), cliExecutable: URL(fileURLWithPath: "/synthetic/bw"))
        await store.start()
        let preference = LoginModePreference()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 424), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: LoginModeHarness(preference: preference, store: store).environment(\.colorScheme, .dark))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 424)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func fields() -> [NSTextField] { all(host).compactMap { $0 as? NSTextField } }
        let modeControl = try XCTUnwrap(all(host).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(modeControl.bounds.width, 248, accuracy: 0.5)
        XCTAssertEqual(modeControl.segmentDistribution, .fillEqually)
        let bezel = try XCTUnwrap(modeControl.selectedSegmentBezelColor?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(bezel.redComponent, bezel.greenComponent, accuracy: 0.001)
        XCTAssertEqual(bezel.greenComponent, bezel.blueComponent, accuracy: 0.001)
        modeControl.selectedSegment = 1
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        try capture(host, name: "login-mode-invalid-server")
        modeControl.selectedSegment = 0
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let address = try XCTUnwrap(fields().first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "https://vault.example.com" })
        address.stringValue = "https://vault.example.com"
        address.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: address))
        let addressY = address.convert(address.bounds, to: host).minY
        for choice: AccountServerSelection.Choice in [.us, .eu] {
            preference.server.choice = choice
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let official = try XCTUnwrap(fields().first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "https://vault.example.com" })
            XCTAssertFalse(official.isEnabled)
            XCTAssertEqual(official.stringValue, preference.server.server?.url.absoluteString)
            XCTAssertEqual(official.convert(official.bounds, to: host).minY, addressY, accuracy: 0.5)
        }
        preference.server.choice = .custom
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let custom = try XCTUnwrap(fields().first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "https://vault.example.com" })
        XCTAssertTrue(custom.isEnabled)
        XCTAssertEqual(custom.stringValue, "https://vault.example.com")
        XCTAssertEqual(custom.convert(custom.bounds, to: host).minY, addressY, accuracy: 0.5)
        let email = try XCTUnwrap(fields().first { $0.placeholderString == "电子邮箱" })
        let password = try XCTUnwrap(fields().first { $0.placeholderString == "主密码" })
        email.stringValue = "synthetic@example.invalid"
        email.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: email))
        password.stringValue = "synthetic-master"
        password.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: password))
        modeControl.selectedSegment = 1
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(fields().contains { $0.placeholderString == "主密码" })
        XCTAssertEqual(fields().first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "https://vault.example.com" }?.stringValue, "https://vault.example.com")
        try capture(host, name: "login-mode-terminal")
        await store.checkLogin()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        try capture(host, name: "login-mode-terminal-result")
        modeControl.selectedSegment = 0
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(fields().first { $0.placeholderString == "电子邮箱" }?.stringValue, "synthetic@example.invalid")
        XCTAssertEqual(fields().first { $0.placeholderString == "主密码" }?.stringValue, "")
        XCTAssertEqual(fields().first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "https://vault.example.com" }?.stringValue, "https://vault.example.com")
        try capture(host, name: "login-mode-app")
        XCTAssertNil(store.loginCheckMessage)
    }

    private func render(_ store: VaultStore, name: String, dark: Bool, width: Double = PopoverWidth.defaultValue, policy: AutoLockPolicy = .idle(minutes: 5)) async throws {
        let view = ResizableVaultPopover(store: store, dataDirectory: URL(fileURLWithPath: "/synthetic/CLI"), configurationIssue: nil, savedWidth: .constant(width), lockPolicy: .constant(policy))
        try await renderView(view, name: name, dark: dark, width: width, height: 520, expectsActionsMenu: true)
    }

    private func renderView<V: View>(_ view: V, name: String, dark: Bool, width: Double, height: Double, expectsActionsMenu: Bool = false) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, CGFloat(width), accuracy: 0.5)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        if expectsActionsMenu {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            let actions = try XCTUnwrap(all(host).compactMap { $0 as? NSPopUpButton }
                .first { $0.menu?.items.contains(where: { $0.title == "打开密码库目录" }) == true })
            let quit = try XCTUnwrap(actions.menu?.items.first { $0.title == "退出" })
            let settings = try XCTUnwrap(actions.menu?.items.first { $0.title == "设置" })
            XCTAssertNil(settings.submenu)
            XCTAssertEqual(quit.keyEquivalent, "q")
            XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
            XCTAssertTrue(quit.isEnabled)
        }
        try capture(host, name: name)
        window.orderOut(nil)
    }

    private func capture(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = appRoot.appendingPathComponent(".build/visual-check", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
}
