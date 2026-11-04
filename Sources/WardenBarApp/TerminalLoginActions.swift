import SwiftUI
import WardenBarDesktop

struct TerminalLoginExplanation: View {
    let serverIsValid: Bool
    private let explanation = "特殊认证可在终端完成，之后回来检查登录状态。"

    var body: some View {
        // Measure the longer explanation even when showing the shorter validation hint.
        // This also preserves the height when the explanation wraps in a narrow window.
        Text(explanation)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .topLeading) {
                Text(serverIsValid ? explanation : "请先填写有效的服务器地址")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout).foregroundStyle(.secondary)
    }
}

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
