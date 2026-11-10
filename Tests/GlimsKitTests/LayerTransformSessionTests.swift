import CoreGraphics
import XCTest
@testable import GlimsKit

final class LayerTransformSessionTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 50, width: 200, height: 100)

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, accuracy: Double = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
    }

    func testAFreshSessionChangesNothing() {
        let session = LayerTransformSession(layer: 1, bounds: bounds)

        XCTAssertTrue(session.isIdentity)
        XCTAssertTrue(session.matrix.isIdentity)
        assertEqual(session.corners[2], CGPoint(x: 300, y: 150))
    }

    func testHandlesAreFoundByWhereThePressLands() {
        let session = LayerTransformSession(layer: 1, bounds: bounds)

        XCTAssertEqual(session.handle(at: CGPoint(x: 102, y: 52), tolerance: 5), .corner(0))
        XCTAssertEqual(session.handle(at: CGPoint(x: 298, y: 151), tolerance: 5), .corner(2))
        XCTAssertEqual(session.handle(at: CGPoint(x: 200, y: 49), tolerance: 5), .edge(0))
        XCTAssertEqual(session.handle(at: CGPoint(x: 300, y: 100), tolerance: 5), .edge(1))
        XCTAssertEqual(session.handle(at: CGPoint(x: 180, y: 90), tolerance: 5), .move)
        XCTAssertEqual(session.handle(at: CGPoint(x: 400, y: 300), tolerance: 5), .rotate)
    }

    func testStationaryPressAndReturningToItRestoreCapturedGeometry() {
        let handles: [(LayerTransformSession.Handle, CGPoint)] = [
            (.corner(2), CGPoint(x: 298, y: 149)),
            (.edge(1), CGPoint(x: 298, y: 100)),
            (.rotate, CGPoint(x: 400, y: 100))
        ]
        for (handle, press) in handles {
            var session = LayerTransformSession(layer: 1, bounds: bounds)
            let drag = session.beginDrag(handle, at: press)
            session.update(drag, to: press, constrained: true)
            XCTAssertTrue(session.isIdentity)
            session.update(drag, to: CGPoint(x: 450, y: 175), constrained: false)
            XCTAssertFalse(session.isIdentity)
            session.update(drag, to: press, constrained: false)
            XCTAssertTrue(session.isIdentity)
        }
    }

    func testACornerScalesFromTheOppositeCornerAndShiftKeepsTheShape() {
        var session = LayerTransformSession(layer: 1, bounds: bounds)
        let drag = session.beginDrag(.corner(2), at: CGPoint(x: 300, y: 150))

        session.update(drag, to: CGPoint(x: 400, y: 160), constrained: false)
        XCTAssertEqual(session.box, CGRect(x: 100, y: 50, width: 300, height: 110))

        session.update(drag, to: CGPoint(x: 400, y: 160), constrained: true)
        XCTAssertEqual(session.box, CGRect(x: 100, y: 50, width: 300, height: 150))

        // The matrix carries the layer's corners onto the box's.
        let mapped = CGPoint(x: bounds.maxX, y: bounds.maxY).applying(session.matrix)
        assertEqual(mapped, CGPoint(x: 400, y: 200))
    }

    func testAnEdgeScalesOneWayAndCannotCollapseTheBox() {
        var session = LayerTransformSession(layer: 1, bounds: bounds)
        let drag = session.beginDrag(.edge(3), at: CGPoint(x: 100, y: 100))

        session.update(drag, to: CGPoint(x: 50, y: 400), constrained: false)
        XCTAssertEqual(session.box, CGRect(x: 50, y: 50, width: 250, height: 100))

        session.update(drag, to: CGPoint(x: 900, y: 100), constrained: false)
        XCTAssertEqual(session.box.width, LayerTransformSession.minimumSide)
        XCTAssertNotEqual(session.matrix.a * session.matrix.d - session.matrix.b * session.matrix.c, 0)
    }

    func testRotationTurnsAroundTheCenterAndShiftSnapsTo15Degrees() {
        var session = LayerTransformSession(layer: 1, bounds: bounds)
        let center = CGPoint(x: 200, y: 100)
        // From straight right of the center to straight below it: a quarter turn.
        let drag = session.beginDrag(.rotate, at: CGPoint(x: 400, y: 100))

        session.update(drag, to: CGPoint(x: 200, y: 300), constrained: false)
        XCTAssertEqual(session.angle, .pi / 2, accuracy: 1e-9)
        assertEqual(center.applying(session.matrix), center)
        // The top-left corner swings to the top-right side of the turned box.
        assertEqual(session.corners[0], CGPoint(x: 250, y: 0))

        session.update(drag, to: CGPoint(x: 400, y: 150), constrained: true)  // 14°
        XCTAssertEqual(session.angle, .pi / 12, accuracy: 1e-9)
    }

    func testScalingATurnedBoxKeepsItsOppositeCornerStill() {
        var session = LayerTransformSession(layer: 1, bounds: bounds)
        session.update(session.beginDrag(.rotate, at: CGPoint(x: 400, y: 100)),
                       to: CGPoint(x: 200, y: 300), constrained: false)
        let fixed = session.corners[0]
        let dragged = session.corners[2]

        session.update(session.beginDrag(.corner(2), at: dragged),
                       to: CGPoint(x: dragged.x - 30, y: dragged.y + 40), constrained: false)

        assertEqual(session.corners[0], fixed)
        assertEqual(session.corners[2], CGPoint(x: dragged.x - 30, y: dragged.y + 40))
    }

    func testMovingShiftsTheBoxAndKeepsTheTurn() {
        var session = LayerTransformSession(layer: 1, bounds: bounds)
        session.update(session.beginDrag(.rotate, at: CGPoint(x: 400, y: 100)),
                       to: CGPoint(x: 200, y: 300), constrained: false)

        session.update(session.beginDrag(.move, at: CGPoint(x: 200, y: 100)),
                       to: CGPoint(x: 230, y: 90), constrained: false)

        XCTAssertEqual(session.box, bounds.offsetBy(dx: 30, dy: -10))
        XCTAssertEqual(session.angle, .pi / 2, accuracy: 1e-9)
    }
}
