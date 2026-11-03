import AppKit
import SwiftUI
import WardenBarDesktop
import WardenBarCore

@MainActor
struct VaultPopoverView: View {
    @ObservedObject var store: VaultStore
    let dataDirectory: URL
    let configurationIssue: String?
    @Binding var lockPolicy: AutoLockPolicy
    @State private var showsLockSettings = false

    init(store: VaultStore, dataDirectory: URL, configurationIssue: String?, lockPolicy: Binding<AutoLockPolicy> = .constant(.idle(minutes: 5))) {
        self.store = store
        self.dataDirectory = dataDirectory
        self.configurationIssue = configurationIssue
        _lockPolicy = lockPolicy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = configurationIssue ?? store.errorMessage { errorBanner(error) }
            Group {
                if showsLockSettings {
                    AutoLockSettingsView(policy: $lockPolicy, onClose: { showsLockSettings = false; store.userDidInteract() }, onInteract: { store.userDidInteract() })
                } else {
                    switch store.phase {
                    case .checking: progress("正在检查密码库…")
                    case .locked, .unlocking: UnlockView(store: store)
                    case .locking: progress("本地访问已阻止，正在锁定后端…")
                    case .lockFailed:
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.shield").font(.largeTitle).foregroundStyle(.secondary)
                            Text("访问已阻止").font(.title2.weight(.semibold))
                            Text("后端锁定尚未完成，请重试。").foregroundStyle(.secondary)
                            Button("重试锁定") { store.lock() }.buttonStyle(.borderedProminent)
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .setup: setup
                    case .unlocked:
                        ZStack {
                            // Keep the native list and its exact scroll offset alive during details.
                            // Leaving the unlocked phase still removes this entire subtree.
                            VaultListView(store: store)
                                .opacity(store.selectedItem == nil ? 1 : 0)
                                .allowsHitTesting(store.selectedItem == nil)
                                .accessibilityHidden(store.selectedItem != nil)
                                .disabled(store.selectedItem != nil)
                            if let item = store.selectedItem {
                                ItemDetailView(store: store, item: item)
                                    .id("\(store.generation):\(store.indexRevision):\(item.id)")
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear { store.userDidInteract() }
        .onExitCommand {
            if showsLockSettings { showsLockSettings = false; store.userDidInteract() }
            else { NSApp.keyWindow?.orderOut(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.tint).accessibilityHidden(true)
            Text("WardenBar").font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 8) {
                if store.isWorking || store.isRefreshingFolders { ProgressView().controlSize(.small).accessibilityLabel("正在处理") }
                Button {
                    let generation = store.generation
                    Task { await store.sync(expectedGeneration: generation) }
                } label: { Label("同步密码库", systemImage: "arrow.triangle.2.circlepath") }
                    .labelStyle(.iconOnly).help("同步密码库")
                    .disabled(store.phase != .unlocked || store.isWorking || store.isRefreshingFolders)
                Button { store.lock() } label: { Label("锁定密码库", systemImage: "lock") }
                    .labelStyle(.iconOnly).help("锁定密码库")
                    .disabled(![.unlocked, .unlocking, .lockFailed].contains(store.phase))
                Menu {
                    Button("自动锁定…") { showsLockSettings = true; store.userDidInteract() }
                    Divider()
                    Button("打开密码库目录") { NSWorkspace.shared.open(dataDirectory) }
                    Divider()
                    Button("退出 WardenBar") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("更多操作") }
                .menuStyle(.borderlessButton).fixedSize()
            }.modifier(NativeToolbarSurface())
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(height: 48)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red).accessibilityHidden(true)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if store.phase != .lockFailed && configurationIssue == nil {
                Button { store.dismissError() } label: { Label("关闭提示", systemImage: "xmark") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private var setup: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
            Text("连接密码库").font(.title2.weight(.semibold))
            Text(configurationIssue == nil ? "先为独立目录完成 CLI 登录，之后即可在这里解锁。" : "修复本地配置后，请重新打开应用。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(dataDirectory.path).font(.caption).textSelection(.enabled).multilineTextAlignment(.center)
            if configurationIssue == nil {
                Button("重新检查") { Task { await store.start() } }.buttonStyle(.borderedProminent)
            } else {
                Button("退出应用") { NSApp.terminate(nil) }.buttonStyle(.borderedProminent)
            }
            Button("打开目录") { NSWorkspace.shared.open(dataDirectory) }.buttonStyle(.borderless)
        }.padding(28).frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 3) {
            if let activity = store.activityMessage { Text(activity).foregroundStyle(.primary) }
            else if let notice = store.notice { Text(notice).foregroundStyle(.primary) }
            else if store.phase == .unlocked {
                Text(store.lastSync.map { "已同步 " + $0.formatted(date: .omitted, time: .shortened) } ?? "本地密码库 · \(store.items.count) 条记录")
            } else { Text(store.phase == .lockFailed ? "后端锁定待重试" : "密码库访问受保护") }
            HStack(spacing: 4) {
                if store.phase == .unlocked {
                    Button { showsLockSettings = true; store.userDidInteract() } label: {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let seconds = store.secondsUntilLock(policy: lockPolicy) {
                                Text(String(format: "锁定 %02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                            } else { Text("随系统锁定") }
                        }
                    }.buttonStyle(.borderless).help("修改自动锁定设置")
                    Text("·")
                }
                Text("剪贴板 30 秒清理")
            }
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 9)
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 12) { ProgressView(); Text(message).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct VaultListView: View {
    @ObservedObject var store: VaultStore
    @State private var cursorID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索名称或条目信息", text: $store.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { store.select(cursorID ?? store.filteredItems.first?.id) }
                        .accessibilityIdentifier("vaultSearch")
                }.padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 8) {
                    Picker("文件夹", selection: $store.folderFilter) {
                        Text("全部文件夹").tag(FolderFilter.all)
                        Text("未分类").tag(FolderFilter.unfiled)
                        ForEach(store.folders) { folder in
                            Text(folder.name).lineLimit(1).truncationMode(.middle).tag(FolderFilter.folder(folder.id))
                        }
                    }.labelsHidden().pickerStyle(.menu)
                        .frame(maxWidth: 140, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("文件夹")
                    Picker("类型", selection: $store.typeFilter) {
                        Text("全部类型").tag(Optional<VaultItemType>.none)
                        ForEach(VaultItemType.displayOrder) { type in
                            Text(type.title).tag(Optional(type))
                        }
                    }.labelsHidden().pickerStyle(.menu)
                        .frame(maxWidth: 100, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("类型")
                    Spacer(minLength: 0)
                }
            }.padding(12)
            if store.isWorking && store.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(store.activityMessage ?? "正在读取记录…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(store.items.isEmpty ? "没有可显示的记录" : "未找到匹配项").font(.headline)
                    Text(store.items.isEmpty ? "支持个人登录、支付卡、身份、笔记和 SSH 密钥。" : "试试其他类型、文件夹或搜索词。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $cursorID) {
                    ForEach(store.filteredItems) { item in
                        HStack(spacing: 6) {
                            Button { store.select(item.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.type.symbol)
                                        .foregroundStyle(.secondary).frame(width: 18).accessibilityLabel(item.type.title)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                        Text(item.subtitle?.isEmpty == false ? item.subtitle! : (item.username ?? item.uris.first ?? item.type.title))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if item.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("已收藏") }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(store.isWorking)
                            HStack(spacing: 2) {
                                if item.type == .login {
                                    Button { store.copyUsername(for: item.id) } label: {
                                        Label("复制用户名", systemImage: "person")
                                            .frame(width: 26, height: 28).contentShape(Rectangle())
                                    }.disabled(store.isWorking || item.username?.isEmpty != false).help("复制用户名")
                                    Button { copyPassword(item.id) } label: {
                                        Label("复制密码", systemImage: "key.horizontal")
                                            .frame(width: 26, height: 28).contentShape(Rectangle())
                                    }.disabled(store.isWorking || !item.hasPassword).help("复制密码")
                                    Button { copyTOTP(item.id) } label: {
                                        Label("复制动态验证码", systemImage: "clock")
                                            .frame(width: 26, height: 28).contentShape(Rectangle())
                                    }.disabled(store.isWorking || !item.hasTOTP).help(item.hasTOTP ? "复制动态验证码" : "未配置动态验证码")
                                } else if item.primaryCopyField != nil {
                                    Button { copyPrimary(item) } label: {
                                        Label(item.type.copyLabel, systemImage: "doc.on.doc")
                                            .frame(width: 26, height: 28).contentShape(Rectangle())
                                    }.disabled(store.isWorking).help(item.type.copyLabel)
                                }
                            }.labelStyle(.iconOnly).buttonStyle(.borderless).fixedSize()
                        }.padding(.vertical, 7).tag(item.id)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
                HStack {
                    Text("\(store.filteredItems.count) 条记录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background {
            // Keep the keyboard command without a duplicate visible action or an implicit first-row target.
            Button("复制选中记录的主要字段") {
                if let item = store.filteredItems.first(where: { $0.id == cursorID }) { copyPrimary(item) }
            }.keyboardShortcut("2", modifiers: .command)
                .disabled(store.isWorking || store.filteredItems.first(where: { $0.id == cursorID })?.primaryCopyField == nil)
                .hidden().accessibilityHidden(true)
        }
        .onAppear { searchFocused = true }
        .onChange(of: store.selectedID) { id in
            if id != nil { searchFocused = false }
        }
        .onChange(of: store.filteredItems.map(\.id)) { ids in
            if !ids.contains(cursorID ?? "") { cursorID = nil }
        }
        .onMoveCommand { direction in
            let ids = store.filteredItems.map(\.id)
            guard !ids.isEmpty else { return }
            guard let current = ids.firstIndex(of: cursorID ?? "") else {
                if direction == .down { cursorID = ids.first }
                if direction == .up { cursorID = ids.last }
                store.userDidInteract()
                return
            }
            if direction == .down { cursorID = ids[min(current + 1, ids.count - 1)] }
            if direction == .up { cursorID = ids[max(current - 1, 0)] }
            store.userDidInteract()
        }
    }

    private func copyPrimary(_ item: VaultItemSummary) {
        guard let fieldID = item.primaryCopyField else { return }
        let generation = store.generation
        Task { await store.copyField(for: item.id, fieldID: fieldID, expectedGeneration: generation) }
    }

    private func copyPassword(_ id: String) {
        let generation = store.generation
        Task { await store.copyPassword(for: id, expectedGeneration: generation) }
    }

    private func copyTOTP(_ id: String) {
        let generation = store.generation
        Task { await store.copyTOTP(for: id, expectedGeneration: generation) }
    }
}
