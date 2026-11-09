import XCTest
import CoreGraphics
@testable import GlimsKit

final class DestinationRenderLayoutTests: XCTestCase {
    func testSmallPaddedOriginHasExactLayout() throws {
        let layout = try EngineSession.destinationRenderLayout(scale: 1,
            area: CGRect(x: -3, y: 5, width: 4, height: 2), iccByteCount: 128)
        XCTAssertEqual(layout.rect.x, -3)
        XCTAssertEqual(layout.rect.y, 5)
        XCTAssertEqual(layout.rect.width, 4)
        XCTAssertEqual(layout.stride, 16)
        XCTAssertEqual(layout.bytes, 32)
    }

    func testNegativeSizesAreRefusedWithoutCGRectStandardization() {
        for area in [CGRect(x: 10, y: 10, width: -4, height: 2),
                     CGRect(x: 10, y: 10, width: 4, height: -2)] {
            XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
                area: area, iccByteCount: 128))
        }
    }

    func testInt32SizedDimensionsCannotOverflowTotalByteArithmetic() {
        let side = Double(Int32.max)
        XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
            area: CGRect(x: 0, y: 0, width: side, height: side), iccByteCount: 128))
        XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
            area: CGRect(x: 0, y: 0, width: 100_000, height: 100_000), iccByteCount: 128))
    }

    func testICCSizeAndNonfiniteRequestsRefuseBeforeAnyParsingOrAllocation() {
        for count in [0, -1, 16 * 1024 * 1024 + 1] {
            XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
                area: CGRect(x: 0, y: 0, width: 1, height: 1), iccByteCount: count))
        }
        for scale in [Double.nan, .infinity, 0, -1, 33, 1e-300] {
            XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: scale,
                area: CGRect(x: 0, y: 0, width: 1, height: 1), iccByteCount: 128))
        }
        XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
            area: CGRect(x: 0.5, y: 0, width: 1, height: 1), iccByteCount: 128))
        XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 1,
            area: CGRect(x: Double(Int32.max), y: 0, width: 1, height: 1), iccByteCount: 128))
        XCTAssertThrowsError(try EngineSession.destinationRenderLayout(scale: 0.5,
            area: CGRect(x: 67_108_864, y: 0, width: 1, height: 1), iccByteCount: 128))
    }
}
