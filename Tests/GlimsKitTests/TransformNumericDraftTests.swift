import CoreGraphics
import XCTest
@testable import GlimsKit

final class TransformNumericDraftTests: XCTestCase {
    private let first = NSObject()
    private let second = NSObject()
    private func target(_ owner: NSObject, layer: Int32 = 1, generation: UInt64 = 0) -> TransformNumericTarget {
        TransformNumericTarget(document: ObjectIdentifier(owner), layer: layer,
                               original: CGRect(x: 0, y: 0, width: 100, height: 50), generation: generation)
    }

    func testRetargetNeverAdoptsAnUncommittedDraft() {
        var draft = TransformNumericDraft(text: "100")
        draft.begin(target: target(first))
        draft.update("250")
        draft.refresh("50", target: target(second), editing: false)
        XCTAssertEqual(draft.text, "250")
        XCTAssertFalse(draft.canCommit(to: target(second)))
        XCTAssertTrue(draft.canCommit(to: target(first)))
    }

    func testRejectedDraftSurvivesFocusEndAndRefreshUntilCancelled() {
        var draft = TransformNumericDraft(text: "100")
        draft.begin(target: target(first))
        draft.update("-")
        draft.reject("Enter a number.")
        draft.refresh("200", target: target(first), editing: false)
        XCTAssertEqual(draft.text, "-")
        XCTAssertEqual(draft.error, "Enter a number.")
        XCTAssertTrue(draft.hasDraft)
        draft.cancel(text: "200")
        XCTAssertEqual(draft.text, "200")
        XCTAssertFalse(draft.hasDraft)
        XCTAssertNil(draft.error)
    }

    func testCancelAndNewSessionInvalidateCapturedEditEvenOnSameLayer() {
        var draft = TransformNumericDraft(text: "0")
        draft.begin(target: target(first))
        draft.update("25")
        XCTAssertFalse(draft.canCommit(to: target(first, generation: 1)))
        XCTAssertFalse(draft.canCommit(to: target(first, layer: 2)))
    }

    func testUntouchedFocusedFieldFollowsSameTargetAndKeepsCapture() {
        var draft = TransformNumericDraft(text: "100")
        draft.begin(target: target(first))
        draft.refresh("120", target: target(first), editing: true)
        XCTAssertEqual(draft.text, "120")
        XCTAssertFalse(draft.hasDraft)
        XCTAssertTrue(draft.canCommit(to: target(first)))
        draft.refresh("50", target: target(second), editing: true)
        XCTAssertEqual(draft.text, "120")
        XCTAssertFalse(draft.canCommit(to: target(second)))
    }
    func testLeavingAndReturningToSameLayerStillInvalidatesOldDraft() {
        let initial = target(first)
        let returned = TransformNumericTarget(document: initial.document, layer: initial.layer,
                                              original: initial.original, generation: initial.generation,
                                              routeRevision: [2, 2, 0, 0])
        var draft = TransformNumericDraft(text: "100")
        draft.begin(target: initial)
        draft.update("250")
        XCTAssertFalse(draft.canCommit(to: returned))
        XCTAssertEqual(draft.text, "250")
    }

}
