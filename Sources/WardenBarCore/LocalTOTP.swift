import CryptoKit
import Foundation

/// Generates a fresh code from session-only material. Never logs or persists inputs.
enum LocalTOTP {
    static func generate(seed: String, at date: Date) throws -> SecretValue {
        var secret = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        var algorithm = "SHA1"
        var digits = 6
        var period = 30
        let steam = secret.lowercased().hasPrefix("steam://")
        if steam {
            secret = String(secret.dropFirst(8))
        } else if secret.lowercased().hasPrefix("otpauth://") {
            guard let uri = URLComponents(string: secret), uri.host?.lowercased() == "totp" else { throw VaultError.invalidResponse }
            var parameters: [String: String] = [:]
            for item in uri.queryItems ?? [] {
                let key = item.name.lowercased()
                guard parameters[key] == nil, let value = item.value else { throw VaultError.invalidResponse }
                parameters[key] = value
            }
            guard let value = parameters["secret"] else { throw VaultError.invalidResponse }
            secret = value
            if let value = parameters["algorithm"] { algorithm = value.uppercased() }
            if let value = parameters["digits"] {
                guard let parsed = Int(value), (6...10).contains(parsed) else { throw VaultError.invalidResponse }
                digits = parsed
            }
            if let value = parameters["period"] {
                guard let parsed = Int(value), (1...86_400).contains(parsed) else { throw VaultError.invalidResponse }
                period = parsed
            }
        }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else { throw VaultError.invalidResponse }
        var counter = UInt64(seconds / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: try decodeBase32(secret))
        let digest: [UInt8]
        switch algorithm {
        case "SHA1": digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case "SHA256": digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: throw VaultError.invalidResponse
        }
        let offset = Int(digest[digest.count - 1] & 15)
        var binary = UInt64(digest[offset] & 127) << 24 | UInt64(digest[offset + 1]) << 16
            | UInt64(digest[offset + 2]) << 8 | UInt64(digest[offset + 3])
        if steam {
            let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
            var code = ""
            for _ in 0..<5 {
                code.append(alphabet[Int(binary % UInt64(alphabet.count))])
                binary /= UInt64(alphabet.count)
            }
            return SecretValue(code)
        }
        let modulus = (0..<digits).reduce(UInt64(1)) { value, _ in value * 10 }
        let code = String(binary % modulus)
        return SecretValue(String(repeating: "0", count: digits - code.count) + code)
    }

    private static func decodeBase32(_ source: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt32 = 0
        var bits = 0
        var output = Data()
        var padding = false
        for character in source.uppercased() where !character.isWhitespace {
            if character == "=" { padding = true; continue }
            guard !padding, let ascii = character.asciiValue, let value = alphabet.firstIndex(of: ascii) else { throw VaultError.invalidResponse }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 255))
                buffer &= (1 << bits) - 1
            }
        }
        guard !output.isEmpty, buffer == 0 else { throw VaultError.invalidResponse }
        return output
    }
}
