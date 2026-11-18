import XCTest
@testable import GlimsKit

final class LayerAlignmentTests: XCTestCase {
    func testAlignAndDistributeShareTitlesInPhotoshopOrder() {
        let all = EngineSession.LayerAlignment.allCases
        let align = all.filter { !$0.isDistribute }
        let distribute = all.filter(\.isDistribute)
        let titles = ["Top Edges", "Vertical Centers", "Bottom Edges",
                      "Left Edges", "Horizontal Centers", "Right Edges"]
        XCTAssertEqual(align.map(\.title), titles)
        XCTAssertEqual(distribute.map(\.title), titles)
        XCTAssertEqual(all.map(\.rawValue), Array(1...12))
    }
}
