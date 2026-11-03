import Foundation
import XCTest
@testable import WardenBarCore

final class RecordModelTests: XCTestCase {
    private func decode(_ type: Int, _ payload: [String: Any], extra: [String: Any] = [:]) throws -> WireItem {
        var item: [String: Any] = ["id": "77777777-7777-7777-7777-777777777777", "name": "Synthetic", "type": type, "reprompt": 0]
        payload.forEach { item[$0] = $1 }
        extra.forEach { item[$0] = $1 }
        return try JSONDecoder().decode(WireItem.self, from: JSONSerialization.data(withJSONObject: item))
    }

    func testEachKnownTypeProjectsOnlySafeMetadata() throws {
        let card = try decode(3, ["card": ["number": "4111111111111111", "code": "987", "brand": "Visa"]])
        XCTAssertTrue(card.isSupportedRecord)
        XCTAssertEqual(card.summary.type, .card)
        XCTAssertEqual(card.summary.subtitle, "Visa · ••••1111")
        XCTAssertFalse(String(reflecting: card.summary).contains("4111111111111111"))
        XCTAssertFalse(card.summary.hasPassword)
        let identity = try decode(4, ["identity": ["email": "synthetic@example.invalid", "ssn": "synthetic-ssn"]])
        XCTAssertEqual(identity.summary.type, .identity)
        XCTAssertFalse(String(reflecting: identity.summary).contains("synthetic-ssn"))
        let note = try decode(2, ["secureNote": ["type": 0], "notes": "synthetic-private-note"])
        XCTAssertEqual(note.summary.type, .secureNote)
        XCTAssertFalse(String(reflecting: note.summary).contains("synthetic-private-note"))
        let ssh = try decode(5, ["sshKey": ["privateKey": "synthetic-private-key", "publicKey": "synthetic-public-key", "keyFingerprint": "synthetic-fingerprint"]])
        XCTAssertEqual(ssh.summary.type, .sshKey)
        XCTAssertEqual(ssh.summary.primaryFieldID, "ssh.publicKey")
        XCTAssertFalse(String(reflecting: ssh.summary).contains("synthetic-private-key"))
    }

    func testDetailFieldsPreserveWhitespaceAndConcealSensitiveValues() throws {
        let key = "\n-----BEGIN PRIVATE KEY-----\n synthetic-key\n-----END PRIVATE KEY-----\n"
        let ssh = try decode(5, ["sshKey": ["privateKey": key, "publicKey": "ssh-ed25519 synthetic", "keyFingerprint": "SHA256:synthetic"], "notes": " note\n", "fields": [["name": "PIN", "type": 1, "value": " 1234 "]]])
        let fields = ssh.detailFields
        XCTAssertEqual(fields.first { $0.id == "ssh.privateKey" }?.value.withValue { $0 }, key)
        XCTAssertEqual(fields.first { $0.id == "notes" }?.value.withValue { $0 }, " note\n")
        XCTAssertEqual(fields.first { $0.id == "custom:0" }?.value.withValue { $0 }, " 1234 ")
        XCTAssertEqual(fields.first { $0.id == "ssh.privateKey" }?.concealed, true)
        XCTAssertEqual(fields.first { $0.id == "notes" }?.concealed, true)
        XCTAssertFalse(String(reflecting: fields).contains("synthetic-key"))
    }

    func testProtectionAndPayloadAllowlistApplyToEveryType() throws {
        for (type, payload) in [(2, ["secureNote": ["type": 0]]), (3, ["card": [:]]), (4, ["identity": [:]]), (5, ["sshKey": [:]])] as [(Int, [String: Any])] {
            XCTAssertTrue(try decode(type, payload).isSupportedRecord)
            for protection in [["reprompt": 1], ["organizationId": "synthetic-org"], ["deletedDate": "2026-01-01"]] as [[String: Any]] {
                XCTAssertFalse(try decode(type, payload, extra: protection).isSupportedRecord)
            }
            XCTAssertFalse(try decode(type, [:]).isSupportedRecord)
        }
        XCTAssertFalse(try decode(999, [:]).isSupportedRecord)
    }
}
