import AppKit
import XCTest
@testable import GlimsKit

/// The catalog's pure decisions: category mapping, ordering, availability
/// presentation, and merging into the Filter menu's categories without
/// disturbing dedicated or plug-in items.
@MainActor
final class NativeFilterCatalogTests: XCTestCase {
    private func operation(_ name: String, title: String? = nil, categories: [String] = [],
                           support: EngineSession.FilterOpSupport = .supported) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title ?? name, categories: categories,
                                      blurb: "", support: support)
    }

    private func procedure(_ name: String, label: String? = nil,
                           menuPath: String) -> EngineSession.Procedure {
        EngineSession.Procedure(name: name, label: label ?? name, menuPath: menuPath,
                                blurb: "", isSensitive: true)
    }

    private func filterMenu(_ menu: NSMenu) -> NSMenu {
        menu.item(withTitle: "Filter")!.submenu!
    }

    /// Item titles of a submenu, marking separators as "—".
    private func titles(_ submenu: NSMenu?) -> [String] {
        submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
    }

    /// Every item anywhere under the Filter menu carrying a native command.
    private func nativeItems(_ menu: NSMenu) -> [NSMenuItem] {
        var found: [NSMenuItem] = []
        for item in filterMenu(menu).items {
            found += item.submenu?.items.filter { $0.representedObject is NativeFilterCommand } ?? []
        }
        return found
    }

    func testCategoryMappingUsesTheFirstKnownKey() {
        XCTAssertEqual(NativeFilterMenuLayout.submenuTitle(for: ["blur"]), "Blur")
        XCTAssertEqual(NativeFilterMenuLayout.submenuTitle(for: ["distort", "map"]), "Distort")
        XCTAssertEqual(NativeFilterMenuLayout.submenuTitle(for: ["artistic", "map"]), "Artistic")
        XCTAssertEqual(NativeFilterMenuLayout.submenuTitle(for: ["grayscale", "color"]), "Color")
        XCTAssertNil(NativeFilterMenuLayout.submenuTitle(for: ["compositors", "svgfilter"]))
        XCTAssertNil(NativeFilterMenuLayout.submenuTitle(for: []))
    }

    func testLayoutSortsCategoriesAndOperations() {
        let layout = NativeFilterMenuLayout(operations: [
            operation("gegl:waves", title: "Waves", categories: ["distort"]),
            operation("gegl:median-blur", title: "Median Blur", categories: ["blur"]),
            operation("gegl:gaussian-blur", title: "Gaussian Blur", categories: ["blur"]),
            operation("gegl:motion-blur", title: "Motion Blur", categories: ["blur"]),
            operation("custom:thing", title: "A Custom Thing", categories: ["programming"]),
        ])
        XCTAssertEqual(layout.sections.map(\.title), ["Blur", "Distort", "Other"])
        XCTAssertEqual(layout.sections[0].entries.map(\.title), ["Median Blur", "Motion Blur"],
                       "Gaussian Blur keeps its dedicated command and is left out")
        XCTAssertEqual(layout.sections[2].entries.map(\.name), ["custom:thing"])
    }

    func testUnavailableOperationsStayListedWithReasons() {
        let aux = operation("fixture:unhandled-map", title: "Unhandled Map", categories: ["map"], support: .needsAuxInput)
        let config = operation("gimp:future-config", title: "Future", categories: [], support: .needsConfig)
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(aux), "Unhandled Map (needs a second layer as its source)")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(config), "Future (needs a dedicated editor)")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(operation("gegl:waves", title: "Waves")), "Waves…")
        let layout = NativeFilterMenuLayout(operations: [aux, config])
        XCTAssertEqual(layout.sections.map(\.title), ["Map", "Other"],
                       "unavailable operations keep their place in the catalog menu")
    }

    /// Native after plug-ins: the catalog's operations merge into the
    /// Filter categories next to dedicated and plug-in items.
    func testInstallMergesIntoFilterCategoriesAlongsidePlugIns() {
        let menu = MainMenu.make()
        let checkerboard = procedure("plug-in-checkerboard", label: "Checkerboard (legacy)…",
                                     menuPath: "<Image>/Filters/Render/Pattern")
        PlugInMenus.install([checkerboard], in: menu)
        NativeFilterMenus.install([
            operation("gegl:median-blur", title: "Median Blur", categories: ["blur"]),
            operation("gegl:displace", title: "Displace", categories: ["map"], support: .needsAuxInput),
            operation("gegl:waves", title: "Waves", categories: ["render"]),
        ], in: menu)

        let filter = filterMenu(menu)
        XCTAssertNil(filter.item(withTitle: "Native"), "no implementation-level Native submenu remains")
        XCTAssertEqual(titles(filter.item(withTitle: "Blur")?.submenu),
                       ["Gaussian Blur…", "Median Blur…"],
                       "the catalog's blurs merge into Filter ▸ Blur next to the dedicated command")
        let displace = filter.item(withTitle: "Map")?.submenu?.items.first
        XCTAssertEqual(displace?.title, "Displace…")
        XCTAssertEqual(displace?.action, #selector(DocumentWindowController.runNativeFilter(_:)))
        XCTAssertEqual((displace?.representedObject as? NativeFilterCommand)?.operation.name, "gegl:displace")
        XCTAssertNil(displace?.toolTip, "the admitted source chooser needs no unavailable-operation reason")
        XCTAssertEqual(titles(filter.item(withTitle: "Render")?.submenu),
                       ["Waves…", "—", "Pattern"],
                       "native operations share a category with plug-in submenus")
        XCTAssertNotNil(filter.item(withTitle: MainMenu.recentlyUsedTitle))

        // A plug-in refresh loses none of the native entries.
        PlugInMenus.install([checkerboard], in: menu)
        XCTAssertEqual(nativeItems(menu).count, 3)
        XCTAssertEqual(titles(filter.item(withTitle: "Blur")?.submenu),
                       ["Gaussian Blur…", "Median Blur…"])
        XCTAssertEqual(titles(filter.item(withTitle: "Render")?.submenu),
                       ["Waves…", "—", "Pattern"])
    }

    /// Native before plug-ins: a plug-in install into a category the
    /// catalog created keeps the native entries too.
    func testInstallSurvivesPlugInInstallInEitherOrder() {
        let menu = MainMenu.make()
        let checkerboard = procedure("plug-in-checkerboard", label: "Checkerboard (legacy)…",
                                     menuPath: "<Image>/Filters/Render/Pattern")
        NativeFilterMenus.install([
            operation("gegl:waves", title: "Waves", categories: ["render"]),
        ], in: menu)
        PlugInMenus.install([checkerboard], in: menu)

        let filter = filterMenu(menu)
        XCTAssertEqual(titles(filter.item(withTitle: "Render")?.submenu),
                       ["Waves…", "—", "Pattern"],
                       "a category the catalog made is shared, not replaced")

        // Both refreshes are stable: native entries survive the plug-in
        // rebuild, plug-in entries survive the catalog rebuild.
        PlugInMenus.install([checkerboard], in: menu)
        NativeFilterMenus.install([
            operation("gegl:waves", title: "Waves", categories: ["render"]),
        ], in: menu)
        XCTAssertEqual(titles(filter.item(withTitle: "Render")?.submenu),
                       ["Waves…", "—", "Pattern"])
        XCTAssertEqual(nativeItems(menu).count, 1)
    }

    func testInstallIsIdempotentAndDropsWhenEmpty() {
        let menu = MainMenu.make()
        let filter = filterMenu(menu)
        let checkerboard = procedure("plug-in-checkerboard", label: "Checkerboard (legacy)…",
                                     menuPath: "<Image>/Filters/Render/Pattern")
        PlugInMenus.install([checkerboard], in: menu)
        let ops = [
            operation("gegl:median-blur", title: "Median Blur", categories: ["blur"]),
            operation("gegl:displace", title: "Displace", categories: ["map"], support: .needsAuxInput),
        ]
        NativeFilterMenus.install(ops, in: menu)
        NativeFilterMenus.install(ops, in: menu)
        XCTAssertEqual(nativeItems(menu).count, 2, "a repeated install adds no duplicates")
        XCTAssertEqual(filter.item(withTitle: "Map")?.submenu?.items.count, 1)

        NativeFilterMenus.install([], in: menu)
        XCTAssertEqual(nativeItems(menu).count, 0)
        XCTAssertNil(filter.item(withTitle: "Map"),
                     "a category the catalog made goes away when it is empty")
        XCTAssertEqual(titles(filter.item(withTitle: "Blur")?.submenu), ["Gaussian Blur…"],
                       "the dedicated command stays")
        XCTAssertNotNil(filter.item(withTitle: "Render")?.submenu?.item(withTitle: "Pattern"),
                        "plug-in categories stay")
    }
}
