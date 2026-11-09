import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class CanvasRotationViewTests: XCTestCase {
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private let eps: CGFloat = 1e-4

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    private func assertRoundTrip(_ host: CanvasRotationView, _ point: NSPoint, file: StaticString = #filePath, line: UInt = #line) {
        let mapped = host.canvas.convert(point, to: host)
        let back = host.canvas.convert(mapped, from: host)
        XCTAssertTrue(near(point, back), "\(point) -> \(mapped) -> \(back)", file: file, line: line)
    }

    func testRotated90LayoutAndKnownCorners() {
        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let host = CanvasRotationView(canvas: canvas)
        host.setRotationDegrees(90)
        XCTAssertEqual(host.frame.size.width, 100, accuracy: eps)
        XCTAssertEqual(host.frame.size.height, 200, accuracy: eps)
        let corners = [(NSPoint(x: 0, y: 0), NSPoint(x: 100, y: 0)),
                       (NSPoint(x: 200, y: 0), NSPoint(x: 100, y: 200)),
                       (NSPoint(x: 0, y: 100), NSPoint(x: 0, y: 0))]
        for (image, expectedHost) in corners {
            let mapped = canvas.convert(image, to: host)
            XCTAssertTrue(near(mapped, expectedHost), "\(image) -> \(mapped)")
            assertRoundTrip(host, image)
        }
    }

    func testArbitraryAnglesAndNonfinite() {
        let host45 = CanvasRotationView(canvas: FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        host45.setRotationDegrees(45)
        let side = 300 / sqrt(2.0)
        XCTAssertEqual(host45.frame.size.width, side, accuracy: 1e-3)
        XCTAssertEqual(host45.frame.size.height, side, accuracy: 1e-3)

        let hostNeg = CanvasRotationView(canvas: FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        hostNeg.setRotationDegrees(-45)
        let corners = [NSPoint(x: 0, y: 0), NSPoint(x: 200, y: 0), NSPoint(x: 200, y: 100), NSPoint(x: 0, y: 100)]
        for corner in corners { assertRoundTrip(hostNeg, corner) }

        let host = CanvasRotationView(canvas: FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        host.setRotationDegrees(30)
        let before = host.frame
        XCTAssertFalse(host.setRotationDegrees(.nan))
        XCTAssertEqual(host.rotationDegrees, 30, accuracy: 1e-9)
        XCTAssertEqual(host.frame, before)
        host.setRotationDegrees(360)
        XCTAssertEqual(host.rotationDegrees, 0, accuracy: 1e-9)
    }

    func testResizeRefreshHitTestAndLifecycle() {
        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        weak var weakHost: CanvasRotationView?
        autoreleasepool {
            let host = CanvasRotationView(canvas: canvas)
            weakHost = host
            host.setRotationDegrees(90)
            canvas.setFrameSize(NSSize(width: 220, height: 110))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            XCTAssertEqual(canvas.bounds.size.width, 220, accuracy: eps)
            XCTAssertEqual(canvas.bounds.size.height, 110, accuracy: eps)
            XCTAssertEqual(host.frame.size.width, 110, accuracy: eps)
            XCTAssertEqual(host.frame.size.height, 220, accuracy: eps)
            let points = [NSPoint(x: 0, y: 0), NSPoint(x: 220, y: 0), NSPoint(x: 220, y: 110), NSPoint(x: 0, y: 110)]
                .map { canvas.convert($0, to: host) }
            let xs = points.map(\.x); let ys = points.map(\.y)
            XCTAssertTrue((xs.min() ?? 0) >= -eps && (ys.min() ?? 0) >= -eps)
            XCTAssertTrue((xs.max() ?? 0) <= host.frame.width + eps && (ys.max() ?? 0) <= host.frame.height + eps)
            let hit = NSPoint(x: 55, y: 110)
            XCTAssertFalse(canvas.frame.contains(hit), "the native rotated hit lies outside the unrotated frame")
            XCTAssertTrue(host.hitTest(hit) === canvas)
            var notifications = 0
            let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: canvas, queue: .main) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            host.layoutCanvas()
            let settled = notifications
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertEqual(notifications, settled, "layout must not enqueue a repeating frame-notification cycle")
        }
        XCTAssertNil(weakHost)
        XCTAssertNil(canvas.superview)
        canvas.setFrameSize(NSSize(width: 300, height: 150))
    }
}
