import XCTest
@testable import GlimsKit

final class SpringToolLettersStateTests: XCTestCase {
    func testQuickTapPersistsSelectedTool() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.299, selectionRevision: 2))
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testExactThresholdRestoresPreviousTool() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertEqual(state.release(keyCode: 11, at: 1.3, selectionRevision: 2), .move)
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testBackwardsTimestampTreatedAsQuickTap() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 5.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 4.0, selectionRevision: 2))
    }

    func testCanPressRejectsRepeatOrAlreadyHeldKey() {
        var state = SpringToolLettersState()
        XCTAssertTrue(state.canPress(keyCode: 11, isRepeat: false))
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertFalse(state.canPress(keyCode: 11, isRepeat: false))
        XCTAssertFalse(state.canPress(keyCode: 11, isRepeat: true))
        XCTAssertTrue(state.canPress(keyCode: 12, isRepeat: false))
        XCTAssertFalse(state.canPress(keyCode: 12, isRepeat: true))
    }

    func testPointerUsedShortLetterDefersRestoreUntilPointerEnded() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.1, selectionRevision: 2))
        XCTAssertTrue(state.isHeld(keyCode: 11))
        XCTAssertEqual(state.pointerEnded(selectionRevision: 2), .move)
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testPointerEndedBeforeReleaseLeavesHeldOwnerUntilKeyUp() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.pointerEnded(selectionRevision: 2))
        XCTAssertTrue(state.isHeld(keyCode: 11))
        XCTAssertEqual(state.release(keyCode: 11, at: 1.1, selectionRevision: 2), .move)
    }

    func testReleaseMidDragStaysDeferredWhenPointerStillActive() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.05, selectionRevision: 2))
        XCTAssertTrue(state.isHeld(keyCode: 11))
        XCTAssertEqual(state.pointerEnded(selectionRevision: 2), .move)
    }

    func testStaleRevisionSameSelectedToolDoesNotRestore() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.5, selectionRevision: 3))
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testOrdinarySettingNotificationLeavesUnchangedRevisionOwned() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertEqual(state.release(keyCode: 11, at: 1.4, selectionRevision: 2), .move)
    }

    func testOverlappingOwnershipInheritsOriginalBaselineAndConsumesOldRelease() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.press(keyCode: 14, at: 1.1, previous: .paintbrush, previousRevision: 2,
                    selected: .eraser, selectedRevision: 3)
        XCTAssertNil(state.release(keyCode: 11, at: 1.4, selectionRevision: 3))
        XCTAssertTrue(state.isHeld(keyCode: 14))
        XCTAssertEqual(state.release(keyCode: 14, at: 1.5, selectionRevision: 3), .move)
    }

    func testOverlappingQuickTapNewOwnerPersistsAndLeavesOldHarmless() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.press(keyCode: 14, at: 1.1, previous: .paintbrush, previousRevision: 2,
                    selected: .eraser, selectedRevision: 3)
        XCTAssertNil(state.release(keyCode: 14, at: 1.2, selectionRevision: 3))
        XCTAssertNil(state.release(keyCode: 11, at: 1.4, selectionRevision: 3))
    }

    func testStaleOldOwnerGivesNewPressActualPreviousBaseline() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.5, selectionRevision: 5))
        state.press(keyCode: 14, at: 2.0, previous: .crop, previousRevision: 5,
                    selected: .eraser, selectedRevision: 6)
        XCTAssertEqual(state.release(keyCode: 14, at: 2.4, selectionRevision: 6), .crop)
    }

    func testCancelReturnsPriorToolOnlyWhenRevisionOwned() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        XCTAssertEqual(state.cancel(selectionRevision: 2), .move)
        XCTAssertFalse(state.isHeld(keyCode: 11))

        state.press(keyCode: 11, at: 2.0, previous: .move, previousRevision: 2,
                    selected: .eraser, selectedRevision: 3)
        XCTAssertNil(state.cancel(selectionRevision: 4))
    }

    func testCancelDuringPointerActiveCleanupClearsState() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 1.05, selectionRevision: 2))
        XCTAssertEqual(state.cancel(selectionRevision: 2), .move)
        XCTAssertNil(state.pointerEnded(selectionRevision: 2))
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testPromoteClearsOwnershipWithoutRestoring() {
        var state = SpringToolLettersState()
        state.press(keyCode: 17, at: 1.0, previous: .move, previousRevision: 1,
                    selected: .text, selectedRevision: 2)
        state.promote()
        XCTAssertNil(state.release(keyCode: 17, at: 1.6, selectionRevision: 2))
        XCTAssertFalse(state.isHeld(keyCode: 17))
        XCTAssertTrue(state.canPress(keyCode: 17, isRepeat: false))
    }
    func testLongHoldDefersWhileAnotherCapturedToolFinishes() {
        var state = SpringToolLettersState()
        state.pointerBegan(using: .move, selectionRevision: 1)
        state.press(keyCode: 11, at: 0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        // The accepted Move still owns the pointer even though this later
        // letter is only selecting a tool for the next gesture.
        XCTAssertNil(state.release(keyCode: 11, at: 0.3, selectionRevision: 2))
        XCTAssertEqual(state.pointerEnded(selectionRevision: 2), .move)
    }

    func testExplicitSelectionAfterDeferredReleaseWins() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 0.1, selectionRevision: 2))
        XCTAssertNil(state.pointerEnded(selectionRevision: 3))
        XCTAssertFalse(state.isHeld(keyCode: 11))
    }

    func testOverlapKeepsActivePointerAndRestoresOnlyNewestOwner() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        state.press(keyCode: 14, at: 0.1, previous: .paintbrush, previousRevision: 2,
                    selected: .eraser, selectedRevision: 3)
        XCTAssertNil(state.release(keyCode: 11, at: 0.2, selectionRevision: 3))
        XCTAssertNil(state.release(keyCode: 14, at: 0.5, selectionRevision: 3))
        XCTAssertEqual(state.pointerEnded(selectionRevision: 3), .move)
    }

    func testReleasedDeferredKeyCanBePressedAfterNewOwnerFinishes() {
        var state = SpringToolLettersState()
        state.press(keyCode: 11, at: 0, previous: .move, previousRevision: 1,
                    selected: .paintbrush, selectedRevision: 2)
        state.pointerBegan(using: .paintbrush, selectionRevision: 2)
        XCTAssertNil(state.release(keyCode: 11, at: 0.1, selectionRevision: 2))
        state.press(keyCode: 37, at: 0.2, previous: .paintbrush, previousRevision: 2,
                    selected: .lasso, selectedRevision: 3)
        XCTAssertNil(state.pointerEnded(selectionRevision: 3))
        XCTAssertTrue(state.canPress(keyCode: 11, isRepeat: false),
                      "A released key must not remain orphaned behind the newer owner")
        XCTAssertEqual(state.release(keyCode: 37, at: 0.6, selectionRevision: 3), .move,
                       "The newer owner must retain the original chained baseline")
    }

}
