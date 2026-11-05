import CryptoKit
import XCTest
@testable import WardenBarDesktop

final class BiometricEnvelopeTests: XCTestCase {
    func testEnvelopeRequiresRecipientKeyAndBindsAccount() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let envelope = try BiometricCredentialEnvelope.seal(Data("synthetic-master".utf8),
            recipient: recipient.publicKey, secureKey: Data("opaque-device-bound-key".utf8), account: "account-a")
        let decoded = try JSONDecoder().decode(BiometricCredentialEnvelope.self, from: JSONEncoder().encode(envelope))
        let sender = try P256.KeyAgreement.PublicKey(rawRepresentation: decoded.senderPublicKey)
        let shared = try recipient.sharedSecretFromKeyAgreement(with: sender)
        XCTAssertEqual(try decoded.open(sharedSecret: shared, account: "account-a"), Data("synthetic-master".utf8))
        XCTAssertThrowsError(try decoded.open(sharedSecret: shared, account: "account-b"))
        let wrong = try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: sender)
        XCTAssertThrowsError(try decoded.open(sharedSecret: wrong, account: "account-a"))
        XCTAssertFalse(String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!.contains("synthetic-master"))
    }
}
