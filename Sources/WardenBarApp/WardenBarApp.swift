import AppKit
import SwiftUI
import WardenBarCore
import WardenBarDesktop

@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()
    let store: VaultStore
    let options: RuntimeOptions
    let configurationIssue: String?
    private var monitor: SecurityMonitor?

    private init() {
        let parsed = try? RuntimeOptions.parse(Array(CommandLine.arguments.dropFirst()))
        options = parsed ?? RuntimeOptions()
        if let parsed, let configuration = try? CLIConfiguration.discover(executable: parsed.cli, dataDirectory: parsed.dataDirectory) {
            store = VaultStore(backend: BitwardenVault(configuration: configuration, readPolicy: .sessionSnapshot), clipboard: ClipboardService())
            configurationIssue = nil
        } else {
            store = VaultStore(backend: nil, clipboard: ClipboardService())
            configurationIssue = parsed == nil ? "启动参数无效，请使用绝对路径指定 CLI 与密码库目录。" : "无法使用 CLI 或密码库目录，请检查本地配置。"
        }
    }

    func start() {
        let store = self.store
        monitor = SecurityMonitor(
            lastActivity: { [weak store] in store?.lastActivity ?? 0 },
            isUnlocked: { [weak store] in store?.phase == .unlocked },
            onLock: { [weak store] in
                // Startup status has no plaintext input or session to revoke.
                if let store, store.phase != .checking { store.lock() }
            }
        )
        monitor?.start()
        Task { await store.start() }
    }

    func stopMonitoring() { monitor?.stop() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppCoordinator.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            let mayQuit = await AppCoordinator.shared.store.prepareToQuit()
            if mayQuit { AppCoordinator.shared.stopMonitoring() }
            else { terminating = false }
            sender.reply(toApplicationShouldTerminate: mayQuit)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct WardenBarApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppCoordinator.shared.store
    @AppStorage("popoverWidth") private var popoverWidth = PopoverWidth.defaultValue

    var body: some Scene {
        MenuBarExtra {
            ResizableVaultPopover(
                store: store, dataDirectory: AppCoordinator.shared.options.dataDirectory,
                configurationIssue: AppCoordinator.shared.configurationIssue, savedWidth: $popoverWidth
            )
        } label: {
            Image(systemName: store.phase == .lockFailed ? "exclamationmark.shield" : (store.phase == .unlocked ? "lock.open" : "lock.shield"))
                .accessibilityLabel("WardenBar")
        }
        .menuBarExtraStyle(.window)
    }
}
