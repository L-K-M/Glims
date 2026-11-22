import XCTest
@testable import GlimsKit

final class SourceAlignmentTests: XCTestCase {
    private typealias Source = EngineSession.Brush.Source
    private let picked = Source(drawable: 4, x: 20.9, y: 40.2)

    func testFirstStrokeUsesThePickedPoint() {
        XCTAssertEqual(SourceAlignment().source(picked, strokeAtX: 100.5, y: 40.5), picked)
    }

    func testLaterStrokesKeepTheFirstDistanceInWholePixels() {
        var alignment = SourceAlignment()
        alignment.strokeStarted(picked, atX: 100.7, y: 10.1)
        XCTAssertEqual(alignment.source(picked, strokeAtX: 140.2, y: 12.9), Source(drawable: 4, x: 60, y: 42))

        alignment.strokeStarted(picked, atX: 140.2, y: 12.9)
        XCTAssertEqual(alignment.source(picked, strokeAtX: 100.7, y: 10.1), Source(drawable: 4, x: 20, y: 40))
    }

    func testPositionsLeftOfTheCanvasRoundDown() {
        var alignment = SourceAlignment()
        alignment.strokeStarted(picked, atX: -0.5, y: 0)
        XCTAssertEqual(alignment.source(picked, strokeAtX: -0.1, y: 0), Source(drawable: 4, x: 20, y: 40))
    }

    func testUnalignedStrokesRestartAtThePickedPoint() {
        var alignment = SourceAlignment()
        alignment.isAligned = false
        alignment.strokeStarted(picked, atX: 100, y: 10)
        XCTAssertEqual(alignment.source(picked, strokeAtX: 140, y: 12), picked)
    }

    func testTurningAlignmentOffOrResettingForgetsTheDistance() {
        var alignment = SourceAlignment()
        alignment.strokeStarted(picked, atX: 100, y: 10)
        alignment.isAligned = false
        alignment.isAligned = true
        XCTAssertEqual(alignment.source(picked, strokeAtX: 140, y: 12), picked)

        alignment.strokeStarted(picked, atX: 100, y: 10)
        alignment.reset()
        XCTAssertEqual(alignment.source(picked, strokeAtX: 140, y: 12), picked)
    }
}
