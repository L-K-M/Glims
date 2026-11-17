import AppKit
import XCTest
@testable import GlimsKit

final class LayerViaMenuTests: XCTestCase {
    @MainActor
    func testLayerViaItemsFollowDuplicateLayerWithPhotoshopCutShortcut() throws {
        _ = NSApplication.shared
        let layer = try XCTUnwrap(MainMenu.make().item(withTitle: "Layer")?.submenu)
        let titles = layer.items.map(\.title)
        let duplicate = try XCTUnwrap(titles.firstIndex(of: "Duplicate Layer"))
        XCTAssertEqual(Array(titles[duplicate + 1 ... duplicate + 2]), ["Layer via Copy", "Layer via Cut"])

        let copy = try XCTUnwrap(layer.item(withTitle: "Layer via Copy"))
        XCTAssertEqual(copy.action, #selector(DocumentWindowController.layerViaCopy(_:)))
        XCTAssertEqual(copy.keyEquivalent, "")

        let cut = try XCTUnwrap(layer.item(withTitle: "Layer via Cut"))
        XCTAssertEqual(cut.action, #selector(DocumentWindowController.layerViaCut(_:)))
        XCTAssertEqual(cut.keyEquivalent, "J")
        XCTAssertEqual(cut.keyEquivalentModifierMask, [.command])
    }

    func testLayerViaTitlesNameTheCommand() {
        XCTAssertEqual(ImageDocument.layerViaTitle(.copy), "Layer via Copy")
        XCTAssertEqual(ImageDocument.layerViaTitle(.move), "Layer via Cut")
    }
}
