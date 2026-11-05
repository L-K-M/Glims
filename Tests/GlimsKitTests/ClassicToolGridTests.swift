import XCTest
import AppKit
@testable import GlimsKit

final class ClassicToolGridTests: XCTestCase {

    /// Records target/action calls; the grid should fire once per user pick.
    private final class ActionTarget: NSObject {
        private(set) var count = 0
        @objc func act(_ sender: Any?) { count += 1 }
    }

    private func tool(_ id: String, shortcut: String? = nil) -> ClassicToolGrid.Tool {
        ClassicToolGrid.Tool(id: id, name: id.capitalized, shortcut: shortcut,
                             image: NSImage(size: NSSize(width: 16, height: 16)))
    }

    /// Two groups and a single-tool slot, two columns:
    /// [move, hand] [brush] [eraser, airbrush].
    private func grid() -> ClassicToolGrid {
        ClassicToolGrid(slots: [
            ClassicToolGrid.Slot(tools: [tool("move", shortcut: "M"), tool("hand", shortcut: "M")]),
            ClassicToolGrid.Slot(tools: [tool("brush", shortcut: "B")]),
            ClassicToolGrid.Slot(tools: [tool("eraser", shortcut: "E"), tool("airbrush")])
        ], columns: 2)
    }

    // MARK: Layout geometry

