import SwiftUI
import WardenBarDesktop

@MainActor
struct SettingsView: View {
    @ObservedObject var store: VaultStore
    @Binding var policy: AutoLockPolicy
    let focusAutoLock: Bool
    let onClose: () -> Void
    @State private var customMinutes = "5"
    @State private var lastIdleMinutes = 5
    @State private var showsCustomMinutes = false

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHeading(isLocked: store.phase != .unlocked, onClose: onClose)
                    if let quick = store.quickUnlock {
                        QuickUnlockSettingsSection(store: store, quick: quick)
                    } else {
                        Text("解锁方式").font(.headline).foregroundStyle(.primary)
                        Text("解锁密码库后可设置快捷解锁").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }
                    Divider().padding(.top, 20).padding(.bottom, 18)
                    autoLock.disabled(!canEdit).id("autoLock")
                }.padding(16)
            }
            .onAppear {
                if case .idle(let minutes) = policy {
                    customMinutes = String(minutes)
                    lastIdleMinutes = minutes
                    showsCustomMinutes = ![1, 5, 15, 30, 60].contains(minutes)
                }
                if focusAutoLock { reader.scrollTo("autoLock", anchor: .top) }
            }
        }
    }

    private var systemOnly: Binding<Bool> {
        Binding(get: { policy == .systemOnly }, set: { systemOnly in
            guard canEdit else { return }
            policy = systemOnly ? .systemOnly : .idle(minutes: lastIdleMinutes)
            store.userDidInteract()
        })
    }

    private var autoLock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("自动锁定").font(.headline).foregroundStyle(.primary)
            HStack(alignment: .top) {
                Picker("锁定方式", selection: systemOnly) {
                    Text("空闲后锁定").tag(false)
                    Text("仅随系统锁定").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden().fixedSize()
                Spacer(minLength: 4)
                Menu {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { minutes in
                        Button("\(minutes) 分钟") {
                            guard canEdit else { return }
                            policy = .idle(minutes: minutes)
                            customMinutes = String(minutes)
                            lastIdleMinutes = minutes
                            showsCustomMinutes = false
                            store.userDidInteract()
                        }
                    }
                    Button("自定") {
                        guard canEdit else { return }
                        showsCustomMinutes = true
                        store.userDidInteract()
                    }
                } label: {
                    Text("\(effectiveIdleMinutes) 分钟")
                }.menuStyle(.borderedButton).fixedSize().disabled(policy == .systemOnly)
            }
            if showsCustomMinutes, policy != .systemOnly {
                HStack {
                    TextField("分钟", text: $customMinutes)
                        .textFieldStyle(.roundedBorder).frame(width: 64).accessibilityLabel("空闲分钟数")
                        .onChange(of: customMinutes) { value in
                            guard canEdit else { return }
                            if let minutes = Int(value), (1...1440).contains(minutes) {
                                policy = .idle(minutes: minutes)
                                lastIdleMinutes = minutes
                            }
                            store.userDidInteract()
                        }
                    Text("分钟（1–1440）").font(.caption).foregroundStyle(.secondary)
                }
                if Int(customMinutes).map({ !(1...1440).contains($0) }) ?? true {
                    Text("请输入 1–1440 分钟，当前按 \(effectiveIdleMinutes) 分钟锁定")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("锁屏、睡眠或切换用户时也会锁定")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectiveIdleMinutes: Int {
        if case .idle(let minutes) = policy { return minutes }
        return lastIdleMinutes
    }

    private var canEdit: Bool { store.phase == .unlocked && !store.isWorking }
}

@MainActor
struct SettingsHeading: View {
    let isLocked: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("返回密码库")
            Text("设置").font(.title2.weight(.semibold))
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottomLeading) {
            // Reuse the existing gap; the hint never contributes layout height.
            Text("解锁密码库后方可修改")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.bottom, 4)
                .opacity(isLocked ? 1 : 0)
                .accessibilityHidden(!isLocked)
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private struct QuickUnlockSettingsSection: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var quick: QuickUnlockController
    @State private var setup: QuickUnlockSetupKind?
    @State private var error: String?

    private var canConfigure: Bool { store.phase == .unlocked && !store.isWorking && quick.isBound && !quick.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("解锁方式").font(.headline).foregroundStyle(.primary).padding(.bottom, 8)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Touch ID")
                    Text("重启 WardenBar，仍可使用").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Touch ID", isOn: Binding(get: { quick.touchIDEnabled }, set: { enabled in
                    guard canConfigure else { return }
                    store.userDidInteract()
                    if enabled { setup = .touchID }
                    else { do { try quick.disableTouchID() } catch { self.error = error.localizedDescription } }
                }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!canConfigure || (!quick.touchIDEnabled && !quick.touchIDAvailable))
            }.frame(minHeight: 48)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PIN 码")
                    Text(quick.pinConfigured ? "已设置" : "未设置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if quick.pinConfigured {
                    Button("关闭") {
                        guard canConfigure else { return }
                        quick.disablePIN()
                        store.userDidInteract()
                    }
                        .buttonStyle(.bordered).disabled(!canConfigure)
                }
                Button(quick.pinConfigured ? "更改" : "设置") {
                    guard canConfigure else { return }
                    setup = .pin
                    store.userDidInteract()
                }
                    .buttonStyle(.bordered).disabled(!canConfigure)
            }.frame(minHeight: 48)
            Text("重启 WardenBar，需先使用主密码解锁")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if !quick.touchIDAvailable {
                Text("此 Mac 未配置可用的 Touch ID").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.top, 8) }
        }
        .sheet(item: $setup) { kind in
            QuickUnlockSetupView(store: store, quick: quick, kind: kind, onClose: { setup = nil })
        }
        .onChange(of: store.generation) { _ in setup = nil; error = nil }
    }
}
