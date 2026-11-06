import CoreGraphics
import XCTest
@testable import GlimsKit

final class VectorPathTests: XCTestCase {
    private typealias Index = VectorPath.AnchorIndex

    private func triangle() -> VectorPath {
        VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 0, y: 0)), .init(CGPoint(x: 100, y: 0)),
                                              .init(CGPoint(x: 50, y: 80))], isClosed: true)])
    }

    func testPullingHandlesMakesASmoothAnchorAndMovingKeepsItsShape() {
        var anchor = VectorPath.Anchor(CGPoint(x: 10, y: 10))
        XCTAssertTrue(anchor.isCorner)

        anchor.pullHandles(to: CGPoint(x: 30, y: 15))
        XCTAssertEqual(anchor.handleOut, CGPoint(x: 30, y: 15))
        XCTAssertEqual(anchor.handleIn, CGPoint(x: -10, y: 5))
        XCTAssertFalse(anchor.isCorner)

        anchor.move(by: CGSize(width: 5, height: -5))
        XCTAssertEqual(anchor.point, CGPoint(x: 15, y: 5))
        XCTAssertEqual(anchor.handleIn, CGPoint(x: -5, y: 0))
        XCTAssertEqual(anchor.handleOut, CGPoint(x: 35, y: 10))
    }

    func testAnchorsWinOverHandlesAndHandlesShowOnlyWhereAsked() {
        var path = triangle()
        let second = Index(subpath: 0, anchor: 1)
        path[second].pullHandles(to: CGPoint(x: 130, y: 0))

        XCTAssertEqual(path.part(at: CGPoint(x: 101, y: 1), tolerance: 4, handlesOf: [second]), .anchor(second))
        XCTAssertEqual(path.part(at: CGPoint(x: 129, y: 0), tolerance: 4, handlesOf: [second]), .handleOut(second))
        XCTAssertEqual(path.part(at: CGPoint(x: 71, y: 0), tolerance: 4, handlesOf: [second]), .handleIn(second))
        XCTAssertNil(path.part(at: CGPoint(x: 129, y: 0), tolerance: 4, handlesOf: []),
                     "handles of anchors not asked for are not grabbable")
        XCTAssertNil(path.part(at: CGPoint(x: 50, y: 30), tolerance: 4, handlesOf: [second]))
    }

    func testTheNearestOfTwoCloseAnchorsIsTheOneGrabbed() {
        let path = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 0, y: 0)), .init(CGPoint(x: 6, y: 0))])])
        XCTAssertEqual(path.part(at: CGPoint(x: 4, y: 0), tolerance: 5, handlesOf: []),
                       .anchor(Index(subpath: 0, anchor: 1)))
    }

    func testRemovingAnchorsOpensAndThenDropsTheSubpath() {
        var path = triangle()
        path.removeAnchor(at: Index(subpath: 0, anchor: 2))
        XCTAssertEqual(path.subpaths[0].anchors.count, 2)
        XCTAssertTrue(path.subpaths[0].isClosed)

        path.removeAnchor(at: Index(subpath: 0, anchor: 1))
        XCTAssertFalse(path.subpaths[0].isClosed, "one anchor cannot enclose anything")

        path.removeAnchor(at: Index(subpath: 0, anchor: 0))
        XCTAssertTrue(path.isEmpty)
        path.removeAnchor(at: Index(subpath: 0, anchor: 0))
    }

    func testReversingASubpathSwapsEachAnchorsHandles() {
        var path = VectorPath(subpaths: [.init(anchors: [
            .init(point: CGPoint(x: 0, y: 0), handleIn: CGPoint(x: -1, y: 0), handleOut: CGPoint(x: 1, y: 0)),
            .init(CGPoint(x: 10, y: 0)),
        ])])
        path.reverseSubpath(0)

        XCTAssertEqual(path.subpaths[0].anchors.map(\.point), [CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 0)])
        XCTAssertEqual(path.subpaths[0].anchors[1].handleIn, CGPoint(x: 1, y: 0))
        XCTAssertEqual(path.subpaths[0].anchors[1].handleOut, CGPoint(x: -1, y: 0))
    }

    func testTheOutlineScalesAndClosesThroughTheFirstAnchor() {
        let outline = triangle().cgPath(scale: 2)
        XCTAssertEqual(outline.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 200, height: 160))
        XCTAssertTrue(outline.contains(CGPoint(x: 100, y: 40)), "the closed triangle encloses its middle")
    }
}
