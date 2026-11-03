import Foundation

public enum VaultItemType: Int, CaseIterable, Sendable, Identifiable {
    case login = 1, secureNote = 2, card = 3, identity = 4, sshKey = 5
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .login: return "登录"
        case .secureNote: return "笔记"
        case .card: return "支付卡"
        case .identity: return "身份"
        case .sshKey: return "SSH 密钥"
        }
    }
}

/// Selected-detail values are explicitly wrapped; never put these in the search index.
public struct VaultDetailField: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: SecretValue
    public let concealed: Bool
    public let multiline: Bool
}

extension WireItem {
    struct Card: Decodable {
        let cardholderName, brand, number, expMonth, expYear, code: String?
    }
    struct Identity: Decodable {
        let title, firstName, middleName, lastName, username, company, email, phone: String?
        let ssn, passportNumber, licenseNumber, address1, address2, address3, city, state, postalCode, country: String?
    }
    struct SecureNote: Decodable { let type: Int? }
    struct SSHKey: Decodable { let privateKey, publicKey, keyFingerprint: String? }
    struct CustomField: Decodable { let name: String?; let type: Int; let value: String? }

    var isSupportedRecord: Bool {
        guard UUID(uuidString: id) != nil, reprompt == 0, organizationId == nil, deletedDate == nil else { return false }
        switch VaultItemType(rawValue: type) {
        case .login: return login != nil
        case .secureNote: return secureNote?.type == 0
        case .card: return card != nil
        case .identity: return identity != nil
        case .sshKey: return sshKey != nil
        case nil: return false
        }
    }

    var recordSubtitle: String? {
        switch VaultItemType(rawValue: type) {
        case .login: return login?.username ?? login?.uris?.compactMap(\.uri).first
        case .card:
            var parts = [card?.brand].compactMap { $0 }.filter { !$0.isEmpty }
            let digits = card?.number?.filter(\.isNumber) ?? ""
            if digits.count >= 4 { parts.append("••••" + digits.suffix(4)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .identity:
            if let email = identity?.email, !email.isEmpty { return email }
            let name = [identity?.firstName, identity?.middleName, identity?.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? nil : name
        case .sshKey: return sshKey?.keyFingerprint
        default: return nil
        }
    }

    var primaryFieldID: String? {
        let candidate: (String, String?)
        switch VaultItemType(rawValue: type) {
        case .login: candidate = ("login.password", login?.password)
        case .secureNote: candidate = ("notes", notes)
        case .card: candidate = ("card.number", card?.number)
        case .identity: candidate = ("identity.email", identity?.email)
        case .sshKey: candidate = ("ssh.publicKey", sshKey?.publicKey)
        case nil: return nil
        }
        return candidate.1?.isEmpty == false ? candidate.0 : nil
    }

    var detailFields: [VaultDetailField] {
        var result: [VaultDetailField] = []
        func add(_ id: String, _ label: String, _ value: String?, hidden: Bool = false, multiline: Bool = false) {
            guard let value, !value.isEmpty else { return }
            result.append(VaultDetailField(id: id, label: label, value: SecretValue(value), concealed: hidden, multiline: multiline))
        }
        switch VaultItemType(rawValue: type) {
        case .login:
            add("login.username", "用户名", login?.username)
            add("login.password", "密码", login?.password, hidden: true)
        case .card:
            add("card.cardholderName", "持卡人", card?.cardholderName)
            add("card.brand", "卡组织", card?.brand)
            add("card.number", "卡号", card?.number, hidden: true)
            add("card.expMonth", "到期月份", card?.expMonth)
            add("card.expYear", "到期年份", card?.expYear)
            add("card.code", "安全码", card?.code, hidden: true)
        case .identity:
            let i = identity
            for (key, label, value) in [("title", "称谓", i?.title), ("firstName", "名字", i?.firstName), ("middleName", "中间名", i?.middleName), ("lastName", "姓氏", i?.lastName), ("username", "用户名", i?.username), ("company", "公司", i?.company), ("email", "电子邮箱", i?.email), ("phone", "电话", i?.phone), ("address1", "地址", i?.address1), ("address2", "地址第二行", i?.address2), ("address3", "地址第三行", i?.address3), ("city", "城市", i?.city), ("state", "省／州", i?.state), ("postalCode", "邮政编码", i?.postalCode), ("country", "国家／地区", i?.country)] {
                add("identity." + key, label, value)
            }
            add("identity.ssn", "社会保障号码", i?.ssn, hidden: true)
            add("identity.passportNumber", "护照号码", i?.passportNumber, hidden: true)
            add("identity.licenseNumber", "驾照号码", i?.licenseNumber, hidden: true)
        case .sshKey:
            add("ssh.publicKey", "公钥", sshKey?.publicKey, multiline: true)
            add("ssh.keyFingerprint", "指纹", sshKey?.keyFingerprint)
            add("ssh.privateKey", "私钥", sshKey?.privateKey, hidden: true, multiline: true)
        default: break
        }
        add("notes", "笔记", notes, hidden: true, multiline: true)
        for (index, field) in (fields ?? []).enumerated() where (0...2).contains(field.type) {
            add("custom:\(index)", field.name?.isEmpty == false ? field.name! : "自定义字段 \(index + 1)", field.value, hidden: field.type == 1)
        }
        return result
    }
}
