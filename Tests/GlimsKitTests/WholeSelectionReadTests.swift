import XCTest
@testable import GlimsKit

final class WholeSelectionReadTests: XCTestCase {
    func testGrowthNeverPublishesTheTruncatedFirstFill() throws {
        var fills = 0
        let ids = try EngineSession.readWholeSelection { out, capacity, total in
            if out == nil { total = fills == 0 ? 2 : 3; return }
            fills += 1
            total = 3
            for i in 0..<min(Int(capacity), 3) { out![i] = Int32(41 + i) }
        }
        XCTAssertEqual(ids, [41, 42, 43])
        XCTAssertEqual(fills, 2)
    }

    func testRepeatedGrowthRefusesInsteadOfReturningAPartialSelection() {
        XCTAssertThrowsError(try EngineSession.readWholeSelection { out, capacity, total in
            if out == nil { total = 2; return }
            out![0] = 4; out![1] = 5
            total = capacity + 1
        }) { XCTAssertTrue(($0 as? EngineSession.EngineError)?.isBusy == true) }
    }

    func testShrinkReturnsOnlyTheNewSelection() throws {
        let ids = try EngineSession.readWholeSelection { out, _, total in
            if out == nil { total = 3; return }
            out![0] = 7; out![1] = 8; total = 2
        }
        XCTAssertEqual(ids, [7, 8])
    }

    func testMalformedSizesAndIDsRefuseBeforeBecomingTargets() {
        for size: Int32 in [-1, Int32.max] {
            XCTAssertThrowsError(try EngineSession.readWholeSelection { _, _, count in count = size })
        }
        for ids: [Int32] in [[0, 2], [2, 2], [-1, 2]] {
            XCTAssertThrowsError(try EngineSession.readWholeSelection { out, _, total in
                total = 2
                if let out { out[0] = ids[0]; out[1] = ids[1] }
            })
        }
    }
}
