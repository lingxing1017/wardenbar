import XCTest
@testable import WardenBarDesktop

final class PopoverWidthTests: XCTestCase {
    func testSavedWidthsAreNormalizedBeforeLayout() {
        XCTAssertEqual(PopoverWidth.clamp(.nan), 320)
        XCTAssertEqual(PopoverWidth.clamp(.infinity), 320)
        XCTAssertEqual(PopoverWidth.clamp(-1), 280)
        XCTAssertEqual(PopoverWidth.clamp(9999), 480)
        XCTAssertEqual(PopoverWidth.clamp(305), 305)
    }

    func testDragUsesAbsoluteStartAndStaysWithinBounds() {
        XCTAssertEqual(PopoverWidth.resized(start: 320, translation: 10), 330)
        XCTAssertEqual(PopoverWidth.resized(start: 320, translation: 20), 340)
        XCTAssertEqual(PopoverWidth.resized(start: 320, translation: -1000), 280)
        XCTAssertEqual(PopoverWidth.resized(start: 320, translation: 1000), 480)
        XCTAssertEqual(PopoverWidth.resized(start: 320, translation: .nan), 320)
    }
}
