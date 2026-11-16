import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class EraserBackgroundSnapshotTests: XCTestCase {
    func testEraserSnapshotsBackgroundAtPressWithoutChangingForegroundTools() {
        let state = ToolState()
        state.foreground = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1)
        state.background = NSColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: 1)
        let eraser = state.brush(for: .eraser)
        let pencil = state.brush(for: .pencil)
        state.background = .white
        XCTAssertEqual(eraser.eraserBackground?.red ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(eraser.eraserBackground?.green ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(eraser.eraserBackground?.blue ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertEqual(eraser.red, 0.8, accuracy: 0.0001)
        XCTAssertNil(pencil.eraserBackground)
        XCTAssertEqual(state.brush(for: .eraser).eraserBackground?.red ?? -1, 1, accuracy: 0.0001)
    }
}
