import XCTest
@testable import BoltbarNative

/// The menu bar mark is a template image with the bolt left open between the two pieces.
final class MarkTests: XCTestCase {
    func testStatusImageIsATemplateAtMenuBarSize() {
        let image = Mark.statusImage()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 27, height: 12))
        XCTAssertEqual(image.accessibilityDescription, "Boltbar")
    }

    func testBoltIsTheGapBetweenThePieces() {
        // Logo coordinates (y down) mapped into a 1285×575 rect.
        let path = Mark.path(in: NSRect(x: 0, y: 0, width: 1285, height: 575))
        func filled(_ x: CGFloat, _ y: CGFloat) -> Bool { path.contains(NSPoint(x: x - 229.5, y: 738.5 - y)) }
        XCTAssertTrue(filled(300, 451), "left arm")
        XCTAssertTrue(filled(1444, 451), "right arm")
        XCTAssertFalse(filled(517, 451), "left hole")
        XCTAssertFalse(filled(871, 451), "bolt jog")
        XCTAssertFalse(filled(930, 164.5), "bolt top")
        XCTAssertFalse(filled(814, 737.5), "bolt bottom")
    }
}
