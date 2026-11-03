import WardenBarCore

extension VaultItemType {
    static var displayOrder: [Self] { [.login, .card, .identity, .secureNote, .sshKey] }
    var symbol: String {
        switch self {
        case .login: return "globe"
        case .card: return "creditcard"
        case .identity: return "person.text.rectangle"
        case .secureNote: return "note.text"
        case .sshKey: return "key.horizontal"
        }
    }
    var copyLabel: String {
        switch self {
        case .login: return "复制密码"
        case .card: return "复制卡号"
        case .identity: return "复制电子邮箱"
        case .secureNote: return "复制笔记"
        case .sshKey: return "复制公钥"
        }
    }
}

extension VaultItemSummary {
    var primaryCopyField: String? {
        type == .login && hasPassword ? "login.password" : primaryFieldID
    }
}
