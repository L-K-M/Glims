import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ScreenModeControlsTests: XCTestCase {
    func testViewMenuExposesAllThreeModesWithoutTakingThePlainFKey() throws {
        let menu = MainMenu.make()
        let view = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let modes = try XCTUnwrap(view.item(withTitle: "Screen Mode")?.submenu)
        XCTAssertEqual(modes.items.map(\.title), ["Windowed", "Full Screen with Menu", "Full Screen Bare"])
        XCTAssertTrue(modes.items.allSatisfy { $0.action == Selector(("chooseScreenMode:")) && $0.keyEquivalent.isEmpty })
        XCTAssertEqual(modes.items.map(\.tag), [0, 1, 2])
    }

    func testToolsOffersThreeNamedScreenModeSegments() throws {
        let palette = ToolsPaletteController()
        func all(_ root: NSView) -> [NSSegmentedControl] {
            (root as? NSSegmentedControl).map { [$0] } ?? root.subviews.flatMap(all)
        }
        let control = try XCTUnwrap(all(palette.view).first { $0.accessibilityLabel() == "Screen mode" })
        XCTAssertEqual(control.segmentCount, 3)
        XCTAssertEqual((0..<3).map { control.label(forSegment: $0) },
                       ["Windowed", "Full Screen with Menu", "Full Screen Bare"])
        XCTAssertNotNil(control.action)
        XCTAssertNotNil(control.target)
    }
}
