import CoreGraphics
import XCTest
@testable import GlimsKit

/// New document windows step down and right from the previous one, so
/// each title bar stays reachable, and start over at the top when the
/// next step would leave the screen.
@MainActor
final class DocumentCascadeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    func testANewWindowStepsDownAndRightFromThePreviousOne() {
        let previous = CGRect(x: 480, y: 200, width: 960, height: 680)
        let topLeft = DocumentWindowController.cascadedTopLeft(after: previous, size: previous.size, in: screen)
        XCTAssertEqual(topLeft, CGPoint(x: 480 + DocumentWindowController.cascadeStep,
                                        y: 880 - DocumentWindowController.cascadeStep))
    }

    func testAStepThatWouldLeaveTheScreenStartsOverAtTheTopLeft() {
        let previous = CGRect(x: 950, y: 5, width: 960, height: 680)
        let topLeft = DocumentWindowController.cascadedTopLeft(after: previous, size: previous.size, in: screen)
        XCTAssertEqual(topLeft, CGPoint(x: screen.minX + DocumentWindowController.cascadeStep, y: screen.maxY))
    }
}
