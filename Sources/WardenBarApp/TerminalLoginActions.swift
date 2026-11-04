import SwiftUI
import WardenBarDesktop

/// Keep terminal options compact; native help remains on the enabled wrapper
/// so an unavailable copy button can still explain how to enable it.
struct TerminalLoginActions: View {
    @Binding var method: TerminalLoginMethod
    let canCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("终端登录方式", selection: $method) {
                Text("交互登录").tag(TerminalLoginMethod.standard)
                Text("API Key").tag(TerminalLoginMethod.apiKey)
                Text("SSO").tag(TerminalLoginMethod.sso)
            }.labelsHidden().pickerStyle(.menu).fixedSize()
            ZStack {
                Button("复制登录命令", action: onCopy).disabled(!canCopy)
            }
            .fixedSize()
            .contentShape(Rectangle())
            .help(canCopy ? "复制在终端执行的登录命令" : "请先填写有效的服务器地址")
            Spacer(minLength: 0)
        }
    }
}
