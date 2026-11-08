import AppKit
import XCTest
@testable import GlimsKit

/// Deterministic offscreen raster and edge-preservation tests for the
/// selection marching ants. The engine hands the canvas unordered unit
/// boundary edges on pixel corners; the outline path must join them into
/// continuous contours so the [4, 4] dash phase runs along each contour
/// instead of restarting on every 1 px edge (which makes the black dashes
/// vanish at the off phases on a white image).
@MainActor
final class SelectionOutlineTests: XCTestCase {
    // MARK: Fixtures

    private func segment(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> EngineSession.Segment {
        EngineSession.Segment(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
    }

    /// A long 1 px stair-step diagonal boundary: `steps` horizontal and
    /// `steps` vertical unit edges climbing from (origin, origin).
    private func stairStep(origin: Int, steps: Int) -> [EngineSession.Segment] {
        var segments: [EngineSession.Segment] = []
        for i in 0..<steps {
            let x = origin + i, y = origin + i
            segments.append(segment(x, y, x + 1, y))
            segments.append(segment(x + 1, y, x + 1, y + 1))
        }
        return segments
    }

    /// The edges of the axis-aligned rectangle (x1, y1)-(x2, y2), closed.
    private func rectangle(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> [EngineSession.Segment] {
        [segment(x1, y1, x2, y1), segment(x2, y1, x2, y2),
         segment(x2, y2, x1, y2), segment(x1, y2, x1, y1)]
    }

    /// The pre-fix path builder, kept here as the reference for the bug:
    /// one subpath per raw boundary segment.
    private func rawSubpathPath(for segments: [EngineSession.Segment], scale: Double) -> NSBezierPath {
        let path = NSBezierPath()
        for s in segments {
            path.move(to: NSPoint(x: s.from.x * scale + 0.5, y: s.from.y * scale + 0.5))
            path.line(to: NSPoint(x: s.to.x * scale + 0.5, y: s.to.y * scale + 0.5))
        }
        return path
    }

    // MARK: Offscreen raster helpers

    /// Strokes `path` with the production marching-ants stroker on a
    /// white offscreen bitmap, no window involved.
    private func renderOnWhite(_ size: Int, path: NSBezierPath, phase: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        EngineCanvasView.strokeMarchingAnts(path, phase: phase)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func darkPixels(_ rep: NSBitmapImageRep) -> [(x: Int, y: Int)] {
        var dark: [(x: Int, y: Int)] = []
        let data = rep.bitmapData!
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = data.advanced(by: y * rep.bytesPerRow + x * 4)
                if p[0] < 128, p[1] < 128, p[2] < 128 { dark.append((x, y)) }
            }
        }
        return dark
    }

    private func bitmapData(_ rep: NSBitmapImageRep) -> Data {
        Data(bytes: rep.bitmapData!, count: rep.pixelsHigh * rep.bytesPerRow)
    }

    // MARK: Raster regression: visibility at every dash phase

    /// A long 1 px stair-step diagonal must show a significant black
    /// outline at EVERY dash phase, and the phase must shift the pattern.
    func testStairStepDiagonalStaysVisibleAtEveryPhase() {
        let segments = stairStep(origin: 4, steps: 40) // 80 unit edges, one contour
        let path = SelectionContour.outlinePath(for: segments, scale: 1)
        var counts: [Int] = []
        var bitmaps: [Data] = []
        for phase in 0..<8 {
            let rep = renderOnWhite(48, path: path, phase: CGFloat(phase))
            counts.append(darkPixels(rep).count)
            bitmaps.append(bitmapData(rep))
        }
        for phase in 0..<8 {
            XCTAssertGreaterThanOrEqual(counts[phase], 20,
                                       "phase \(phase): only \(counts[phase]) dark pixels, outline invisible; counts \(counts)")
        }
        // The dash phase really moves the pattern along the contour.
        XCTAssertNotEqual(bitmaps[0], bitmaps[1], "phase 0 and 1 render identically")
        XCTAssertNotEqual(bitmaps[0], bitmaps[4], "phase 0 and 4 render identically")
    }

    /// Documents the root cause: the raw per-segment subpaths all restart
    /// the dash, so at the off phases every 1 px edge is fully inside the
    /// off half and no black is drawn at all (solid black at on phases).
    func testRawPerSegmentSubpathsGoInvisibleAtOffPhases() {
        let segments = stairStep(origin: 4, steps: 40)
        let path = rawSubpathPath(for: segments, scale: 1)
        var counts: [Int] = []
        for phase in 0..<8 {
            counts.append(darkPixels(renderOnWhite(48, path: path, phase: CGFloat(phase))).count)
        }
        XCTAssertGreaterThanOrEqual(counts[0], 60, "on-phase should be solid black, counts \(counts)")
        XCTAssertTrue((4..<8).contains { counts[$0] <= 2 },
                      "expected an off-phase with no black at all, counts \(counts)")
    }

    /// An aligned rectangle must stay a crisp 1 px band at every phase:
    /// no antialiasing bleed next to the expected pixel row/column.
    func testAlignedRectangleStaysCrispAtEveryPhase() {
        let segments = rectangle(5, 5, 15, 15) // symmetric in the 21x21 bitmap
        let path = SelectionContour.outlinePath(for: segments, scale: 1)
        for phase in 0..<8 {
            let dark = darkPixels(renderOnWhite(21, path: path, phase: CGFloat(phase)))
            XCTAssertFalse(dark.isEmpty, "phase \(phase): no black at all")
            for (x, y) in dark {
                let onBand = ((x == 5 || x == 15) && (5...15).contains(y))
                    || ((y == 5 || y == 15) && (5...15).contains(x))
                XCTAssertTrue(onBand, "phase \(phase): dark pixel (\(x), \(y)) outside the crisp 1 px band")
            }
        }
    }

    // MARK: Edge preservation

    private struct IntPoint: Hashable, Comparable {
        let x: Int, y: Int
        init(_ p: CGPoint) { x = Int(p.x.rounded()); y = Int(p.y.rounded()) }
        static func < (l: IntPoint, r: IntPoint) -> Bool { (l.x, l.y) < (r.x, r.y) }
    }

    /// An undirected edge, orientation-normalized so input segment
    /// direction does not matter.
    private struct Edge: Hashable {
        let a: IntPoint, b: IntPoint
        init(_ p: CGPoint, _ q: CGPoint) {
            let u = IntPoint(p), v = IntPoint(q)
            if u <= v { a = u; b = v } else { a = v; b = u }
        }
    }

    private func edgeCounts(_ segments: [EngineSession.Segment]) -> [Edge: Int] {
        var counts: [Edge: Int] = [:]
        for s in segments { counts[Edge(s.from, s.to), default: 0] += 1 }
        return counts
    }

    private func edgeCounts(of contours: [SelectionContour.Contour]) -> [Edge: Int] {
        var counts: [Edge: Int] = [:]
        for contour in contours {
            let points = contour.isClosed ? contour.points + [contour.points[0]] : contour.points
            for i in 0..<points.count - 1 {
                counts[Edge(points[i], points[i + 1]), default: 0] += 1
            }
        }
        return counts
    }

    private func scrambled(_ segments: [EngineSession.Segment]) -> [EngineSession.Segment] {
        // Deterministic permutation plus reversed directions: the
        // contour builder must not depend on input order or orientation.
        var result: [EngineSession.Segment] = []
        let reversed = segments.reversed()
        for (i, s) in reversed.enumerated() {
            result.append(i.isMultiple(of: 2) ? s : EngineSession.Segment(from: s.to, to: s.from))
        }
        return result
    }

    /// Disconnected regions, a hole, permuted and reversed input: every
    /// undirected edge exactly once, one closed contour per region.
    func testDisconnectedRegionsAndHolesPreserveEveryEdgeExactlyOnce() {
        var input = rectangle(2, 2, 10, 10)          // outer boundary
        input += rectangle(4, 4, 6, 6)               // hole
        input += rectangle(14, 14, 16, 16)           // disconnected region
        let contours = SelectionContour.contours(from: scrambled(input))
        XCTAssertEqual(contours.count, 3)
        XCTAssertTrue(contours.allSatisfy(\.isClosed))
        XCTAssertEqual(edgeCounts(of: contours), edgeCounts(input))
    }

    /// An open chain stays a single open contour with its edges intact.
    func testOpenChainStaysOpenAndKeepsEveryEdge() {
        let input = [segment(0, 0, 1, 0), segment(2, 1, 1, 1), segment(1, 1, 1, 0)]
        let contours = SelectionContour.contours(from: scrambled(input))
        XCTAssertEqual(contours.count, 1)
        XCTAssertFalse(contours[0].isClosed)
        XCTAssertEqual(edgeCounts(of: contours), edgeCounts(input))
    }

    /// A diagonal touch (two diagonally adjacent selected pixels) puts
    /// four edges on one shared corner: the walk must branch without
    /// losing or doubling any edge, as two separate closed loops.
    func testDiagonalTouchBranchKeepsEveryEdgeExactlyOnce() {
        let input = [segment(0, 0, 1, 0), segment(1, 0, 1, 1), segment(1, 1, 0, 1), segment(0, 1, 0, 0),
                     segment(1, 1, 2, 1), segment(2, 1, 2, 2), segment(2, 2, 1, 2), segment(1, 2, 1, 1)]
        let contours = SelectionContour.contours(from: scrambled(input))
        XCTAssertEqual(contours.count, 2, "diagonal regions must stay separate loops")
        XCTAssertTrue(contours.allSatisfy(\.isClosed))
        XCTAssertEqual(edgeCounts(of: contours), edgeCounts(input))
    }

    /// The builder only reads its input.
    func testInputSegmentsAreNotMutated() {
        let input = scrambled(rectangle(2, 2, 9, 7) + stairStep(origin: 12, steps: 5))
        let copy = input
        _ = SelectionContour.contours(from: input)
        _ = SelectionContour.outlinePath(for: input, scale: 2)
        XCTAssertEqual(input, copy)
    }

    // MARK: Path mapping

    private func pathElements(_ path: NSBezierPath) -> [(NSBezierPath.ElementType, CGPoint)] {
        var result: [(NSBezierPath.ElementType, CGPoint)] = []
        var points = [NSPoint](repeating: .zero, count: 1)
        for i in 0..<path.elementCount {
            let type = path.element(at: i, associatedPoints: &points)
            result.append((type, points[0]))
        }
        return result
    }

    /// Image-pixel corners map to view points at `scale` plus the half
    /// point that keeps a 1 pt line crisp; closed contours close.
    func testPathMapsImagePixelsToViewPointsWithHalfPointCrispness() {
        let open = pathElements(SelectionContour.outlinePath(for: [segment(2, 3, 7, 3)], scale: 2))
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open[0].0.rawValue, NSBezierPath.ElementType.moveTo.rawValue)
        XCTAssertEqual(open[0].1, CGPoint(x: 4.5, y: 6.5))
        XCTAssertEqual(open[1].0.rawValue, NSBezierPath.ElementType.lineTo.rawValue)
        XCTAssertEqual(open[1].1, CGPoint(x: 14.5, y: 6.5))
        let closed = pathElements(SelectionContour.outlinePath(for: rectangle(1, 1, 4, 4), scale: 1))
        XCTAssertEqual(closed.first?.0.rawValue, NSBezierPath.ElementType.moveTo.rawValue)
        XCTAssertEqual(closed.first?.1, CGPoint(x: 1.5, y: 1.5))
        // A closed contour is one subpath ending in a close element
        // (NSBezierPath appends an empty trailing move after close()).
        XCTAssertEqual(closed.filter { $0.0.rawValue == NSBezierPath.ElementType.closePath.rawValue }.count, 1)
        XCTAssertEqual(closed.filter { $0.0.rawValue == NSBezierPath.ElementType.lineTo.rawValue }.count, 3)
    }
}
