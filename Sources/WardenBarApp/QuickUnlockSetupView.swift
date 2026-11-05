import SwiftUI
import WardenBarDesktop

enum QuickUnlockSetupKind: String, Identifiable { case pin, touchID; var id: String { rawValue } }

@MainActor
struct QuickUnlockSetupView: View {
    @ObservedObject var store: VaultStore
    @ObservedObject var quick: QuickUnlockController
    let kind: QuickUnlockSetupKind
    let onClose: () -> Void
    @State private var password = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focus: Field?
    private enum Field { case password, pin, confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .pin ? "设置 PIN 码" : "启用 Touch ID").font(.title2.weight(.semibold))
            Text("请验证主密码").foregroundStyle(.secondary)
            SecureField("主密码", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .onSubmit { if kind == .pin { focus = .pin } else { submit() } }
                .padding(9).background(AccountInputBackground(isFocused: focus == .password))
            if kind == .pin {
                SecureField("6 位数字 PIN 码", text: $pin).focused($focus, equals: .pin)
                    .onSubmit { focus = .confirmation }
                    .padding(9).background(AccountInputBackground(isFocused: focus == .pin))
                SecureField("再次输入 PIN 码", text: $confirmation).focused($focus, equals: .confirmation)
                    .onSubmit(submit)
                    .padding(9).background(AccountInputBackground(isFocused: focus == .confirmation))
            } else {
                Text("主密码将保存在本机受 Touch ID 保护的钥匙串中")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { quick.cancelPendingAuthentication(); clear(); onClose() }.keyboardShortcut(.cancelAction)
                Button(kind == .pin ? "确认" : "启用", action: submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working || (kind == .pin && (pin.isEmpty || confirmation.isEmpty)))
            }
        }
        .textFieldStyle(.plain).padding(20).frame(width: 300)
        .onAppear { focus = .password }
        .onDisappear { quick.cancelPendingAuthentication(); clear() }
        .onChange(of: store.generation) { _ in quick.revokeAuthorization(); clear(); onClose() }
    }

    private func clear() { password = ""; pin = ""; confirmation = "" }
    private func submit() {
        guard store.phase == .unlocked, !store.isWorking, !working, !password.isEmpty else { return }
        guard kind != .pin || pin == confirmation else { error = "两次输入的 PIN 码不一致"; return }
        let password = self.password, pin = self.pin, generation = store.generation
        clear()
        error = nil
        working = true
        store.userDidInteract()
        Task {
            do {
                if kind == .pin { try quick.configurePIN(pin, password: password) }
                else { try await quick.enableTouchID(password: password) }
                guard store.generation == generation, store.phase == .unlocked else { return }
                working = false
                onClose()
            } catch {
                guard store.generation == generation, store.phase == .unlocked else { return }
                working = false
                self.error = (error as? QuickUnlockError)?.errorDescription ?? "验证未完成，请重试或取消"
                focus = .password
            }
        }
    }
}
