import AppKit
import XCTest
@testable import GlimsKit

/// File ▸ Open as Layers… and Place…: menu placement and
/// selectors, and the engine version data that gates link layers — all
/// without an engine.
@MainActor
final class PlaceCommandTests: XCTestCase {
    /// The two imports sit directly below Open Recent on the document
    /// window's own selectors — never AppController's Open, which opens
    /// a file as a new document instead.
    func testFileMenuOffersImportsBelowOpenRecent() throws {
        let file = try XCTUnwrap(MainMenu.make().items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map(\.title)
        let recent = try XCTUnwrap(titles.firstIndex(of: "Open Recent"))
        XCTAssertEqual(titles[recent + 1], "Open as Layers…")
        XCTAssertEqual(titles[recent + 2], "Place…")
        let layers = try XCTUnwrap(file.items.first { $0.title == "Open as Layers…" })
        let place = try XCTUnwrap(file.items.first { $0.title == "Place…" })
        XCTAssertEqual(layers.action, #selector(DocumentWindowController.openLayersFromFile(_:)))
        XCTAssertEqual(place.action, #selector(DocumentWindowController.placeLinkFromFile(_:)))
        XCTAssertNotEqual(layers.action, #selector(AppController.openDocument(_:)))
        XCTAssertNotEqual(place.action, #selector(AppController.openDocument(_:)))
        for action in [layers.action!, place.action!] {
            XCTAssertFalse(NSApplication.shared.responds(to: action),
                           "\(action) must not collide with a standard responder")
        }
    }

    /// Link layers arrived in GIMP 3.2: 3.0 and older report unsupported,
    /// 3.2 and later support them, and an unparsable version stays nil so
    /// the facade's own answer decides.
    func testLinkLayerSupportFollowsTheEngineVersion() {
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.0.8"), false)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.1.2"), false)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "2.10.38"), false)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.2.0"), true)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.2.8"), true)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.3.1"), true)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "4.0"), true)
        XCTAssertNil(EngineSession.supportsLinkLayers(version: "?"))
        XCTAssertNil(EngineSession.supportsLinkLayers(version: "dev"))
        XCTAssertNil(EngineSession.supportsLinkLayers(version: "3"))
    }
}
