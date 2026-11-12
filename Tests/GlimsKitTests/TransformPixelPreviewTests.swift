import CoreGraphics
import XCTest
@testable import GlimsKit

@MainActor
final class TransformPixelPreviewTests: XCTestCase {
    private func request(_ x: Double, revision: UInt64 = 1) -> TransformPixelPreview.Request {
        .init(layer: 1, original: CGRect(x: 0, y: 0, width: 100, height: 100),
              matrix: ProjectiveTransform(affine: CGAffineTransform(translationX: x, y: 0)),
              interpolation: .linear, imageSize: CGSize(width: 100, height: 100), sourceRevision: revision)
    }

    private func pixel() throws -> CGImage {
        let data = Data([UInt8(255), 0, 0, 255])
        return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    func testRapidInputKeepsOnlyLatestWaitingMatrix() throws {
        var requests: [TransformPixelPreview.Request] = []
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = TransformPixelPreview(render: { requests.append($0); replies.append($1) },
                                            changed: {}, failed: { XCTFail("\($0)") })
        preview.update(request(1))
        for x in 2...100 { preview.update(request(Double(x))) }
        XCTAssertEqual(requests, [request(1)])
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(requests, [request(1), request(100)])
        XCTAssertEqual(preview.displayedRequest, request(1))
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(preview.displayedRequest, request(100))
        XCTAssertFalse(preview.isPending)
        preview.update(request(100))
        XCTAssertEqual(requests.count, 2)
    }

    func testCancelRejectsLatePixelsEvenWhenSameGeometryStartsAgain() throws {
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = TransformPixelPreview(render: { _, reply in replies.append(reply) }, changed: {}, failed: { _ in })
        preview.update(request(5))
        preview.update(nil)
        preview.update(request(5))
        replies.removeFirst()(.success(try pixel()))
        XCTAssertNil(preview.image)
        XCTAssertEqual(replies.count, 1)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertNotNil(preview.image)
        preview.update(nil)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.displayedRequest)
        XCTAssertFalse(preview.isPending)
    }

    func testSourceChangeCannotPublishOldPixels() throws {
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = TransformPixelPreview(render: { _, reply in replies.append(reply) }, changed: {}, failed: { _ in })
        preview.update(request(1))
        preview.update(request(2, revision: 2))
        replies.removeFirst()(.success(try pixel()))
        XCTAssertNil(preview.image)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(preview.displayedRequest?.sourceRevision, 2)
        preview.update(request(3, revision: 3))
        XCTAssertNil(preview.image)
    }

    func testFailedRequestDoesNotRetryOnEveryRedraw() {
        var calls = 0, failures = 0
        let preview = TransformPixelPreview(render: { _, reply in
            calls += 1
            reply(.failure(ImageDocument.DocumentError.busy))
        }, changed: {}, failed: { _ in failures += 1 })
        for _ in 0..<100 { preview.update(request(1)) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(preview.isPending)
        preview.update(request(2))
        XCTAssertEqual(calls, 2)
    }

    func testRenderSizeIsBoundedWithoutChangingSourceGeometry() {
        let large = TransformPixelPreview.Request(layer: 1, original: CGRect(x: -20, y: 30, width: 6000, height: 4000),
            matrix: ProjectiveTransform(affine: CGAffineTransform(translationX: 10, y: 0)), interpolation: .cubic,
            imageSize: CGSize(width: 6000, height: 4000), sourceRevision: 1)
        XCTAssertTrue(large.isValid)
        XCTAssertEqual(large.renderScale, 0.256, accuracy: 1e-12)
        XCTAssertEqual(large.outputSize, CGSize(width: 1536, height: 1024))
        XCTAssertEqual(large.original.width, 6000)
        let invalid = TransformPixelPreview.Request(layer: 1, original: large.original, matrix: large.matrix,
            interpolation: .none, imageSize: CGSize(width: Double.infinity, height: 1), sourceRevision: 1)
        XCTAssertFalse(invalid.isValid)
    }

    func testZoomedViewportRendersAtDeviceScaleInsteadOfEnlargingAThumbnail() {
        let viewport = CGRect(x: 3100.25, y: 2100.25, width: 700, height: 450)
        let request = TransformPixelPreview.Request(layer: 1,
            original: CGRect(x: 0, y: 0, width: 6000, height: 4000),
            matrix: ProjectiveTransform(affine: CGAffineTransform(translationX: 10, y: 0)),
            interpolation: .cubic, imageSize: CGSize(width: 6000, height: 4000), sourceRevision: 1,
            maximumEdge: 4096, viewport: viewport, displayScale: 2)
        XCTAssertTrue(request.isValid)
        XCTAssertEqual(request.renderScale, 2)
        XCTAssertEqual(request.renderArea, CGRect(x: 6200, y: 4200, width: 1401, height: 901))
    }

    func testChangingInterpolationNotifiesTheCanvasWithoutAnotherGesture() {
        let state = ToolState.shared
        let saved = state.transformInterpolation
        var changes = 0
        let token = state.observe { changes += 1 }
        defer { state.removeObserver(token); state.transformInterpolation = saved }
        let baseline = changes
        state.transformInterpolation = saved == .none ? .linear : .none
        XCTAssertGreaterThan(changes, baseline)
    }

    func testSynchronousReadsWaitForEveryPreviewWithoutLockingEdits() {
        let activity = EngineActivity()
        var replies: [Int] = []
        activity.beginTransformPreview()
        activity.beginTransformPreview()
        activity.whenReadyForSynchronousRead { replies.append(1) }
        XCTAssertTrue(activity.isRenderingTransformPreview)
        XCTAssertFalse(activity.isBusy)
        XCTAssertTrue(replies.isEmpty)
        activity.endTransformPreview()
        XCTAssertTrue(replies.isEmpty)
        activity.endTransformPreview()
        XCTAssertEqual(replies, [1])
        activity.whenReadyForSynchronousRead { replies.append(2) }
        XCTAssertEqual(replies, [1, 2])
    }

    func testDeferredReadReentrancyKeepsLaterReadsBehindANewPreview() {
        let activity = EngineActivity()
        var replies: [Int] = []
        activity.beginTransformPreview()
        activity.whenReadyForSynchronousRead { replies.append(1); activity.beginTransformPreview() }
        activity.whenReadyForSynchronousRead { replies.append(2) }
        activity.endTransformPreview()
        XCTAssertEqual(replies, [1])
        activity.endTransformPreview()
        XCTAssertEqual(replies, [1, 2])
    }
}
