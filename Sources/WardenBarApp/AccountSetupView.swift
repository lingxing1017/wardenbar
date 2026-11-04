import SwiftUI
import WardenBarCore
import WardenBarDesktop

@MainActor
struct AccountSetupView: View {
    @ObservedObject var store: VaultStore
    let dataDirectory: URL
    @State private var serverChoice = ServerChoice.us
    @State private var customServer = ""
    @State private var email = ""
    @State private var password = ""
    @State private var response = ""
    @State private var method = CLITwoFactorMethod.authenticator
    @State private var terminalMethod = TerminalLoginMethod.standard
    @FocusState private var focus: Field?
    private enum Field { case email, password, response, server }
    private enum ServerChoice: String, CaseIterable {
        case us = "Bitwarden 美国", eu = "Bitwarden 欧洲", custom = "自托管"
    }
    private var server: VaultServer? {
        switch serverChoice {
        case .us: return .us
        case .eu: return .eu
        case .custom: return try? VaultServer(address: customServer)
        }
    }
    private var signingIn: Bool { store.phase == .signingIn }
    private var canConnect: Bool { server != nil && email.contains("@") && !password.isEmpty && !store.isWorking }
    private var terminalCommand: String? {
        guard let executable = store.cliExecutable, let server else { return nil }
        return TerminalLoginCommand.make(executable: executable, dataDirectory: dataDirectory, server: server, method: terminalMethod)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接密码库").font(.title2.weight(.semibold))
                    Text(signingIn ? "完成验证后，即可打开密码库。" : "登录现有账号，以后启动只需解锁。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if signingIn { loginProgress }
                else {
                    credentials
                    Button(action: connect) {
                        HStack(spacing: 8) {
                            if store.isWorking { ProgressView().controlSize(.small) }
                            Text("连接账号")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!canConnect)
                        .keyboardShortcut(.defaultAction)
                    if store.cliExecutable != nil {
                        Divider()
                        terminalFallback
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .onAppear { focus = .email }
        .onChange(of: serverChoice) { choice in if choice == .custom { focus = .server } }
        .onChange(of: store.loginChallenge) { challenge in
            response = ""
            focus = challenge == nil ? nil : .response
        }
        .onChange(of: store.generation) { _ in password = ""; response = "" }
        .onDisappear { password = ""; response = "" }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("服务器").font(.caption).foregroundStyle(.secondary)
                Picker("服务器", selection: $serverChoice) {
                    ForEach(ServerChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
                if serverChoice == .custom {
                    TextField("https://vault.example.com", text: $customServer)
                        .textFieldStyle(.roundedBorder).focused($focus, equals: .server)
                        .accessibilityLabel("自托管服务器地址")
                    if !customServer.isEmpty && server == nil {
                        Text("请输入 HTTPS 地址，不包含账号、查询参数或片段。")
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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

    private var terminalFallback: some View {
        DisclosureGroup("其他登录方式（终端）") {
            VStack(alignment: .leading, spacing: 10) {
                TerminalLoginExplanation(serverIsValid: server != nil)
                TerminalLoginActions(method: $terminalMethod, canCopy: terminalCommand != nil) {
                    if let command = terminalCommand { store.copyLoginCommand(command) }
                }
                Button("已完成，检查登录状态") { Task { await store.start() } }
                Text("使用本应用的独立目录，不会复用终端默认的账号资料。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.disabled(store.isWorking)
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
        Task { await store.login(server: server, email: address, masterPassword: master, method: selectedMethod, expectedGeneration: generation) }
    }
    private func submitResponse() {
        let value = response
        response = ""
        store.submitLoginResponse(value)
    }
}
