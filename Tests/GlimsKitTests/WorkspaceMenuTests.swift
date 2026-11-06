import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class WorkspaceMenuTests: XCTestCase {
    private final class FakeStore: WorkspaceStore {
        var workspaceNames: [String] = []
        var applied: [String] = []
        var deleted: [String] = []
        func saveWorkspace(named name: String) { workspaceNames.append(name) }
        func applyWorkspace(named name: String) -> Bool { applied.append(name); return true }
        func deleteWorkspace(named name: String) { deleted.append(name) }
    }

    func testTheMenuListsSavedWorkspacesThenSaveAndDelete() throws {
        let store = FakeStore()
        let menuController = WorkspaceMenu()
        menuController.store = store
        let menu = NSMenu()

        menuController.rebuild(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Save Workspace…", "Delete Workspace"])
        XCTAssertFalse(try XCTUnwrap(menu.items.last).isEnabled, "nothing to delete yet")

        store.workspaceNames = ["Painting", "Paths"]
        menuController.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Painting", "Paths", "", "Save Workspace…", "Delete Workspace"])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title), ["Painting", "Paths"])

        let paths = menu.items[1]
        _ = (paths.target as? NSObject)?.perform(paths.action, with: paths)
        let deletePainting = try XCTUnwrap(menu.items.last?.submenu?.items.first)
        _ = (deletePainting.target as? NSObject)?.perform(deletePainting.action, with: deletePainting)
        XCTAssertEqual(store.applied, ["Paths"])
        XCTAssertEqual(store.deleted, ["Painting"])
    }
}
