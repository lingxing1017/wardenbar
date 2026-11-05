import SwiftUI
import WardenBarDesktop

@MainActor
struct UnlockView: View {
    @ObservedObject var store: VaultStore
    @State private var password = ""
    @State private var usesPIN = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            Group {
                if let image = PasswordCoverArtwork.lockedHero {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(nsImage: PasswordCoverArtwork.header).resizable().scaledToFit()
                }
            }
            .frame(width: 112, height: 42)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("密码库已锁定").font(.title2.weight(.semibold))
                Text(usesPIN ? "输入 PIN 码，访问你的密码库。" : "输入主密码，访问你的密码库。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                SecureField(usesPIN ? "6 位 PIN 码" : "主密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($focused)
                    .disabled(store.phase != .locked)
                    .onSubmit(unlock)
                    .accessibilityIdentifier(usesPIN ? "unlockPIN" : "masterPassword")
                    .id(usesPIN)
                Button(action: unlock) {
                    HStack(spacing: 8) {
                        if store.phase == .unlocking { ProgressView().controlSize(.small) }
                        Text(store.phase == .unlocking ? "正在解锁…" : "解锁密码库")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || store.phase != .locked)
                if let quick = store.quickUnlock {
                    QuickUnlockAlternatives(store: store, quick: quick, usesPIN: $usesPIN)
                }
            }.frame(maxWidth: 280)
            Spacer(minLength: 12)
        }
        .padding(24)
        .onAppear { focused = store.phase == .locked; usesPIN = store.quickUnlock?.pinReady == true }
        .onDisappear { password = "" }
        .onChange(of: store.generation) { _ in password = "" }
        .onChange(of: usesPIN) { _ in password = ""; focused = true }
        .onChange(of: store.phase) { phase in if phase == .locked { focused = true } }
    }

    private func unlock() {
        guard store.phase == .locked, !password.isEmpty else { return }
        let input = password
        let generation = store.generation
        password = ""
        let pin = usesPIN
        Task {
            if pin { await store.unlockWithPIN(input, expectedGeneration: generation) }
            else { await store.unlock(masterPassword: input, expectedGeneration: generation) }
        }
    }
}

@MainActor
private struct QuickUnlockAlternatives: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var quick: QuickUnlockController
    @Binding var usesPIN: Bool

    var body: some View {
        VStack(spacing: 10) {
            if quick.touchIDEnabled, quick.touchIDAvailable {
                Button {
                    let generation = store.generation
                    Task { await store.unlockWithTouchID(expectedGeneration: generation) }
                } label: {
                    Label("使用 Touch ID", systemImage: "touchid").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large).disabled(store.phase != .locked)
            }
            if usesPIN || quick.pinReady {
                Button(usesPIN ? "使用主密码" : "使用 PIN 码") { usesPIN.toggle(); store.userDidInteract() }
                    .buttonStyle(.borderless).disabled(store.phase != .locked)
            } else if quick.pinConfigured {
                Text("本次启动需先使用主密码，才能使用 PIN 码")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.phase == .unlocking, quick.isBusy {
                Button("取消验证") { store.lock() }.buttonStyle(.borderless)
            }
        }
        .onChange(of: quick.pinReady) { ready in if !ready { usesPIN = false } }
    }
}
