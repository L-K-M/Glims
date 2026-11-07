import AppKit
import XCTest
import RigiUI
@testable import GlimsKit

/// The History palette's pure logic without an engine: how a row marks
/// the current state by shape and VoiceOver label, and the pick rules
/// that bind a displayed row to its document and revision so a stale row
/// is refused and reloaded instead of silently selecting another state.
@MainActor
final class HistoryPaletteTests: XCTestCase {

    private func history(revision: UInt64 = 9, current: Int32 = 1) -> EngineSession.History {
        EngineSession.History(revision: revision, currentPosition: current, rows: [
            EngineSession.HistoryRow(position: 0, name: "Earliest State"),
            EngineSession.HistoryRow(position: 1, name: "Add Layer"),
            EngineSession.HistoryRow(position: 2, name: "Paint"),
        ])
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, as: type) { return match }
        }
        return nil
    }

    func testMarkerSeparatesTheCurrentStateByShape() {
        XCTAssertEqual(HistoryListSnapshot.marker(isCurrent: true), "●")
        XCTAssertEqual(HistoryListSnapshot.marker(isCurrent: false), "○")
    }

    func testAccessibilityLabelsSayWhatPickingDoes() {
        let rows = history().rows
        XCTAssertEqual(HistoryListSnapshot.accessibilityLabel(for: rows[0], currentPosition: 1),
                       "Earliest State, undo to this state")
        XCTAssertEqual(HistoryListSnapshot.accessibilityLabel(for: rows[1], currentPosition: 1),
                       "Add Layer, current state")
        XCTAssertEqual(HistoryListSnapshot.accessibilityLabel(for: rows[2], currentPosition: 1),
                       "Paint, redo to this state")
    }

    func testPickSendsTheRowsOwnPositionAndRevision() {
        let owner = NSObject()
        let shown = HistoryListSnapshot(document: owner, history: history())
        XCTAssertEqual(shown.pick(row: 0, for: owner, currentRevision: 9),
                       .move(position: 0, revision: 9))
        // Undone future rows are pickable: they redo.
        XCTAssertEqual(shown.pick(row: 2, for: owner, currentRevision: 9),
                       .move(position: 2, revision: 9))
    }

    func testStaleRowsRefuseInsteadOfRetryingUnderANewRevision() {
        let owner = NSObject()
        let shown = HistoryListSnapshot(document: owner, history: history(revision: 9))
        // The document's history moved on after the list was read.
        XCTAssertEqual(shown.pick(row: 2, for: owner, currentRevision: 10), .stale)
        // Another document's rows, a missing revision, a missing row.
        XCTAssertEqual(shown.pick(row: 2, for: NSObject(), currentRevision: 9), .stale)
        XCTAssertEqual(shown.pick(row: 2, for: owner, currentRevision: nil), .stale)
        XCTAssertEqual(shown.pick(row: 3, for: owner, currentRevision: 9), .stale)
        // No list at all.
        let empty = HistoryListSnapshot(document: nil, history: nil)
        XCTAssertEqual(empty.pick(row: 0, for: owner, currentRevision: 9), .stale)
    }

    func testEmptyPalettePresentsNoRowsAndADisabledSnapshot() {
        let controller = HistoryPaletteController()
        _ = controller.view
        controller.retarget(to: nil)
        let table = descendant(of: controller.view, as: NSTableView.self)
        let bar = descendant(of: controller.view, as: ClassicPaletteButtonBar.self)

        XCTAssertEqual(table.map(controller.numberOfRows(in:)), 0)
        XCTAssertEqual(table?.accessibilityLabel(), "History")
        XCTAssertEqual(bar?.isEnabled(item: "snapshot"), false)

        let snapshotItem = controller.paletteMenu?.items.first { $0.title == "New Snapshot" }
        XCTAssertEqual(snapshotItem.map(controller.validateMenuItem(_:)) ?? true, false)
    }
}
