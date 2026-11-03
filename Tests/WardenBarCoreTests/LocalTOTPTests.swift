import Foundation
import XCTest
@testable import WardenBarCore

final class LocalTOTPTests: XCTestCase {
    // Cross-check against the public Bitwarden SDK Steam vector (2023-01-01 UTC).
    func testSteamGuardVector() throws {
        for prefix in ["steam://", "StEam://"] {
            XCTAssertEqual(try LocalTOTP.generate(seed: prefix + "HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ", at: Date(timeIntervalSince1970: 1672531200)).withValue { $0 }, "7W6CJ")
        }
    }
    // RFC 6238 Appendix B: independently specified expected codes.
    func testRFC6238VectorsAcrossAlgorithms() throws {
        let times: [TimeInterval] = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000]
        let vectors = [
            ("SHA1", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"]),
            ("SHA256", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA", ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"]),
            ("SHA512", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA", ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"])
        ]
        for (algorithm, seed, codes) in vectors {
            for (index, time) in times.enumerated() {
                let uri = "otpauth://totp/test?secret=\(seed)&digits=8&algorithm=\(algorithm)"
                XCTAssertEqual(try LocalTOTP.generate(seed: uri, at: Date(timeIntervalSince1970: time)).withValue { $0 }, codes[index])
            }
        }
    }

    func testDefaultAndCustomPeriodsRecomputeAtBoundary() throws {
        let seed = "gezd gnbv gy3t qojq gezd gnbv gy3t qojq"
        XCTAssertEqual(try LocalTOTP.generate(seed: seed, at: Date(timeIntervalSince1970: 59)).withValue { $0 }, "287082")
        let uri = "otpauth://totp/test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=60&digits=8"
        XCTAssertEqual(try LocalTOTP.generate(seed: uri, at: Date(timeIntervalSince1970: 59)).withValue { $0 }, "84755224")
        XCTAssertEqual(try LocalTOTP.generate(seed: uri, at: Date(timeIntervalSince1970: 60)).withValue { $0 }, "94287082")
    }

    func testMalformedInputsFailWithoutReflectingSeed() {
        for seed in ["", "!", "ABC1", "MY=ABC", "otpauth://hotp/test?secret=MY", "otpauth://totp/test?secret=MY&secret=MY", "otpauth://totp/test?secret=MY&period=0", "otpauth://totp/test?secret=MY&digits=999", "otpauth://totp/test?secret=MY&algorithm=MD5"] {
            XCTAssertThrowsError(try LocalTOTP.generate(seed: seed, at: Date(timeIntervalSince1970: 59))) { error in
                XCTAssertEqual(error as? VaultError, .invalidResponse)
            }
        }
        for time in [-1.0, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try LocalTOTP.generate(seed: "MY", at: Date(timeIntervalSince1970: time)))
        }
    }
}
