import XCTest
@testable import GlimsKit

final class ClipboardImageTests: XCTestCase {
    func testPNGTransferKeepsPixelOrderAndAlpha() throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255,
                           0, 0, 255, 255, 255, 0, 0, 128])
        let source = ClipboardImage(width: 2, height: 2, pixels: pixels, origin: .zero)
        let decoded = try ClipboardImage.decode(source.pngData())
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.pixels, pixels)
    }

    @MainActor
    func testNativeClipboardKeepsColorBitsInNearlyTransparentPixels() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let pixels = Data([101, 3, 230, 128, 255, 10, 101, 1, 20, 40, 80, 0])
        let image = ClipboardImage(width: 3, height: 1, pixels: pixels, origin: CGPoint(x: 5, y: 7))
        try image.encoded().write(to: board)
        XCTAssertEqual(try ClipboardImage.read(from: board).pixels, pixels)
    }

    func testRejectsInvalidOrOversizedBuffers() {
        XCTAssertThrowsError(try ClipboardImage.byteCount(width: Int.max, height: Int.max))
        XCTAssertThrowsError(try ClipboardImage.byteCount(width: 0, height: 1))
        XCTAssertThrowsError(try ClipboardImage.byteCount(width: 524_288, height: 524_288))
        XCTAssertThrowsError(try ClipboardImage(width: 2, height: 2, pixels: Data(), origin: .zero).pngData())
        XCTAssertThrowsError(try ClipboardImage.decode(Data([0, 1, 2])))
    }

    @MainActor
    func testStandardClipboardFormatsAndOriginalPosition() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = ClipboardImage(width: 1, height: 1, pixels: Data([1, 2, 3, 255]), origin: CGPoint(x: 12, y: 34))
        try source.write(to: board)
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(board.data(forType: .tiff))
        let pasted = try ClipboardImage.read(from: board)
        XCTAssertEqual(pasted.pixels, source.pixels)
        XCTAssertEqual(pasted.origin, source.origin)
    }
}
