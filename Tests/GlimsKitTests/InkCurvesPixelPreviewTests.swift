import CoreGraphics
import XCTest
@testable import GlimsKit

@MainActor
final class InkCurvesPixelPreviewTests: XCTestCase {
    private func request(_ samples: [Double], token: UInt64 = 1) -> InkCurvesPixelPreview.Request {
        .init(token: token, settings: .init(samples: samples), imageSize: CGSize(width: 32, height: 24),
              destination: .srgbFallback, proof: nil, viewport: CGRect(x: 0, y: 0, width: 32, height: 24),
              displayScale: 1)
    }

    private func pixel() throws -> CGImage {
        let data = Data([UInt8(127), 0, 0, 255])
        return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }

    func testSampleDraftsAreOwnedAndCoalescedWithoutLosingPrecision() throws {
        var requests: [InkCurvesPixelPreview.Request] = []
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkCurvesPixelPreview(render: { requests.append($0); replies.append($1) },
            changed: {}, failed: { XCTFail("\($0)") })
        var samples = EngineSession.InkCurvesSettings().samples
        let original = request(samples)
        preview.update(original)
        samples[1] = 0.123456789012345
        preview.update(request(samples))
        samples[255] = 0.987654321098765
        let latest = request(samples)
        preview.update(latest)
        samples[1] = 1
        XCTAssertEqual(requests, [original])
        replies.removeFirst()(.success(try pixel()))
        XCTAssertFalse(preview.isCurrent)
        XCTAssertEqual(requests.last, latest)
        XCTAssertEqual(requests.last?.settings.samples[1], 0.123456789012345)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertTrue(preview.isCurrent)
        XCTAssertEqual(preview.displayedRequest, latest)
    }

    func testCancelThenSameCurveOnNewTokenRejectsOldPixels() throws {
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkCurvesPixelPreview(render: { _, reply in replies.append(reply) },
            changed: {}, failed: { XCTFail("\($0)") })
        let samples = [Double](repeating: 0.5, count: 256)
        preview.update(request(samples))
        preview.update(nil)
        preview.update(request(samples, token: 2))
        replies.removeFirst()(.success(try pixel()))
        XCTAssertNil(preview.image)
        XCTAssertFalse(preview.isCurrent)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertTrue(preview.isCurrent)
        XCTAssertEqual(preview.displayedRequest?.token, 2)
    }

    func testMalformedLastSampleCannotBecomeAValidRenderRequest() {
        var samples = [Double](repeating: 0.5, count: 256)
        XCTAssertTrue(request(samples).isValid)
        samples[255] = .nan
        XCTAssertFalse(request(samples).isValid)
        samples[255] = 1.0000001
        XCTAssertFalse(request(samples).isValid)
        XCTAssertFalse(request(Array(samples.dropLast())).isValid)
    }
}
