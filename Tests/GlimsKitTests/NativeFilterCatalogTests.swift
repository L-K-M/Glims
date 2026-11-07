import AppKit
import XCTest
@testable import GlimsKit

/// The catalog's pure decisions: category mapping, ordering, availability
/// presentation, and installing into a menu without touching other items.
@MainActor
final class NativeFilterCatalogTests: XCTestCase {
    private func operation(_ name: String, title: String? = nil, categories: [String] = [],
                           support: EngineSession.FilterOpSupport = .supported) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title ?? name, categories: categories,
                                      blurb: "", support: support)
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
        let aux = operation("gegl:displace", title: "Displace", categories: ["map"], support: .needsAuxInput)
        let config = operation("gimp:curves", title: "Curves", categories: [], support: .needsConfig)
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(aux), "Displace (needs a second layer as its source)")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(config), "Curves (needs a dedicated editor)")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(operation("gegl:waves", title: "Waves")), "Waves…")
        let layout = NativeFilterMenuLayout(operations: [aux, config])
        XCTAssertEqual(layout.sections.map(\.title), ["Map", "Other"],
                       "unavailable operations keep their place in the catalog menu")
    }

    func testInstallKeepsNativeAndPlugInItems() {
        let menu = MainMenu.make()
        let procedure = EngineSession.Procedure(name: "plug-in-checkerboard", label: "Checkerboard…",
                                                menuPath: "<Image>/Filters/Render/Pattern", blurb: "",
                                                isSensitive: true)
        PlugInMenus.install([procedure], in: menu)
        let filter = menu.item(withTitle: "Filter")!.submenu!

        NativeFilterMenus.install([
            operation("gegl:median-blur", title: "Median Blur", categories: ["blur"]),
            operation("gegl:displace", title: "Displace", categories: ["map"], support: .needsAuxInput),
        ], in: menu)

        let native = filter.item(withTitle: "Native")?.submenu
        XCTAssertNotNil(native)
        XCTAssertEqual(native?.item(withTitle: "Blur")?.submenu?.items.map(\.title), ["Median Blur…"])
        let displace = native?.item(withTitle: "Map")?.submenu?.items.first
        XCTAssertEqual(displace?.title, "Displace (needs a second layer as its source)")
        XCTAssertEqual(displace?.action, #selector(DocumentWindowController.runNativeFilter(_:)))
        XCTAssertEqual((displace?.representedObject as? NativeFilterCommand)?.operation.name, "gegl:displace")
        XCTAssertNotNil(displace?.toolTip)

        // Nothing else moved: the dedicated command, plug-in categories
        // and the Recently Used placeholder are untouched.
        XCTAssertEqual(filter.item(withTitle: "Blur")?.submenu?.items.first?.title, "Gaussian Blur…")
        XCTAssertNotNil(filter.item(withTitle: "Render")?.submenu?.item(withTitle: "Pattern"))
        XCTAssertNotNil(filter.item(withTitle: MainMenu.recentlyUsedTitle))

        // A plug-in rebuild leaves the Native submenu alone.
        PlugInMenus.install([procedure], in: menu)
        XCTAssertEqual(filter.item(withTitle: "Native")?.submenu?.item(withTitle: "Blur")?.submenu?.items.count, 1)
    }

    func testInstallIsIdempotentAndDropsWhenEmpty() {
        let menu = MainMenu.make()
        let filter = menu.item(withTitle: "Filter")!.submenu!
        let ops = [operation("gegl:median-blur", title: "Median Blur", categories: ["blur"])]
        NativeFilterMenus.install(ops, in: menu)
        NativeFilterMenus.install(ops, in: menu)
        XCTAssertEqual(filter.items.filter { $0.title == "Native" }.count, 1)
        NativeFilterMenus.install([], in: menu)
        XCTAssertNil(filter.item(withTitle: "Native"))
    }
}
