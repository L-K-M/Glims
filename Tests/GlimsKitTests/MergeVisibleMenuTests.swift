import AppKit
import XCTest
@testable import GlimsKit

/// Layer ▸ Merge Visible sits with Merge Down and reaches the document
/// window controller. Its engine behavior is covered by the adapter
/// conformance tests and the engine smoke test.
final class MergeVisibleMenuTests: XCTestCase {
    @MainActor
    func testMergeVisibleFollowsMergeDownWithoutAShortcut() throws {
        _ = NSApplication.shared
        let layer = try XCTUnwrap(MainMenu.make().item(withTitle: "Layer")?.submenu)
        let titles = layer.items.map(\.title)
        let mergeDown = try XCTUnwrap(titles.firstIndex(of: "Merge Down"))
        XCTAssertEqual(titles[mergeDown + 1], "Merge Visible")
        let item = layer.items[mergeDown + 1]
        XCTAssertEqual(item.action, #selector(DocumentWindowController.mergeVisible(_:)))
        // Shift-Command-E is Photoshop's Merge Visible, but Export… owns it here.
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
