import AppKit
import SwiftUI
import WardenBarDesktop

@MainActor
struct VaultPopoverView: View {
    @ObservedObject var store: VaultStore
    let dataDirectory: URL
    let configurationIssue: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = configurationIssue ?? store.errorMessage { errorBanner(error) }
            Group {
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
                    if let item = store.selectedItem { ItemDetailView(store: store, item: item) }
                    else { VaultListView(store: store) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.userDidInteract() }
        .onExitCommand { NSApp.keyWindow?.orderOut(nil) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.tint).accessibilityHidden(true)
            Text("WardenBar").font(.system(size: 15, weight: .semibold))
            Spacer()
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
                Button("打开密码库目录") { NSWorkspace.shared.open(dataDirectory) }
                Divider()
                Button("退出 WardenBar") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("更多操作") }
            .menuStyle(.borderlessButton).fixedSize()
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
                Text(store.lastSync.map { "已同步 " + $0.formatted(date: .omitted, time: .shortened) } ?? "本地密码库 · \(store.items.count) 条登录")
            } else { Text(store.phase == .lockFailed ? "后端锁定待重试" : "密码库访问受保护") }
            Text("5 分钟未操作后锁定 · 复制后 30 秒清理")
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
                    TextField("搜索名称、用户名或网址", text: $store.query)
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
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("文件夹")
                    Spacer(minLength: 0)
                }
            }.padding(12)
            if store.isWorking && store.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(store.activityMessage ?? "正在读取登录条目…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(store.items.isEmpty ? "没有可显示的登录条目" : "未找到匹配项").font(.headline)
                    Text(store.items.isEmpty ? "当前支持普通个人登录条目。" : "试试其他文件夹或搜索词。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $cursorID) {
                    ForEach(store.filteredItems) { item in
                        HStack(spacing: 6) {
                            Button { store.select(item.id) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                        Text(item.username?.isEmpty == false ? item.username! : (item.uris.first ?? "登录条目"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if item.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("已收藏") }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            HStack(spacing: 2) {
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
                            }.labelStyle(.iconOnly).buttonStyle(.borderless).fixedSize()
                        }.padding(.vertical, 7).tag(item.id)
                    }
                }.listStyle(.inset)
                HStack {
                    Text("\(store.filteredItems.count) 条登录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background {
            // Keep the keyboard command without a duplicate visible action or an implicit first-row target.
            Button("复制选中条目的密码") {
                if let id = cursorID { copyPassword(id) }
            }.keyboardShortcut("2", modifiers: .command)
                .disabled(store.isWorking || store.filteredItems.first(where: { $0.id == cursorID })?.hasPassword != true)
                .hidden().accessibilityHidden(true)
        }
        .onAppear { searchFocused = true }
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

    private func copyPassword(_ id: String) {
        let generation = store.generation
        Task { await store.copyPassword(for: id, expectedGeneration: generation) }
    }

    private func copyTOTP(_ id: String) {
        let generation = store.generation
        Task { await store.copyTOTP(for: id, expectedGeneration: generation) }
    }
}
