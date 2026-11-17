import AppKit
import XCTest
@testable import GlimsKit

final class SelectSimilarTests: XCTestCase {
    func testSimilarTakesOnlyTheWandsColorSettings() {
        var wand = EngineSession.SelectOptions()
        wand.operation = .intersect
        wand.feather = 12
        wand.cornerRadius = 4
        wand.threshold = 32.0 / 255.0
        wand.antialias = false
        wand.sampleMerged = true
        wand.contiguous = true
        let options = DocumentWindowController.similarOptions(wand)
        XCTAssertEqual(options.operation, .add)
        XCTAssertEqual(options.feather, 0)
        XCTAssertEqual(options.cornerRadius, 0)
        XCTAssertEqual(options.threshold, 32.0 / 255.0)
        XCTAssertFalse(options.antialias)
        XCTAssertTrue(options.sampleMerged)
        XCTAssertFalse(options.contiguous)
    }

    @MainActor
    func testSimilarClosesTheModifyGroupWithoutAShortcut() throws {
        _ = NSApplication.shared
        let select = try XCTUnwrap(MainMenu.make().item(withTitle: "Select")?.submenu)
        let titles = select.items.map(\.title)
        let antialiasing = try XCTUnwrap(titles.firstIndex(of: "Remove Antialiasing"))
        XCTAssertEqual(titles[antialiasing + 1], "Similar")
        XCTAssertTrue(select.items[antialiasing + 2].isSeparatorItem)
        let item = try XCTUnwrap(select.item(withTitle: "Similar"))
        XCTAssertEqual(item.action, #selector(DocumentWindowController.selectSimilar(_:)))
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
