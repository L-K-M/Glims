import AppKit
import XCTest
@testable import GlimsKit

final class RankFilterTests: XCTestCase {
    @MainActor
    func testRanksFixPhotoshopsSquareSettings() {
        XCTAssertEqual(RankFilterPanel.operation, "gegl:median-blur")
        for rank in RankFilterPanel.Rank.allCases {
            let settings = Dictionary(uniqueKeysWithValues: RankFilterPanel.fixedSettings(rank).map { ($0.0, $0.1) })
            XCTAssertEqual(settings["neighborhood"], .enumeration("square"))
            XCTAssertEqual(settings["percentile"], .number(rank == .maximum ? 100 : 0))
            XCTAssertEqual(settings["alpha-percentile"], settings["percentile"])
            XCTAssertEqual(settings["high-precision"], .boolean(true))
            XCTAssertEqual(settings["abyss-policy"], .enumeration("clamp"))
        }
    }

    func testRadiusAcceptsWholePixelsOneToOneHundred() {
        XCTAssertEqual(RankFilterPanel.radius("1"), 1)
        XCTAssertEqual(RankFilterPanel.radius(" 100 "), 100)
        XCTAssertNil(RankFilterPanel.radius("0"))
        XCTAssertNil(RankFilterPanel.radius("101"))
        XCTAssertNil(RankFilterPanel.radius("1.5"))
        XCTAssertNil(RankFilterPanel.radius(""))
    }

    @MainActor
    func testOtherFollowsBlurWithMaximumAndMinimum() throws {
        _ = NSApplication.shared
        let filter = try XCTUnwrap(MainMenu.make().item(withTitle: "Filter")?.submenu)
        let titles = filter.items.map(\.title)
        let blur = try XCTUnwrap(titles.firstIndex(of: "Blur"))
        XCTAssertEqual(titles[blur + 1], "Other")
        let other = try XCTUnwrap(filter.item(withTitle: "Other")?.submenu)
        XCTAssertEqual(other.items.map(\.title), ["Maximum…", "Minimum…"])
        XCTAssertEqual(other.items.map(\.action), [#selector(DocumentWindowController.maximumFilter(_:)),
                                                   #selector(DocumentWindowController.minimumFilter(_:))])
        XCTAssertEqual(other.items.map(\.keyEquivalent), ["", ""])
    }
}
