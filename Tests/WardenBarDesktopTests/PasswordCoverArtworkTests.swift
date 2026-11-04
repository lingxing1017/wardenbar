import AppKit
import XCTest
import WardenBarDesktop
@testable import WardenBarApp

@MainActor
final class PasswordCoverArtworkTests: XCTestCase {
    func testHeroLoadsFromApplicationResources() throws {
        let image = try XCTUnwrap(PasswordCoverArtwork.lockedHero)
        XCTAssertGreaterThan(image.size.width, image.size.height * 2)
        XCTAssertFalse(image.isTemplate)
    }

    func testMenuBarStatesRemainDistinctTemplatesWithStableSize() throws {
        let images = PasswordCoverState.allCases.map(PasswordCoverArtwork.menuBar)
        XCTAssertTrue(images.allSatisfy { $0.isTemplate && $0.size == NSSize(width: 20, height: 18) })
        let data = try images.map { try XCTUnwrap($0.tiffRepresentation) }
        XCTAssertEqual(Set(data).count, 3)
        XCTAssertFalse(PasswordCoverArtwork.header.isTemplate)
        XCTAssertEqual(PasswordCoverArtwork.header.size, NSSize(width: 28, height: 20))
    }

    func testOnlyUnlockedPhaseUsesOpenCoverAndFailedLockUsesWarning() {
        XCTAssertEqual(PasswordCoverState(phase: .unlocked), .unlocked)
        XCTAssertEqual(PasswordCoverState(phase: .lockFailed), .lockFailed)
        for phase: VaultPhase in [.checking, .setup, .signingIn, .locked, .unlocking, .locking] {
            XCTAssertEqual(PasswordCoverState(phase: phase), .locked)
        }
    }
}
