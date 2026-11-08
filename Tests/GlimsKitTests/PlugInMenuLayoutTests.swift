import XCTest
@testable import GlimsKit

/// Engine menu paths are as GIMP 3.2.8's plug-ins register them.
final class PlugInMenuLayoutTests: XCTestCase {
    private func procedure(_ label: String, _ path: String) -> EngineSession.Procedure {
        EngineSession.Procedure(name: "plug-in-\(label.lowercased())", label: label,
                                menuPath: path, blurb: "", isSensitive: true)
    }

    func testFilterCategoriesAndSections() {
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Filters/Light and Shadow/[Shadow]"),
                       PlugInMenuPlacement(menu: .filter, submenus: ["Light and Shadow"], section: "Shadow"))
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Filters/Render/Pattern"),
                       PlugInMenuPlacement(menu: .filter, submenus: ["Render", "Pattern"], section: nil))
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Filters"),
                       PlugInMenuPlacement(menu: .filter, submenus: [], section: nil))
    }

    func testGimpColorsMenuIsImageAdjust() {
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Colors/Map/[Colormap]"),
                       PlugInMenuPlacement(menu: .image, submenus: ["Adjust", "Map"], section: "Colormap"))
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Image/[Crop]"),
                       PlugInMenuPlacement(menu: .image, submenus: [], section: "Crop"))
    }

    func testUnknownTopLevelGoesToFilterOther() {
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Windows/Dockable Dialogs"),
                       PlugInMenuPlacement(menu: .filter, submenus: ["Other", "Windows", "Dockable Dialogs"], section: nil))
    }

    func testPathsOutsideImageMenusAreSkipped() {
        XCTAssertNil(PlugInMenuPlacement(menuPath: "<Layers>/Layers Menu"))
        XCTAssertNil(PlugInMenuPlacement(menuPath: "<Image>"))
    }

    func testMnemonicsAreRemoved() {
        XCTAssertEqual(PlugInMenuPlacement(menuPath: "<Image>/Filters/_Render/Fo__o")?.submenus, ["Render", "Fo_o"])
    }

    func testNativePrintingReplacesOnlyTheEnginePrintingCommands() throws {
        let commands = [
            EngineSession.Procedure(name: "file-print-gtk", label: "Print…",
                                    menuPath: "<Image>/File/[Send]", blurb: "", isSensitive: true),
            EngineSession.Procedure(name: "file-print-gtk-page-setup", label: "Page Setup…",
                                    menuPath: "<Image>/File/[Send]", blurb: "", isSensitive: true),
            EngineSession.Procedure(name: "custom-proof", label: "Print…",
                                    menuPath: "<Image>/File/[Send]", blurb: "", isSensitive: true),
        ]
        let file = try XCTUnwrap(PlugInMenuNode.layout(commands)[.file])
        XCTAssertEqual(file.orderedSections.flatMap(\.entries).map(\.procedure.name), ["custom-proof"],
                       "the native replacements suppress GTK printing by procedure identity, preserving other plug-ins")
    }

    func testLayoutOrdersSubmenusThenMainPartThenSections() throws {
        let layout = PlugInMenuNode.layout([
            procedure("Sparkle…", "<Image>/Filters/Light and Shadow/[Light]"),
            procedure("Drop Shadow (legacy)…", "<Image>/Filters/Light and Shadow/[Shadow]"),
            procedure("Lighting Effects…", "<Image>/Filters/Light and Shadow/[Light]"),
            procedure("Checkerboard (legacy)…", "<Image>/Filters/Render/Pattern"),
            procedure("Fractal Explorer…", "<Image>/Filters/Render/Fractals"),
            procedure("Sphere Designer…", "<Image>/Filters/Render"),
            procedure("Guides…", "<Image>/Image/Guides"),
            procedure("Context", "<Layers>/Something"),
        ])

        XCTAssertEqual(Set(layout.keys), [.filter, .image])
        let filter = try XCTUnwrap(layout[.filter])
        XCTAssertEqual(filter.orderedSubmenus.map(\.title), ["Light and Shadow", "Render"])

        let light = try XCTUnwrap(filter.submenus["Light and Shadow"])
        XCTAssertEqual(light.orderedSections.map(\.name), ["Light", "Shadow"])
        XCTAssertEqual(light.orderedSections[0].entries.map(\.procedure.label), ["Lighting Effects…", "Sparkle…"])

        let render = try XCTUnwrap(filter.submenus["Render"])
        XCTAssertEqual(render.orderedSubmenus.map(\.title), ["Fractals", "Pattern"])
        XCTAssertEqual(render.orderedSections.map(\.name), [nil])
        XCTAssertEqual(render.orderedSections[0].entries.map(\.procedure.label), ["Sphere Designer…"])
    }
}
