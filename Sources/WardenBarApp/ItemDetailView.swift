import SwiftUI
import WardenBarCore
import WardenBarDesktop

@MainActor
struct ItemDetailView: View {
    @ObservedObject var store: VaultStore
    let item: VaultItemSummary
    @State private var fields: [VaultDetailField] = []
    @State private var revealed: Set<String> = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { store.select(nil) } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Label(item.type.title, systemImage: item.type.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    if item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("已收藏") }
                }
                if loading {
                    ProgressView("正在读取详情…").frame(maxWidth: .infinity)
                } else if failed {
                    Text("详情暂不可用，请返回后重试或同步密码库。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if fields.isEmpty {
                    Text("此记录没有可显示字段").foregroundStyle(.secondary)
                }
                ForEach(fields) { field in
                    Divider()
                    fieldRow(field)
                }
                if item.hasTOTP {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("动态验证码").font(.caption).foregroundStyle(.secondary)
                        Button {
                            let generation = store.generation
                            Task { await store.copyTOTP(for: item.id, expectedGeneration: generation) }
                        } label: { Label("复制动态验证码", systemImage: "clock") }
                            .keyboardShortcut("3", modifiers: .command).disabled(store.isWorking)
                    }
                }
                if !item.uris.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("网站").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(item.uris.enumerated()), id: \.offset) { _, uri in
                            if let url = URL(string: uri), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                                Link(uri, destination: url).lineLimit(2)
                            } else { Text(uri).lineLimit(2).textSelection(.enabled) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .task { await loadFields() }
        .onDisappear { fields.removeAll(); revealed.removeAll() }
    }

    private func fieldRow(_ field: VaultDetailField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(field.label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if field.concealed {
                    Button {
                        if revealed.contains(field.id) { revealed.remove(field.id) }
                        else { revealed.insert(field.id) }
                        store.userDidInteract()
                    } label: {
                        Label((revealed.contains(field.id) ? "隐藏" : "显示") + field.label,
                              systemImage: revealed.contains(field.id) ? "eye.slash" : "eye")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help((revealed.contains(field.id) ? "隐藏" : "显示") + field.label)
                }
                copyButton(field).labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("复制" + field.label).disabled(store.isWorking)
            }
            if field.concealed && !revealed.contains(field.id) {
                Text("••••••••••••").accessibilityLabel(field.label + "已隐藏")
            } else {
                Text(field.value.withValue { $0 })
                    .font(field.id.hasPrefix("ssh.") ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func copyButton(_ field: VaultDetailField) -> some View {
        let button = Button {
            let generation = store.generation
            Task { await store.copyField(for: item.id, fieldID: field.id, expectedGeneration: generation) }
        } label: { Label("复制" + field.label, systemImage: "doc.on.doc") }
        if field.id == "login.username" { button.keyboardShortcut("1", modifiers: .command) }
        else if field.id == item.primaryCopyField { button.keyboardShortcut("2", modifiers: .command) }
        else { button }
    }

    private func loadFields() async {
        fields.removeAll()
        revealed.removeAll()
        let generation = store.generation
        let revision = store.indexRevision
        let loaded = await store.details(for: item.id, expectedGeneration: generation, expectedRevision: revision)
        guard !Task.isCancelled, store.generation == generation, store.indexRevision == revision,
              store.phase == .unlocked, store.selectedID == item.id else { return }
        fields = loaded ?? []
        failed = loaded == nil
        loading = false
    }
}