    func testSlotFramesFillRowsLeftToRight() {
        var layout = ClassicToolGridLayout(columns: 2)
        layout.setSlotCount(5)
        XCTAssertEqual(layout.frame(forSlot: 0), CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertEqual(layout.frame(forSlot: 1), CGRect(x: 25, y: 0, width: 24, height: 24))
        XCTAssertEqual(layout.frame(forSlot: 2), CGRect(x: 0, y: 25, width: 24, height: 24))
        XCTAssertEqual(layout.frame(forSlot: 3), CGRect(x: 25, y: 25, width: 24, height: 24))
        XCTAssertEqual(layout.frame(forSlot: 4), CGRect(x: 0, y: 50, width: 24, height: 24))
    }

    func testIntrinsicSizeTracksSlotCount() {
        let layout = ClassicToolGridLayout(columns: 2)
        XCTAssertEqual(layout.size(forSlotCount: 0), .zero)
        XCTAssertEqual(layout.size(forSlotCount: 1), CGSize(width: 49, height: 24))
        XCTAssertEqual(layout.size(forSlotCount: 2), CGSize(width: 49, height: 24))
        XCTAssertEqual(layout.size(forSlotCount: 5), CGSize(width: 49, height: 74))
        XCTAssertEqual(grid().intrinsicContentSize, CGSize(width: 49, height: 49))
    }

    func testHitTestInsideCellsGapsAndBounds() {
        let layout = ClassicToolGridLayout(columns: 2)
        // Cell interiors.
        XCTAssertEqual(layout.hitTest(CGPoint(x: 1, y: 1), slotCount: 5), 0)
        XCTAssertEqual(layout.hitTest(CGPoint(x: 30, y: 10), slotCount: 5), 1)
        XCTAssertEqual(layout.hitTest(CGPoint(x: 12, y: 30), slotCount: 5), 2)
        XCTAssertEqual(layout.hitTest(CGPoint(x: 40, y: 30), slotCount: 5), 3)
        XCTAssertEqual(layout.hitTest(CGPoint(x: 12, y: 60), slotCount: 5), 4)
        // The 1 pt gaps between and around cells.
        XCTAssertNil(layout.hitTest(CGPoint(x: 24.5, y: 10), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 10, y: 24.5), slotCount: 5))
        // Cell edges are half-open: 24 is the gap, 25 is the next cell.
        XCTAssertNil(layout.hitTest(CGPoint(x: 24, y: 10), slotCount: 5))
        XCTAssertEqual(layout.hitTest(CGPoint(x: 25, y: 10), slotCount: 5), 1)
        // Outside the grid entirely, including the empty half of the last row.
        XCTAssertNil(layout.hitTest(CGPoint(x: -1, y: 10), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 10, y: -1), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 49, y: 10), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 30, y: 60), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 10, y: 80), slotCount: 5))
        XCTAssertNil(layout.hitTest(CGPoint(x: 10, y: 10), slotCount: 0))
    }

    // MARK: Per-slot current tool

    func testCurrentToolTracksEachSlotIndependently() {
        var layout = ClassicToolGridLayout(columns: 2)
        layout.setSlotCount(3)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 0), 0)
        layout.setCurrentTool(1, forSlot: 0)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 0), 1)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 1), 0)
        // Shrinking then regrowing keeps survivors and resets new slots.
        layout.setSlotCount(1)
        layout.setSlotCount(3)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 0), 1)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 2), 0)
    }

    func testCyclingWrapsAround() {
        var layout = ClassicToolGridLayout(columns: 2)
        layout.setSlotCount(1)
        XCTAssertEqual(layout.nextToolIndex(forSlot: 0, toolCount: 3), 1)
        layout.setCurrentTool(2, forSlot: 0)
        XCTAssertEqual(layout.nextToolIndex(forSlot: 0, toolCount: 3), 0)
        XCTAssertEqual(layout.cycleTool(forSlot: 0, toolCount: 3), 0)
        XCTAssertEqual(layout.currentToolIndex(forSlot: 0), 0)
        // An empty group cannot crash the cycle.
        XCTAssertEqual(layout.nextToolIndex(forSlot: 0, toolCount: 0), 0)
    }

    // MARK: Selection

    func testSelectToolUpdatesSlotCurrentAndSelectionWithoutAction() {
        let grid = grid()
        let target = ActionTarget()
        grid.target = target
        grid.action = #selector(ActionTarget.act(_:))

        grid.selectTool(id: "hand")
        XCTAssertEqual(grid.selectedToolID, "hand")
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "hand")
        XCTAssertEqual(target.count, 0)

        grid.selectTool(id: "brush")
        XCTAssertEqual(grid.selectedToolID, "brush")
        XCTAssertEqual(grid.currentTool(inSlot: 1)?.id, "brush")
        // The group still shows its own pick.
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "hand")
        XCTAssertEqual(target.count, 0)

        grid.selectTool(id: "not-a-tool")
        XCTAssertEqual(grid.selectedToolID, "brush")
    }

    func testCycleGroupWrapsAndSelectsNextTool() {
        let grid = grid()
        grid.cycleGroup(containing: "move")
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "hand")
        XCTAssertEqual(grid.selectedToolID, "hand")
        grid.cycleGroup(containing: "hand")     // same slot, wraps to first
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "move")
        XCTAssertEqual(grid.selectedToolID, "move")
    }

    func testUserSelectionSendsActionExactlyOnce() {
        _ = NSApplication.shared     // NSApp must exist for sendAction
        let grid = grid()
        let target = ActionTarget()
        grid.target = target
        grid.action = #selector(ActionTarget.act(_:))

        grid.selectCurrentTool(inSlot: 0, sendsAction: true)   // a click
        XCTAssertEqual(grid.selectedToolID, "move")
        XCTAssertEqual(target.count, 1)

        grid.select(1, inSlot: 0, sendsAction: true)           // a flyout choice
        XCTAssertEqual(grid.selectedToolID, "hand")
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "hand")
        XCTAssertEqual(target.count, 2)

        grid.cycleTool(inSlot: 0, sendsAction: true)           // an Option-click
        XCTAssertEqual(grid.selectedToolID, "move")
        XCTAssertEqual(grid.currentTool(inSlot: 0)?.id, "move")
        XCTAssertEqual(target.count, 3)

        // Programmatic selection never fires.
        grid.selectTool(id: "eraser")
        grid.cycleGroup(containing: "eraser")
        XCTAssertEqual(grid.selectedToolID, "airbrush")
        XCTAssertEqual(target.count, 3)
    }

    // MARK: Accessibility

    func testCellsAreRadioButtonsInARadioGroup() {
        let grid = grid()
        grid.selectTool(id: "brush")
        XCTAssertTrue(grid.isAccessibilityElement())
        XCTAssertEqual(grid.accessibilityRole(), .radioGroup)
        let cells = (grid.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells[0].accessibilityLabel(), "Move")
        XCTAssertEqual(cells[1].accessibilityLabel(), "Brush")
        XCTAssertEqual(cells[1].accessibilityValue() as? NSNumber, NSNumber(value: true))
        XCTAssertEqual(cells[0].accessibilityValue() as? NSNumber, NSNumber(value: false))
    }
}
