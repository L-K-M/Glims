import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ImageAdjustMenuTests: XCTestCase {
    private func operation(_ name: String, support: EngineSession.FilterOpSupport = .supported)
        -> EngineSession.FilterOperation {
        .init(name: name, title: "Engine \(name)", categories: ["color"], blurb: "Native detail", support: support)
    }

    private var operations: [EngineSession.FilterOperation] {
        [operation("gimp:threshold"), operation("gegl:invert-gamma"), operation("gegl:invert-linear")]
    }

    private func procedure(_ name: String, path: String = "<Image>/Colors") -> EngineSession.Procedure {
        .init(name: name, label: name, menuPath: path, blurb: "", isSensitive: true)
    }

    private var procedures: [EngineSession.Procedure] {
        [procedure("Legacy Color…"), procedure("Nested Color…", path: "<Image>/Colors/Map/Nested")]
    }

    private func image(_ menu: NSMenu) -> NSMenu { menu.item(withTitle: "Image")!.submenu! }
    private func adjust(_ menu: NSMenu) -> NSMenu { image(menu).item(withTitle: "Adjust")!.submenu! }

    private func descendants(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(descendants) ?? []) }
    }

    private func nativeNames(_ menu: NSMenu) -> [String] {
        descendants(menu).compactMap { ($0.representedObject as? NativeFilterCommand)?.operation.name }
    }

    private func pluginNames(_ menu: NSMenu) -> [String] {
        descendants(menu).compactMap { ($0.representedObject as? PlugInCommand)?.procedure.name }
    }

    private func assertSeparators(_ menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(menu.items.first?.isSeparatorItem == true, "leading separator in \(menu.title)", file: file, line: line)
        XCTAssertFalse(menu.items.last?.isSeparatorItem == true, "trailing separator in \(menu.title)", file: file, line: line)
        for (first, second) in zip(menu.items, menu.items.dropFirst()) {
            XCTAssertFalse(first.isSeparatorItem && second.isSeparatorItem, "adjacent separators in \(menu.title)", file: file, line: line)
        }
        menu.items.compactMap(\.submenu).forEach { assertSeparators($0, file: file, line: line) }
    }

    func testStaticAdjustKeepsItsIdentityThroughAllRefreshOrders() {
        for nativeFirst in [false, true] {
            let menu = MainMenu.make()
            let original = adjust(menu)
            let keep = NSMenuItem(title: "Unrelated command", action: nil, keyEquivalent: "")
            original.addItem(keep)
            for _ in 0..<3 {
                if nativeFirst {
                    NativeFilterMenus.install(operations, in: menu)
                    PlugInMenus.install(procedures, in: menu)
                } else {
                    PlugInMenus.install(procedures, in: menu)
                    NativeFilterMenus.install(operations, in: menu)
                }
                XCTAssertTrue(adjust(menu) === original)
                XCTAssertEqual(image(menu).items.filter { $0.title == "Adjust" }.count, 1)
                XCTAssertTrue(original.item(withTitle: keep.title) === keep)
                XCTAssertEqual(nativeNames(original), ["gimp:threshold", "gegl:invert-gamma", "gegl:invert-linear"])
                XCTAssertEqual(pluginNames(original).sorted(), ["Legacy Color…", "Nested Color…"])
                assertSeparators(original)
            }
        }
    }

    func testDedicatedBrightnessContrastAppearsWithoutAdmittingOtherConfigs() {
        let menu = MainMenu.make()
        let brightness = operation("gimp:brightness-contrast", support: .needsConfig)
        let unknown = operation("gimp:future-config", support: .needsConfig)
        NativeFilterMenus.install(operations + [brightness, unknown], in: menu)
        XCTAssertEqual(nativeNames(adjust(menu)), ["gimp:brightness-contrast", "gimp:threshold", "gegl:invert-gamma", "gegl:invert-linear"])
        XCTAssertEqual(adjust(menu).items.first?.title, "Brightness/Contrast…")
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(brightness))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(unknown))
    }

    func testDedicatedColorBalanceAppearsAlongsideBrightnessContrast() {
        let menu = MainMenu.make()
        let brightness = operation("gimp:brightness-contrast", support: .needsConfig)
        let balance = operation("gimp:color-balance", support: .needsConfig)
        let levels = operation("gimp:levels", support: .needsConfig)
        NativeFilterMenus.install(operations + [balance, levels, brightness], in: menu)
        XCTAssertEqual(nativeNames(adjust(menu)), ["gimp:brightness-contrast", "gimp:color-balance", "gimp:levels", "gimp:threshold", "gegl:invert-gamma", "gegl:invert-linear"])
        XCTAssertEqual(adjust(menu).items[1].title, "Color Balance…")
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(balance))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(levels))
    }

    func testDedicatedHueSaturationKeepsOtherConfigGates() {
        let menu = MainMenu.make()
        let hue = operation("gimp:hue-saturation", support: .needsConfig)
        let unknown = operation("gimp:future-config", support: .needsConfig)
        let levels = operation("gimp:levels", support: .needsConfig)
        NativeFilterMenus.install(operations + [hue, unknown, levels], in: menu)
        XCTAssertEqual(nativeNames(adjust(menu)), ["gimp:hue-saturation", "gimp:levels", "gimp:threshold", "gegl:invert-gamma", "gegl:invert-linear"])
        XCTAssertEqual(adjust(menu).items.first?.title, "Hue/Saturation…")
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(unknown))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(levels))
    }

    func testExactNativeTitlesUseExistingCommandAndFilterCopies() {
        let menu = MainMenu.make()
        NativeFilterMenus.install(operations + [operation("gegl:threshold"), operation("gegl:brightness-contrast")], in: menu)
        let entries = adjust(menu).items
        XCTAssertEqual(entries.map(\.title), ["Threshold…", "Invert Perceptual…", "Invert Linear…"])
        XCTAssertEqual(nativeNames(adjust(menu)), ["gimp:threshold", "gegl:invert-gamma", "gegl:invert-linear"])
        for entry in entries {
            XCTAssertEqual(entry.action, #selector(DocumentWindowController.runNativeFilter(_:)))
            XCTAssertNil(entry.target)
            XCTAssertEqual(entry.keyEquivalent, "")
            XCTAssertEqual(entry.toolTip, "Native detail")
            XCTAssertNotEqual(entry.tag, 0)
            XCTAssertNotEqual(entry.tag, PlugInMenus.generatedTag)
        }
        let color = menu.item(withTitle: "Filter")!.submenu!.item(withTitle: "Color")!.submenu!
        XCTAssertEqual(Set(nativeNames(color)), Set(operations.map(\.name) + ["gegl:threshold", "gegl:brightness-contrast"]))
        XCTAssertTrue(color.items.contains { $0.title == "Engine gimp:threshold…" })
    }

    func testMissingAndUnsupportedOperationsAreNotOfferedAsAdjustments() {
        let menu = MainMenu.make()
        NativeFilterMenus.install([
            operation("gimp:threshold", support: .needsConfig),
            operation("gegl:invert-gamma", support: .needsAuxInput),
            operation("gegl:invert-linear")
        ], in: menu)
        XCTAssertEqual(adjust(menu).items.map(\.title), ["Invert Linear…"])
        let color = menu.item(withTitle: "Filter")!.submenu!.item(withTitle: "Color")!.submenu!
        XCTAssertEqual(nativeNames(color).count, 3, "existing catalog presentation retains its support reasons")
        XCTAssertTrue(color.items.contains { $0.title.contains("needs a dedicated editor") })
        XCTAssertTrue(color.items.contains { $0.title.contains("needs a second layer") })
        NativeFilterMenus.install([], in: menu)
        XCTAssertTrue(adjust(menu).items.isEmpty)
    }

    func testPartialAndEmptyRefreshesRemoveOnlyTheirOwnContent() {
        let menu = MainMenu.make()
        let original = adjust(menu)
        PlugInMenus.install(procedures, in: menu)
        NativeFilterMenus.install(operations, in: menu)
        PlugInMenus.install([], in: menu)
        XCTAssertEqual(nativeNames(original).count, 3)
        XCTAssertTrue(pluginNames(original).isEmpty)
        assertSeparators(original)
        PlugInMenus.install(procedures, in: menu)
        NativeFilterMenus.install([operation("gimp:threshold")], in: menu)
        XCTAssertEqual(nativeNames(original), ["gimp:threshold"])
        XCTAssertEqual(pluginNames(original).count, 2)
        assertSeparators(original)
        NativeFilterMenus.install([], in: menu)
        XCTAssertTrue(nativeNames(original).isEmpty)
        XCTAssertEqual(pluginNames(original).count, 2)
        assertSeparators(original)
        PlugInMenus.install([], in: menu)
        XCTAssertTrue(original.items.isEmpty)
        XCTAssertTrue(adjust(menu) === original)
    }

    func testNestedGeneratedCategoriesPreserveUnrelatedContentAndIdentity() {
        let menu = MainMenu.make()
        let nested = procedure("Old child", path: "<Image>/Colors/Map/Nested")
        PlugInMenus.install([nested], in: menu)
        let map = adjust(menu).item(withTitle: "Map")!.submenu!
        let child = map.item(withTitle: "Nested")!.submenu!
        let keep = NSMenuItem(title: "Unrelated nested command", action: nil, keyEquivalent: "")
        child.addItem(keep)
        for _ in 0..<2 {
            PlugInMenus.install([procedure("New child", path: "<Image>/Colors/Map/Nested")], in: menu)
            XCTAssertEqual(adjust(menu).items.filter { $0.title == "Map" }.count, 1)
            XCTAssertTrue(adjust(menu).item(withTitle: "Map")?.submenu === map)
            XCTAssertTrue(map.item(withTitle: "Nested")?.submenu === child)
            XCTAssertTrue(child.item(withTitle: keep.title) === keep)
            XCTAssertEqual(pluginNames(adjust(menu)), ["New child"])
            assertSeparators(adjust(menu))
        }
        PlugInMenus.install([], in: menu)
        XCTAssertEqual(child.items.count, 1)
        XCTAssertTrue(child.items.first === keep)
        XCTAssertTrue(pluginNames(adjust(menu)).isEmpty)
    }

    func testNativeInstallDoesNotRequireFilterMenu() {
        let menu = NSMenu()
        let image = NSMenu(title: "Image")
        let adjust = NSMenu(title: "Adjust")
        image.addItem(withTitle: "Adjust", action: nil, keyEquivalent: "").submenu = adjust
        menu.addItem(withTitle: "Image", action: nil, keyEquivalent: "").submenu = image
        NativeFilterMenus.install(operations, in: menu)
        XCTAssertEqual(nativeNames(adjust).count, 3)
        NativeFilterMenus.install([], in: menu)
        XCTAssertTrue(adjust.items.isEmpty)
    }
}
