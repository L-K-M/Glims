import XCTest
@testable import GlimsKit

/// The multi-layer selection policy, pinned as pure functions: the
/// primary-layer rule, the reconciliation of stale ids, the refusal
/// copy, and which layer commands a multi-selection gates.
final class LayerSelectionPolicyTests: XCTestCase {

    // MARK: Primary layer

    func testPrimaryIsTheFirstId() {
        XCTAssertEqual(LayerSelectionPolicy.primary(of: [7, 3, 9]), 7)
        XCTAssertEqual(LayerSelectionPolicy.primary(of: [42]), 42)
        XCTAssertNil(LayerSelectionPolicy.primary(of: []))
    }

    // MARK: Refusal copy

    func testRefusalOnlyForMultiSelection() {
        XCTAssertNil(LayerSelectionPolicy.refusal(count: 0, action: "Delete Layer"))
        XCTAssertNil(LayerSelectionPolicy.refusal(count: 1, action: "Delete Layer"))
        let reason = LayerSelectionPolicy.refusal(count: 3, action: "Delete Layer")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Choose one layer") == true,
                      "the refusal is actionable and says to choose one layer: \(reason ?? "")")
        XCTAssertTrue(reason?.contains("3") == true && reason?.contains("Delete Layer") == true)
    }

    func testIsMulti() {
        XCTAssertFalse(LayerSelectionPolicy.isMulti(0))
        XCTAssertFalse(LayerSelectionPolicy.isMulti(1))
        XCTAssertTrue(LayerSelectionPolicy.isMulti(2))
        XCTAssertTrue(LayerSelectionPolicy.isMulti(5))
    }

    // MARK: Command gating

    func testSingleLayerCommandsAreGated() {
        XCTAssertFalse(LayerSelectionPolicy.gates(.new),
                       "New Layer creates and selects a fresh row, which is safe under a multi-selection")
        for command: EngineSession.LayerCommand in [
            .duplicate, .delete, .raise, .lower, .toTop, .toBottom, .mergeDown,
            .fitToImage, .trimToContent, .rasterize, .restoreSource,
        ] {
            XCTAssertTrue(LayerSelectionPolicy.gates(command),
                          "\(LayerSelectionPolicy.actionTitle(for: command)) must be gated")
            XCTAssertFalse(LayerSelectionPolicy.actionTitle(for: command).isEmpty)
        }
    }

    // MARK: Reconciliation

    func testReconcileDropsStaleAndDuplicateIdsAndKeepsOrder() {
        let existing: Set<Int32> = [1, 2, 3, 4]
        XCTAssertEqual(LayerSelectionPolicy.reconcile([3, 1, 2], existing: existing), [3, 1, 2],
                       "primary-first order survives reconciliation")
        XCTAssertEqual(LayerSelectionPolicy.reconcile([3, 99, 1, 99, 0, 2], existing: existing), [3, 1, 2],
                       "stale, zero and duplicate ids drop out, first occurrence wins")
        XCTAssertEqual(LayerSelectionPolicy.reconcile([99, 98], existing: existing), [])
        XCTAssertEqual(LayerSelectionPolicy.reconcile([], existing: existing), [])
    }

    // MARK: Selection gesture resolution

    func testSingleClickSelectsThatRowAsPrimary() {
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [5], rowIDs: [2]), [2])
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [], rowIDs: [2]), [2])
    }

    func testAddedRowBecomesPrimary() {
        // Shift-click adds row 2 to [5]: the clicked row is primary.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [5], rowIDs: [5, 2]), [2, 5])
        // A shift-range adding 2 and 3 (row order) makes the last added row primary.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [5], rowIDs: [5, 2, 3]), [3, 5, 2])
        // Adding several at once: the bottom-most of the added rows.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [], rowIDs: [4, 2, 3]), [3, 4, 2])
    }

    func testRemovalKeepsPrimaryUnlessItWasRemoved() {
        // Command-click removes a non-primary row: primary stays first.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [3, 5, 2], rowIDs: [3, 2]), [3, 2])
        // Command-click removes the primary: the topmost remaining row takes over.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [3, 5, 2], rowIDs: [5, 2]), [5, 2])
        // Down to a single row: that row, alone.
        XCTAssertEqual(LayerSelectionPolicy.resolveSelection(previous: [3, 5], rowIDs: [5]), [5])
    }

    func testEmptySelectionIsRefusedNotCleared() {
        XCTAssertNil(LayerSelectionPolicy.resolveSelection(previous: [3, 5], rowIDs: []),
                     "an emptied selection refuses; the native selection is restored, never cleared")
    }

    func testResultNeverDuplicatesPrimary() {
        let resolved = LayerSelectionPolicy.resolveSelection(previous: [2], rowIDs: [2, 2])
        XCTAssertEqual(resolved, [2])
    }
    func testFlattenIsAnImageWideCommand() {
        XCTAssertFalse(LayerSelectionPolicy.gates(.flatten), "Flatten Image intentionally acts on the whole image")
    }

}
