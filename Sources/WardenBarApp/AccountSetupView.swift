import SwiftUI
import WardenBarCore
import WardenBarDesktop

enum AccountLoginMode: String, CaseIterable {
    case app = "应用内登录", terminal = "终端登录"
}

struct AccountServerSelection {
    enum Choice: String, CaseIterable {
        case us = "Bitwarden 美国", eu = "Bitwarden 欧洲", custom = "自托管"
    }
    var choice = Choice.us
    var customAddress = ""
    var server: VaultServer? {
        switch choice {
        case .us: return .us
        case .eu: return .eu
        case .custom: return try? VaultServer(address: customAddress)
        }
    }
}

@MainActor
struct AccountSetupView: View {
    @ObservedObject var store: VaultStore
    let dataDirectory: URL
    @Binding var mode: AccountLoginMode
    @Binding var serverSelection: AccountServerSelection
    @State private var email = ""
    @State private var password = ""
    @State private var response = ""
    @State private var method = CLITwoFactorMethod.authenticator
    @State private var terminalMethod = TerminalLoginMethod.standard
    @FocusState private var focus: Field?
    private enum Field { case email, password, response, server }
    private var server: VaultServer? { serverSelection.server }
    private var signingIn: Bool { store.phase == .signingIn }
    private var canConnect: Bool { mode == .app && server != nil && email.contains("@") && !password.isEmpty && !store.isWorking }
    private var terminalCommand: String? {
        guard let executable = store.cliExecutable, let server else { return nil }
        return TerminalLoginCommand.make(executable: executable, dataDirectory: dataDirectory, server: server, method: terminalMethod)
    }
    private var canCheckLogin: Bool { terminalCommand != nil && !store.isWorking }
    private var serverAddress: Binding<String> {
        Binding(
            get: { serverSelection.choice == .custom ? serverSelection.customAddress : (server?.url.absoluteString ?? "") },
            set: { if serverSelection.choice == .custom { serverSelection.customAddress = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("连接密码库").font(.title2.weight(.semibold))
                if signingIn {
                    Text("完成验证后，即可打开密码库。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LoginModeSwitch(selection: $mode)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .disabled(store.isWorking)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if signingIn { loginProgress }
                    else {
                        serverFields
                        if mode == .app { credentials }
                        else { terminalFields }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.id(mode).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !signingIn { primaryAction }
        }
        .onAppear { focus = mode == .app ? .email : nil }
        .onChange(of: mode) { value in
            password = ""
            response = ""
            store.dismissLoginCheckMessage()
            focus = value == .app ? .email : nil
        }
        .onChange(of: serverSelection.choice) { choice in
            store.dismissLoginCheckMessage()
            focus = choice == .custom ? .server : nil
        }
        .onChange(of: serverSelection.customAddress) { _ in store.dismissLoginCheckMessage() }
        .onChange(of: terminalMethod) { _ in store.dismissLoginCheckMessage() }
        .onChange(of: store.loginChallenge) { challenge in
            response = ""
            focus = challenge == nil ? nil : .response
        }
        .onChange(of: store.generation) { _ in password = ""; response = "" }
        .onDisappear { password = ""; response = "" }
    }

    private var primaryAction: some View {
        VStack(spacing: 8) {
            LoginCheckFeedback(message: mode == .terminal ? store.loginCheckMessage : nil)
            Button {
                if mode == .app { connect() }
                else { checkLogin() }
            } label: {
                HStack(spacing: 8) {
                    if store.isWorking { ProgressView().controlSize(.small) }
                    Text(mode == .app ? "连接账号" : "检查登录")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(mode == .app ? !canConnect : !canCheckLogin)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("accountPrimaryAction")
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var serverFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("服务器").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                TextField("", text: serverAddress, prompt: Text(verbatim: "https://vault.example.com"))
                    .textFieldStyle(.plain).focused($focus, equals: .server)
                    .accessibilityLabel(serverSelection.choice == .custom ? "自托管服务器地址" : "服务器地址，只读")
                    .disabled(serverSelection.choice != .custom)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 8)
                Menu {
                    Picker("服务器", selection: $serverSelection.choice) {
                        ForEach(AccountServerSelection.Choice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.inline)
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 26)
                    .accessibilityLabel("选择服务器")
                    .help("选择 Bitwarden 区域或自托管服务器")
            }
            .frame(height: 26)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
            if serverSelection.choice == .custom && !serverSelection.customAddress.isEmpty && server == nil {
                Text("请输入 HTTPS 地址，不包含账号、查询参数或片段。")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(store.isWorking)
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("电子邮箱").font(.caption).foregroundStyle(.secondary)
                TextField("电子邮箱", text: $email).textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("主密码").font(.caption).foregroundStyle(.secondary)
                SecureField("主密码", text: $password).textFieldStyle(.roundedBorder)
                    .textContentType(.password).focused($focus, equals: .password).onSubmit(connect)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("两步验证方式（若已启用）").font(.caption).foregroundStyle(.secondary)
                Picker("两步验证方式", selection: $method) {
                    Text("身份验证器").tag(CLITwoFactorMethod.authenticator)
                    Text("电子邮箱").tag(CLITwoFactorMethod.email)
                    Text("YubiKey OTP").tag(CLITwoFactorMethod.yubikey)
                }.labelsHidden().pickerStyle(.menu)
            }
        }.disabled(store.isWorking)
    }

    private var loginProgress: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let challenge = store.loginChallenge {
                VStack(alignment: .leading, spacing: 8) {
                    Text(challengeTitle(challenge)).font(.headline)
                    Text(challengeHelp(challenge)).font(.callout).foregroundStyle(.secondary)
                    SecureField(challenge == .clientSecret ? "client_secret" : "验证码", text: $response)
                        .textFieldStyle(.roundedBorder).focused($focus, equals: .response)
                        .textContentType(challenge == .clientSecret ? .password : .oneTimeCode)
                        .onSubmit(submitResponse)
                    Button("继续验证", action: submitResponse).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(response.isEmpty)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.activityMessage ?? "正在连接账号…").foregroundStyle(.secondary)
                }
            }
            Button("取消登录") { store.lock() }.buttonStyle(.bordered)
        }
    }

    private var terminalFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TerminalLoginExplanation(serverIsValid: server != nil)
            TerminalLoginActions(method: $terminalMethod, canCopy: terminalCommand != nil) {
                if let command = terminalCommand { store.copyLoginCommand(command) }
            }
            Text("命令使用本应用的独立目录。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(store.isWorking)
    }

    private func checkLogin() {
        guard mode == .terminal, canCheckLogin else { return }
        let generation = store.generation
        Task {
            guard mode == .terminal else { return }
            await store.checkLogin(expectedGeneration: generation)
        }
    }

    private func challengeTitle(_ challenge: CLILoginChallenge) -> String {
        switch challenge {
        case .twoFactor: return "两步验证"
        case .newDevice: return "验证新设备"
        case .clientSecret: return "额外身份验证"
        }
    }
    private func challengeHelp(_ challenge: CLILoginChallenge) -> String {
        switch challenge {
        case .twoFactor: return "输入账号要求的动态验证码、邮件验证码或 YubiKey OTP。"
        case .newDevice: return "输入发送到登录邮箱的新设备验证码。"
        case .clientSecret: return "服务器要求个人 API Key 的 client_secret。也可以取消后使用终端登录。"
        }
    }
    private func connect() {
        guard canConnect, let server else { return }
        let master = password
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedMethod = method
        let generation = store.generation
        password = ""
        Task {
            guard mode == .app else { return }
            await store.login(server: server, email: address, masterPassword: master, method: selectedMethod, expectedGeneration: generation)
        }
    }
    private func submitResponse() {
        let value = response
        response = ""
        store.submitLoginResponse(value)
    }
}
