import CGlimsEngine
import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests of the canvas display-destination snapshot/policy: exact ICC
/// byte identity, bounds/non-RGB/missing rejection, the cache-invalidation
/// decision and the honest fallback classification. No AppKit window and no
/// engine is involved, so these do not mirror the snapshot's window access —
/// only its classification rules.
final class CanvasDisplayDestinationTests: XCTestCase {
    private let iccA = Data("profile-A-bytes".utf8)
    private let iccB = Data("profile-B-bytes".utf8)

    // MARK: Classification and bounds

    func testUsableRGBICCWithinCapBecomesWindowProfileWithExactBytes() {
        let destination = CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: .rgb)
        XCTAssertEqual(destination?.kind, .windowProfile)
        XCTAssertEqual(destination?.icc, iccA)
        XCTAssertEqual(destination?.profileICC, iccA)
        XCTAssertFalse(destination?.isFallback ?? true)
    }

    func testMissingNonRGBEmptyAndOversizedICCIsRejected() {
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: nil, colorSpaceModel: .rgb))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: nil))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: nil, colorSpaceModel: nil))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: .cmyk))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: .monochrome))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: .lab))
        XCTAssertNil(CanvasDisplayDestination(validatedWindowICC: Data(), colorSpaceModel: .rgb))
        XCTAssertNil(CanvasDisplayDestination(
            validatedWindowICC: Data(repeating: 0, count: CanvasDisplayDestination.maximumICCBytes + 1),
            colorSpaceModel: .rgb))
        // Exactly at the cap is accepted; one byte less too.
        XCTAssertNotNil(CanvasDisplayDestination(
            validatedWindowICC: Data(repeating: 0, count: CanvasDisplayDestination.maximumICCBytes),
            colorSpaceModel: .rgb))
        XCTAssertNotNil(CanvasDisplayDestination(
            validatedWindowICC: Data(repeating: 0, count: 1), colorSpaceModel: .rgb))
    }

    func testFallbackIsExplicitSRGBWithNoProfileBytes() {
        XCTAssertEqual(CanvasDisplayDestination.srgbFallback.kind, .srgbFallback)
        XCTAssertTrue(CanvasDisplayDestination.srgbFallback.isFallback)
        XCTAssertNil(CanvasDisplayDestination.srgbFallback.profileICC)
        XCTAssertTrue(CanvasDisplayDestination.srgbFallback.icc.isEmpty)
    }

    // MARK: Cache-invalidation decision

    func testSameBytesPreserveCacheAndDifferentBytesInvalidate() {
        let a1 = CanvasDisplayDestination(validatedWindowICC: iccA, colorSpaceModel: .rgb)
        let a2 = CanvasDisplayDestination(validatedWindowICC: Data(iccA), colorSpaceModel: .rgb) // equal copy
        let b = CanvasDisplayDestination(validatedWindowICC: iccB, colorSpaceModel: .rgb)
        XCTAssertEqual(a1, a2)
        XCTAssertFalse(a1!.invalidatesCache(comparedTo: a2!))
        XCTAssertNotEqual(a1, b)
        XCTAssertTrue(a1!.invalidatesCache(comparedTo: b!))
        XCTAssertTrue(a1!.invalidatesCache(comparedTo: .srgbFallback))
        XCTAssertTrue(CanvasDisplayDestination.srgbFallback.invalidatesCache(comparedTo: a1!))
        XCTAssertFalse(CanvasDisplayDestination.srgbFallback.invalidatesCache(comparedTo: .srgbFallback))
    }

    // MARK: Fallback classification

    private func engineError(_ status: Int32) -> EngineSession.EngineError {
        EngineSession.EngineError(status: status, message: "status \(status)")
    }

    func testUnusableProfileTransformStatusesAreClassifiedAsDestinationFailures() {
        // Non-RGB/malformed ICC (UNSUPPORTED) and the LCMS profile error
        // (FAILED) may fall back once to the sRGB render.
        XCTAssertTrue(CanvasDisplayDestination.isUnusableDestination(
            engineError(Int32(GLIMS_STATUS_UNSUPPORTED.rawValue))))
        XCTAssertTrue(CanvasDisplayDestination.isUnusableDestination(
            engineError(Int32(GLIMS_STATUS_FAILED.rawValue))))
    }

    func testStaleCloseBusyAdmissionAndArgumentErrorsAreNotDestinationFailures() {
        // NOT_FOUND (stale image / close), BUSY, admission (LOCKED,
        // REQUIRES_RASTERIZE), INVALID_ARGUMENT and anything else propagate
        // through the normal failure path — never a busy retry loop.
        for status in [GLIMS_STATUS_NOT_FOUND, GLIMS_STATUS_BUSY, GLIMS_STATUS_LOCKED,
                       GLIMS_STATUS_REQUIRES_RASTERIZE, GLIMS_STATUS_INVALID_ARGUMENT,
                       GLIMS_STATUS_NOT_RUNNING, GLIMS_STATUS_CANCELLED, GLIMS_STATUS_OK] {
            XCTAssertFalse(CanvasDisplayDestination.isUnusableDestination(
                engineError(Int32(status.rawValue))),
                "status \(status.rawValue) must not classify as a destination failure")
        }
        XCTAssertFalse(CanvasDisplayDestination.isUnusableDestination(CancellationError()))
        XCTAssertFalse(CanvasDisplayDestination.isUnusableDestination(NSError(domain: "test", code: 1)))
    }
}
