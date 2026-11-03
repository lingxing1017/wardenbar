import SwiftUI
import WardenBarDesktop

@MainActor
struct AutoLockSettingsView: View {
    @Binding private var policy: AutoLockPolicy
    let onClose: () -> Void
    let onInteract: () -> Void
    @State private var systemOnly: Bool
    @State private var minutes: String
    @FocusState private var minutesFocused: Bool

    init(policy: Binding<AutoLockPolicy>, onClose: @escaping () -> Void, onInteract: @escaping () -> Void) {
        _policy = policy
        self.onClose = onClose
        self.onInteract = onInteract
        _systemOnly = State(initialValue: policy.wrappedValue == .systemOnly)
        if case .idle(let value) = policy.wrappedValue {
            _minutes = State(initialValue: String(value))
        } else { _minutes = State(initialValue: "5") }
    }

    private var validMinutes: Int? {
        guard let value = Int(minutes.trimmingCharacters(in: .whitespaces)), (1...1440).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { onClose() } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Text("自动锁定").font(.title2.weight(.semibold))
            Picker("锁定方式", selection: $systemOnly) {
                Text("空闲后锁定").tag(false)
                Text("仅随系统锁定").tag(true)
            }.pickerStyle(.radioGroup).labelsHidden()
            if !systemOnly {
                HStack {
                    TextField("时长", text: $minutes).textFieldStyle(.roundedBorder)
                        .frame(width: 72).focused($minutesFocused)
                        .accessibilityLabel("空闲分钟数").onSubmit(save)
                    Text("分钟未操作后锁定")
                }
                HStack(spacing: 6) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { value in
                        Button("\(value) 分") { minutes = String(value) }
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                Text("可设置 1–1440 分钟。操作密码库后重新计时。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(systemOnly ? "不使用空闲倒计时。锁屏、睡眠或切换用户时锁定。" : "锁屏、睡眠或切换用户时也会锁定。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("保存", action: save).buttonStyle(.borderedProminent)
                    .disabled(!systemOnly && validMinutes == nil)
            }
        }.padding(16)
        .onAppear { minutesFocused = !systemOnly }
        .onChange(of: minutes) { _ in onInteract() }
        .onChange(of: systemOnly) { value in minutesFocused = !value; onInteract() }
    }

    private func save() {
        if systemOnly { policy = .systemOnly }
        else if let minutes = validMinutes { policy = .idle(minutes: minutes) }
        else { return }
        onClose()
    }
}
