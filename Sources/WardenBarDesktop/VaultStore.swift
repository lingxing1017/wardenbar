import Combine
import Foundation
import WardenBarCore

public enum VaultPhase: Equatable { case checking, setup, locked, unlocking, unlocked, locking, lockFailed }

@MainActor
public final class VaultStore: ObservableObject {
    @Published public private(set) var phase: VaultPhase = .checking
    @Published public private(set) var items: [VaultItemSummary] = []
    @Published public private(set) var selectedID: String?
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var generation: UInt64 = 0
    @Published public var query = "" { didSet { userDidInteract() } }
    @Published public var favoritesOnly = false { didSet { userDidInteract() } }
    public private(set) var lastActivity: TimeInterval
    private let backend: (any VaultBackend)?
    private let clipboard: ClipboardService
    private let clock: () -> TimeInterval
    private var locking: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?

    public init(backend: (any VaultBackend)?, clipboard: ClipboardService, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.clipboard = clipboard
        self.clock = clock
        lastActivity = clock()
    }

    public var selectedItem: VaultItemSummary? { items.first { $0.id == selectedID } }
    public var filteredItems: [VaultItemSummary] {
        let words = query.split(whereSeparator: \.isWhitespace).map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        return items.filter { item in
            let metadata = ([item.name, item.username ?? ""] + item.uris).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return (!favoritesOnly || item.favorite) && words.allSatisfy { metadata.contains($0) }
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func start() async {
        guard phase == .checking || phase == .setup else { return }
        guard let backend else {
            phase = .setup
            errorMessage = "未找到可用的 Bitwarden CLI，请安装后重新打开应用。"
            return
        }
        let token = generation
        do {
            let status = try await backend.status()
            guard generation == token else { return }
            phase = status == .unauthenticated ? .setup : .locked
            errorMessage = nil
        } catch {
            guard generation == token else { return }
            phase = .setup
            errorMessage = "无法读取密码库状态，请检查 CLI 和独立目录后重试。"
        }
    }

    public func unlock(masterPassword: String, expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration, expectedGeneration != generation { return }
        guard phase == .locked, !isWorking, !masterPassword.isEmpty, let backend else { return }
        generation &+= 1
        let token = generation
        phase = .unlocking
        isWorking = true
        errorMessage = nil
        notice = nil
        userDidInteract()
        defer { if generation == token { isWorking = false } }
        do {
            try await backend.unlock(masterPassword: masterPassword)
            guard generation == token, phase == .unlocking else { return }
            phase = .unlocked
            let loaded = try await backend.items()
            guard generation == token, phase == .unlocked else { return }
            items = loaded
            userDidInteract()
        } catch {
            guard generation == token else { return }
            if phase == .unlocked {
                errorMessage = "密码库已解锁，但条目读取失败。请重试同步。"
            } else {
                let backendState = await backend.state
                guard generation == token else { return }
                phase = backendState == .lockFailed ? .lockFailed : .locked
                errorMessage = phase == .lockFailed ? Self.lockFailure : "解锁失败，请检查主密码与登录状态。"
            }
        }
    }

    public func sync(expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration, expectedGeneration != generation { return }
        guard phase == .unlocked, !isWorking, let backend else { return }
        let token = generation
        isWorking = true
        errorMessage = nil
        userDidInteract()
        defer { if generation == token { isWorking = false } }
        do {
            try await backend.sync()
            guard generation == token, phase == .unlocked else { return }
            let loaded = try await backend.items()
            guard generation == token, phase == .unlocked else { return }
            items = loaded
            if !items.contains(where: { $0.id == selectedID }) { selectedID = nil }
            lastSync = Date()
            userDidInteract()
            showNotice("同步完成")
        } catch {
            guard generation == token else { return }
            errorMessage = "同步失败，仍可查看已有条目。请稍后重试。"
        }
    }

    public func select(_ id: String?) {
        guard phase == .unlocked else { return }
        selectedID = items.first { $0.id == id }?.id
        userDidInteract()
    }

    public func copyUsername(for id: String) {
        guard phase == .unlocked, !isWorking, let username = items.first(where: { $0.id == id })?.username else { return }
        userDidInteract()
        do { try clipboard.copy(username); showNotice("用户名已复制") }
        catch { errorMessage = "无法写入剪贴板，请重试。" }
    }

    public func copyPassword(for id: String, expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration, expectedGeneration != generation { return }
        guard phase == .unlocked, !isWorking, items.contains(where: { $0.id == id }), let backend else { return }
        let token = generation
        isWorking = true
        userDidInteract()
        defer { if generation == token { isWorking = false } }
        do {
            let password = try await backend.password(for: id)
            guard generation == token, phase == .unlocked else { return }
            // No await between the session check and writing the pasteboard on MainActor.
            try password.withValue { try clipboard.copy($0) }
            showNotice("密码已复制")
        } catch {
            guard generation == token else { return }
            errorMessage = "无法复制密码，请重试或重新解锁。"
        }
    }

    /// Invalidates visible and pending secrets synchronously, before backend cleanup can suspend.
    @discardableResult
    public func lock() -> Task<Void, Never> {
        if let locking { return locking }
        let needsBackend = phase == .unlocked || phase == .unlocking || phase == .lockFailed
        generation &+= 1
        let token = generation
        items.removeAll()
        selectedID = nil
        query = ""
        isWorking = false
        noticeTimer?.cancel()
        notice = nil
        clipboard.clearIfOwned()
        guard needsBackend, let backend else { return Task {} }
        phase = .locking
        errorMessage = nil
        let task = Task { [weak self] in
            do {
                try await backend.lock()
                guard let self, self.generation == token else { return }
                self.phase = .locked
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .lockFailed
                self.errorMessage = Self.lockFailure
            }
            self?.locking = nil
        }
        locking = task
        return task
    }

    public func userDidInteract() {
        if phase == .unlocked || phase == .unlocking { lastActivity = clock() }
    }

    public func dismissError() { if phase != .lockFailed { errorMessage = nil } }

    private func showNotice(_ message: String) {
        noticeTimer?.cancel()
        notice = message
        let token = generation
        noticeTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.notice = nil
        }
    }

    private static let lockFailure = "后端锁定失败，访问已阻止。请重试锁定。"
}
