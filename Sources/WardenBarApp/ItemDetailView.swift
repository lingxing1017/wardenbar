import SwiftUI
import WardenBarCore
import WardenBarDesktop

@MainActor
struct ItemDetailView: View {
    @ObservedObject var store: VaultStore
    let item: VaultItemSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.select(nil) } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                HStack(alignment: .top) {
                    Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("已收藏") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("用户名").font(.caption).foregroundStyle(.secondary)
                    Text(item.username?.isEmpty == false ? item.username! : "未设置用户名")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.copyUsername(for: item.id) } label: { Label("复制用户名", systemImage: "person.crop.rectangle") }
                        .keyboardShortcut("1", modifiers: .command)
                        .disabled(store.isWorking || item.username?.isEmpty != false)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("密码").font(.caption).foregroundStyle(.secondary)
                    Text("••••••••••••").font(.body).accessibilityLabel("密码已隐藏")
                    Button(action: copyPassword) { Label("复制密码", systemImage: "doc.on.doc") }
                        .keyboardShortcut("2", modifiers: .command)
                        .disabled(store.isWorking)
                }
                if !item.uris.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("网站").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(item.uris.enumerated()), id: \.offset) { _, uri in
                            if let url = URL(string: uri), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                                Link(uri, destination: url).lineLimit(2)
                            } else {
                                Text(uri).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }

    private func copyPassword() {
        let generation = store.generation
        Task { await store.copyPassword(for: item.id, expectedGeneration: generation) }
    }
}
