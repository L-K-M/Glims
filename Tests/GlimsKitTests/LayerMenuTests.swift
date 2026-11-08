import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

/// The Layer menu and the Layers palette's menu list the resize commands
/// wired to the typed layer commands.
@MainActor
final class LayerMenuTests: XCTestCase {
    func testTheLayerMenuListsTheResizeCommands() {
        let menu = MainMenu.make()
        let layer = menu.items.first { $0.title == "Layer" }?.submenu
        let titles = layer?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Layer to Image Size"))
        XCTAssertTrue(titles.contains("Trim Layer to Content"))

        let fit = layer?.items.first { $0.title == "Layer to Image Size" }
        XCTAssertEqual(fit?.action, #selector(DocumentWindowController.layerToImageSize(_:)))
        let trim = layer?.items.first { $0.title == "Trim Layer to Content" }
        XCTAssertEqual(trim?.action, #selector(DocumentWindowController.trimLayerToContent(_:)))
    }

    func testThePaletteMenuListsThemWithTheirCommandTags() {
        let palette = LayersPaletteController()
        let menu = palette.paletteMenu
        let fit = menu?.items.first { $0.title == "Layer to Image Size" }
        let trim = menu?.items.first { $0.title == "Trim Layer to Content" }
        XCTAssertEqual(fit?.tag, Int(EngineSession.LayerCommand.fitToImage.rawValue))
        XCTAssertEqual(trim?.tag, Int(EngineSession.LayerCommand.trimToContent.rawValue))
        // No document: nothing validates.
        for item in [fit, trim].compactMap({ $0 }) {
            XCTAssertFalse(palette.validateMenuItem(item))
        }
    }

    func testTheCommandValuesMatchTheFacade() {
        XCTAssertEqual(EngineSession.LayerCommand.fitToImage.rawValue, GLIMS_LAYER_FIT_TO_IMAGE.rawValue)
        XCTAssertEqual(EngineSession.LayerCommand.trimToContent.rawValue, GLIMS_LAYER_TRIM_TO_CONTENT.rawValue)
    }

    /// The layer-source commands sit on the Layer menu, wired to the
    /// document window's own sheet actions.
    func testTheLayerMenuListsTheSourceCommands() {
        let menu = MainMenu.make()
        let layer = menu.items.first { $0.title == "Layer" }?.submenu
        let rasterize = layer?.items.first { $0.title == "Rasterize Layer…" }
        XCTAssertEqual(rasterize?.action, #selector(DocumentWindowController.rasterizeLayer(_:)))
        let restore = layer?.items.first { $0.title == "Restore Layer Source…" }
        XCTAssertEqual(restore?.action, #selector(DocumentWindowController.restoreLayerSource(_:)))
    }
}
