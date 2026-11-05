import AppKit
import SwiftUI

/// Keep action titles and shortcut presentation identical in every vault phase.
@MainActor
struct VaultActionsMenu: NSViewRepresentable {
    let onLockSettings: () -> Void
    let onOpenDirectory: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.bezelStyle = .inline
        button.setAccessibilityLabel("更多操作")
        let menu = NSMenu()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(title)
        menu.addItem(item("设置", action: #selector(Coordinator.lockSettings), coordinator: context.coordinator))
        menu.addItem(.separator())
        menu.addItem(item("打开密码库目录", action: #selector(Coordinator.openDirectory), coordinator: context.coordinator))
        menu.addItem(.separator())
        let quit = item("退出", action: #selector(Coordinator.quit), coordinator: context.coordinator)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        button.menu = menu
        return button
    }

    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.onLockSettings = onLockSettings
        context.coordinator.onOpenDirectory = onOpenDirectory
        view.isEnabled = context.environment.isEnabled
    }

    private func item(_ title: String, action: Selector, coordinator: Coordinator) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = coordinator
        return item
    }

    @MainActor
    final class Coordinator: NSObject {
        var onLockSettings: (() -> Void)?
        var onOpenDirectory: (() -> Void)?
        @objc func lockSettings() { onLockSettings?() }
        @objc func openDirectory() { onOpenDirectory?() }
        @objc func quit() { NSApp.terminate(nil) }
    }
}
