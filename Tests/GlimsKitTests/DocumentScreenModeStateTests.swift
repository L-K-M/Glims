import XCTest
@testable import GlimsKit

final class DocumentScreenModeStateTests: XCTestCase {
    func testCycleHasTheThreeDocumentedStates() {
        XCTAssertEqual(DocumentScreenMode.windowed.next, .fullScreenWithMenu)
        XCTAssertEqual(DocumentScreenMode.fullScreenWithMenu.next, .fullScreenBare)
        XCTAssertEqual(DocumentScreenMode.fullScreenBare.next, .windowed)
    }
    func testEntryIsPendingUntilTheNativeCompletion() {
        var state = DocumentScreenModeState()
        XCTAssertTrue(state.request(.fullScreenWithMenu))
        XCTAssertEqual(state.mode, .windowed)
        XCTAssertEqual(state.phase, .entering)
        XCTAssertFalse(state.request(.fullScreenBare))
        state.willEnter(); state.didEnter()
        XCTAssertEqual(state.mode, .fullScreenWithMenu)
        XCTAssertEqual(state.phase, .stable)
    }
    func testMenuPolicyChangeExitsAndReentersExactlyOnce() {
        var state = DocumentScreenModeState()
        XCTAssertTrue(state.request(.fullScreenWithMenu)); state.didEnter()
        XCTAssertTrue(state.request(.fullScreenBare))
        XCTAssertEqual(state.phase, .exiting)
        XCTAssertTrue(state.didExit())
        XCTAssertEqual(state.requested, .fullScreenBare)
        state.willEnter(); state.didEnter()
        XCTAssertEqual(state.mode, .fullScreenBare)
        XCTAssertTrue(state.request(.windowed))
        XCTAssertFalse(state.didExit())
        XCTAssertEqual(state.mode, .windowed)
    }
    func testExternalFullScreenExitNeverReenters() {
        var state = DocumentScreenModeState()
        state.willEnter(); state.didEnter()
        XCTAssertEqual(state.mode, .fullScreenBare)
        state.willExit()
        XCTAssertEqual(state.phase, .exiting)
        XCTAssertFalse(state.request(.fullScreenWithMenu))
        XCTAssertFalse(state.didExit())
        XCTAssertEqual(state.mode, .windowed)
    }
    func testFailedEntryRestoresWindowedAndAllowsRetry() {
        var state = DocumentScreenModeState()
        XCTAssertTrue(state.request(.fullScreenBare))
        state.failed(isFullScreen: false)
        XCTAssertEqual(state.mode, .windowed)
        XCTAssertEqual(state.phase, .stable)
        XCTAssertTrue(state.request(.fullScreenWithMenu))
    }
    func testFailedExitKeepsTheExistingFullScreenMode() {
        var state = DocumentScreenModeState()
        XCTAssertTrue(state.request(.fullScreenBare)); state.didEnter()
        XCTAssertTrue(state.request(.windowed))
        state.failed(isFullScreen: true)
        XCTAssertEqual(state.mode, .fullScreenBare)
        XCTAssertEqual(state.requested, .fullScreenBare)
    }
    func testOwnedModesApplySynchronouslyWithoutNativeSpaceReentry() {
        var state = DocumentScreenModeState()
        for mode in [DocumentScreenMode.fullScreenWithMenu, .fullScreenBare, .windowed] {
            XCTAssertTrue(state.request(mode))
            state.didApplyOwnedMode()
            XCTAssertEqual(state.mode, mode)
            XCTAssertEqual(state.phase, .stable)
        }
    }
    func testClosePreventsLateReentryAndFurtherCommands() {
        var state = DocumentScreenModeState()
        XCTAssertTrue(state.request(.fullScreenWithMenu)); state.didEnter()
        XCTAssertTrue(state.request(.fullScreenBare)); state.close()
        XCTAssertFalse(state.didExit())
        state.willEnter(); state.didEnter()
        XCTAssertFalse(state.request(.fullScreenBare))
        XCTAssertTrue(state.isClosed)
    }
}
