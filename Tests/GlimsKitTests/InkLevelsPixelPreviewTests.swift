import CoreGraphics
import XCTest
@testable import GlimsKit

@MainActor
final class InkLevelsPixelPreviewTests: XCTestCase {
    private func request(_ gamma: Double, token: UInt64 = 1,
                         viewport: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> InkLevelsPixelPreview.Request {
        .init(token: token, settings: .init(value: .init(gamma: gamma)),
              imageSize: CGSize(width: 6000, height: 4000), destination: .srgbFallback,
              proof: nil, viewport: viewport, displayScale: 2)
    }

    private func pixel() throws -> CGImage {
        let data = Data([UInt8(255), 0, 0, 255])
        return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    func testRapidDraftsCoalesceAndOnlyLatestCompletedSettingsCanApply() throws {
        var requests: [InkLevelsPixelPreview.Request] = []
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkLevelsPixelPreview(render: { requests.append($0); replies.append($1) },
                                            changed: {}, failed: { XCTFail("\($0)") })
        preview.update(request(1))
        for n in 2...100 { preview.update(request(Double(n) / 10)) }
        XCTAssertEqual(requests, [request(1)])
        XCTAssertFalse(preview.isCurrent)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(requests, [request(1), request(10)])
        XCTAssertFalse(preview.isCurrent)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertTrue(preview.isCurrent)
        XCTAssertEqual(preview.displayedRequest, request(10))
        preview.update(request(10))
        XCTAssertEqual(requests.count, 2)
    }

    func testCanceledAndReopenedPanelRejectsLatePixels() throws {
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkLevelsPixelPreview(render: { _, reply in replies.append(reply) }, changed: {}, failed: { _ in })
        preview.update(request(2))
        preview.update(nil)
        preview.update(request(2, token: 2))
        replies.removeFirst()(.success(try pixel()))
        XCTAssertNil(preview.image)
        XCTAssertFalse(preview.isCurrent)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(preview.displayedRequest?.token, 2)
        XCTAssertTrue(preview.isCurrent)
        preview.update(nil)
        XCTAssertNil(preview.image)
        XCTAssertFalse(preview.isPending)
    }

    func testPanCannotReusePixelsFromAnotherViewport() throws {
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkLevelsPixelPreview(render: { _, reply in replies.append(reply) }, changed: {}, failed: { _ in })
        preview.update(request(2))
        replies.removeFirst()(.success(try pixel()))
        preview.update(request(2, viewport: CGRect(x: 100, y: 100, width: 100, height: 100)))
        XCTAssertNil(preview.image)
        XCTAssertFalse(preview.isCurrent)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertEqual(preview.displayedRequest?.renderArea.origin, CGPoint(x: 200, y: 200))
        XCTAssertTrue(preview.isCurrent)
    }

    func testFailureStaysVisibleWithoutRetryingEveryRedraw() {
        var calls = 0
        var status = ""
        let preview = InkLevelsPixelPreview(render: { _, reply in
            calls += 1
            reply(.failure(ImageDocument.DocumentError.busy))
        }, changed: { status = "changed" }, failed: { _ in status = "failed" })
        for _ in 0..<100 { preview.update(request(2)) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(status, "failed")
        XCTAssertFalse(preview.isPending)
        XCTAssertFalse(preview.isCurrent)
    }

    func testExplicitRetryCanRestoreCurrentPreviewAfterApplyRefusal() throws {
        var calls = 0, notifications = 0
        var reply: (@MainActor (Result<CGImage, Error>) -> Void)?
        let preview = InkLevelsPixelPreview(render: { _, completion in calls += 1; reply = completion },
            changed: { notifications += 1 }, failed: { _ in XCTFail("unexpected render failure") })
        preview.update(request(2))
        reply?(.success(try pixel()))
        let previous = notifications
        preview.update(request(2), retryFailure: true)
        XCTAssertEqual(notifications, previous + 1, "Republish current pixels after a transient Apply refusal")
        XCTAssertEqual(calls, 1, "An unchanged successful preview needs no recalculation")
        XCTAssertTrue(preview.isCurrent)
    }

    func testSupersededFailureDoesNotOverwriteNewDraftStatus() throws {
        var failures = 0
        var replies: [(@MainActor (Result<CGImage, Error>) -> Void)] = []
        let preview = InkLevelsPixelPreview(render: { _, reply in replies.append(reply) },
                                            changed: {}, failed: { _ in failures += 1 })
        preview.update(request(2))
        preview.update(request(3))
        replies.removeFirst()(.failure(ImageDocument.DocumentError.busy))
        XCTAssertEqual(failures, 0)
        replies.removeFirst()(.success(try pixel()))
        XCTAssertTrue(preview.isCurrent)
    }

    func testBoundedRenderPreservesZoomedPixelsAndRejectsInvalidRequests() {
        let zoomed = request(2, viewport: CGRect(x: 3100.25, y: 2100.25, width: 700, height: 450))
        XCTAssertTrue(zoomed.isValid)
        XCTAssertEqual(zoomed.renderScale, 2)
        XCTAssertEqual(zoomed.renderArea, CGRect(x: 6200, y: 4200, width: 1401, height: 901))
        let full = request(2, viewport: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        XCTAssertTrue(full.isValid)
        XCTAssertEqual(full.renderArea.width, 2048)
        XCTAssertFalse(request(.nan).isValid)
        XCTAssertFalse(request(2, token: 0).isValid)
        XCTAssertFalse(request(2, viewport: CGRect(x: -1, y: 0, width: 100, height: 100)).isValid)
    }
}
