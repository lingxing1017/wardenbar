import SwiftUI
import WardenBarDesktop

@MainActor
struct UnlockView: View {
    @ObservedObject var store: VaultStore
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("密码库已锁定").font(.title2.weight(.semibold))
                Text("输入主密码，访问你的密码库。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                SecureField("主密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($focused)
                    .disabled(store.phase != .locked)
                    .onSubmit(unlock)
                    .accessibilityIdentifier("masterPassword")
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
            }.frame(maxWidth: 280)
            Spacer(minLength: 12)
        }
        .padding(24)
        .onAppear { focused = store.phase == .locked }
        .onDisappear { password = "" }
        .onChange(of: store.generation) { _ in password = "" }
        .onChange(of: store.phase) { phase in if phase == .locked { focused = true } }
    }

    private func unlock() {
        guard store.phase == .locked, !password.isEmpty else { return }
        let input = password
        let generation = store.generation
        password = ""
        Task { await store.unlock(masterPassword: input, expectedGeneration: generation) }
    }
}
