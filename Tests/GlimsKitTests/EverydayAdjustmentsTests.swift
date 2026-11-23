import AppKit
import XCTest
@testable import GlimsKit

final class EverydayAdjustmentsTests: XCTestCase {
    @MainActor
    func testAdjustmentCommandsKeepTheirIdentity() {
        XCTAssertEqual(EngineSession.Adjustment.autoLevels.rawValue, 1)
        XCTAssertEqual(EngineSession.Adjustment.equalize.rawValue, 2)
        XCTAssertEqual(EngineSession.Adjustment.desaturate.rawValue, 3)
        XCTAssertEqual(EngineSession.Adjustment.addAlpha.rawValue, 4)
        XCTAssertEqual(EngineSession.Adjustment.removeAlpha.rawValue, 5)
        XCTAssertEqual(EngineSession.Adjustment.autoLevels.title, "Auto Levels")
        XCTAssertEqual(EngineSession.Adjustment.removeAlpha.title, "Remove Transparency")
    }

    @MainActor
    func testAdjustMenuCarriesTheOneClickCommands() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let adjust = try XCTUnwrap(menu.item(withTitle: "Image")?.submenu?
            .item(withTitle: MainMenu.adjustTitle)?.submenu)
        let titles = adjust.items.map(\.title)
        let auto = try XCTUnwrap(titles.firstIndex(of: "Auto Levels"))
        XCTAssertEqual(titles[auto + 1], "Desaturate")
        XCTAssertEqual(titles[auto + 2], "Equalize")
        let autoItem = try XCTUnwrap(adjust.item(withTitle: "Auto Levels"))
        XCTAssertEqual(autoItem.action, #selector(DocumentWindowController.autoLevels(_:)))
        XCTAssertEqual(autoItem.keyEquivalent, "l")
        XCTAssertEqual(autoItem.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(autoItem.tag, Int(EngineSession.Adjustment.autoLevels.rawValue))
        let desaturate = try XCTUnwrap(adjust.item(withTitle: "Desaturate"))
        XCTAssertEqual(desaturate.action, #selector(DocumentWindowController.desaturate(_:)))
        XCTAssertEqual(desaturate.keyEquivalent, "u")
        XCTAssertEqual(desaturate.keyEquivalentModifierMask, [.command, .shift])
        let equalize = try XCTUnwrap(adjust.item(withTitle: "Equalize"))
        XCTAssertEqual(equalize.action, #selector(DocumentWindowController.equalize(_:)))
        XCTAssertEqual(equalize.keyEquivalent, "")

        let layer = try XCTUnwrap(menu.item(withTitle: "Layer")?.submenu)
        let layerTitles = layer.items.map(\.title)
        let add = try XCTUnwrap(layerTitles.firstIndex(of: "Add Transparency"))
        XCTAssertEqual(layerTitles[add + 1], "Remove Transparency")
        XCTAssertEqual(layer.item(withTitle: "Add Transparency")?.action,
                       #selector(DocumentWindowController.addTransparency(_:)))
        XCTAssertEqual(layer.item(withTitle: "Remove Transparency")?.action,
                       #selector(DocumentWindowController.removeTransparency(_:)))
    }

    @MainActor
    func testAdjustShortcutsAreFree() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        var clashes: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "l" || item.keyEquivalent == "u" {
                    if item.keyEquivalentModifierMask == [.command, .shift] {
                        clashes.append("\(menu.title) > \(item.title)")
                    }
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        XCTAssertEqual(clashes.filter { $0.contains("Auto Levels") || $0.contains("Desaturate") }.count, 2)
        XCTAssertEqual(clashes.count, 2, "only Auto Levels and Desaturate use Shift-Command-L/U: \(clashes)")
    }

    @MainActor
    func testMenuMergesKeepTheDedicatedAdjustItems() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let operations = [
            EngineSession.FilterOperation(name: "gimp:threshold", title: "Threshold",
                                          categories: ["color"], blurb: "", support: .supported),
            EngineSession.FilterOperation(name: "gegl:invert-gamma", title: "Invert Perceptual",
                                          categories: ["color"], blurb: "", support: .supported),
        ]
        let procedure = EngineSession.Procedure(name: "test-colors", label: "Test Colors…",
                                                menuPath: "<Image>/Colors/Test", blurb: "", isSensitive: true)
        func install() {
            NativeFilterMenus.install(operations, in: menu)
            PlugInMenus.install([procedure], in: menu)
        }
        install()
        install()
        let adjust = try XCTUnwrap(menu.item(withTitle: "Image")?.submenu?
            .item(withTitle: MainMenu.adjustTitle)?.submenu)
        for title in ["Auto Levels", "Desaturate", "Equalize"] {
            XCTAssertEqual(adjust.items.filter { $0.title == title }.count, 1, "\(title) survives a rebuild exactly once")
        }
        let titles = adjust.items.map(\.title)
        let auto = try XCTUnwrap(titles.firstIndex(of: "Auto Levels"))
        XCTAssertEqual(titles[auto + 1], "Desaturate")
        XCTAssertEqual(titles[auto + 2], "Equalize")
        XCTAssertNotNil(adjust.item(withTitle: "Threshold…"))
        XCTAssertNotNil(adjust.item(withTitle: "Test"))
    }
}
