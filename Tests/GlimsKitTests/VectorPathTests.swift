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

    func testAShapeWithANaNCoordinateStillMatchesItself() {
        // Two copies with their own storage, as a reload of the same path
        // produces; equal arrays sharing storage compare equal without
        // looking at their elements.
        func damaged() -> VectorPath {
            VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: CGFloat.nan, y: 1))])])
        }
        XCTAssertTrue(damaged().isUnchanged(from: damaged()))
        XCTAssertFalse(damaged().isUnchanged(from: triangle()))
    }

    func testTheOutlineScalesAndClosesThroughTheFirstAnchor() {
        let outline = triangle().cgPath(scale: 2)
        XCTAssertEqual(outline.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 200, height: 160))
        XCTAssertTrue(outline.contains(CGPoint(x: 100, y: 40)), "the closed triangle encloses its middle")
    }

    func testMovingASetMovesAnchorsAndHandlesAcrossSubpaths() {
        var path = VectorPath(subpaths: [
            .init(anchors: [.init(CGPoint(x: 0, y: 0)),
                            .init(point: CGPoint(x: 10, y: 0),
                                  handleIn: CGPoint(x: 5, y: 0), handleOut: CGPoint(x: 15, y: 0))]),
            .init(anchors: [.init(CGPoint(x: 100, y: 100))], isClosed: true),
        ])
        let set: Set<Index> = [Index(subpath: 0, anchor: 1), Index(subpath: 1, anchor: 0)]
        path.moveAnchors(set, by: CGSize(width: 3, height: -2))

        let moved = path[Index(subpath: 0, anchor: 1)]
        XCTAssertEqual(moved.point, CGPoint(x: 13, y: -2))
        XCTAssertEqual(moved.handleIn, CGPoint(x: 8, y: -2))
        XCTAssertEqual(moved.handleOut, CGPoint(x: 18, y: -2))
        XCTAssertEqual(path[Index(subpath: 1, anchor: 0)].point, CGPoint(x: 103, y: 98))
        XCTAssertEqual(path[Index(subpath: 0, anchor: 0)].point, CGPoint(x: 0, y: 0),
                       "an anchor outside the set stays put")
        XCTAssertTrue(path.subpaths[1].isClosed, "moving does not change closings")

        path.moveAnchors([Index(subpath: 9, anchor: 0), Index(subpath: 0, anchor: 7)],
                        by: CGSize(width: 1, height: 1))
        XCTAssertEqual(path.anchorCount, 3, "indices naming no anchor are ignored")
    }

    func testRemovingASetDescendsAcrossSubpathsAndDropsAndOpens() {
        var path = VectorPath(subpaths: [
            .init(anchors: [.init(CGPoint(x: 0, y: 0)), .init(CGPoint(x: 10, y: 0)), .init(CGPoint(x: 20, y: 0))],
                  isClosed: true),
            .init(anchors: [.init(CGPoint(x: 100, y: 0))]),
            .init(anchors: [.init(CGPoint(x: 200, y: 0)), .init(CGPoint(x: 210, y: 0))], isClosed: true),
        ])
        let set: Set<Index> = [Index(subpath: 0, anchor: 0), Index(subpath: 0, anchor: 2),
                               Index(subpath: 1, anchor: 0), Index(subpath: 2, anchor: 1)]
        path.removeAnchors(set)

        XCTAssertEqual(path.subpaths.count, 2, "the emptied middle subpath dropped away")
        XCTAssertEqual(path.subpaths[0].anchors.map(\.point), [CGPoint(x: 10, y: 0)])
        XCTAssertFalse(path.subpaths[0].isClosed, "a closed subpath left with one anchor opens")
        XCTAssertEqual(path.subpaths[1].anchors.map(\.point), [CGPoint(x: 200, y: 0)],
                       "the later subpath shifted down by the dropped one")
        XCTAssertFalse(path.subpaths[1].isClosed)

        path.removeAnchors([Index(subpath: 5, anchor: 0)])
        XCTAssertEqual(path.subpaths.count, 2, "indices naming no anchor are ignored")
        path.removeAnchors([Index(subpath: 0, anchor: 0), Index(subpath: 1, anchor: 0)])
        XCTAssertTrue(path.isEmpty, "removing every anchor empties the path")
    }

    func testPruningKeepsOnlyTheIndicesThatStillExist() {
        let path = triangle()
        let pruned = path.pruned([Index(subpath: 0, anchor: 1), Index(subpath: 0, anchor: 9),
                                  Index(subpath: 4, anchor: 0)])
        XCTAssertEqual(pruned, [Index(subpath: 0, anchor: 1)])
    }
}
