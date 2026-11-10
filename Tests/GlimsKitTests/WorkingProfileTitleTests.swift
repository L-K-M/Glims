import XCTest
@testable import GlimsKit

@MainActor
final class WorkingProfileTitleTests: XCTestCase {
    func testWorkingProfileIsVisibleWithModeAndPrecision() {
        XCTAssertEqual(DocumentWindowController.title(name: "drawing", zoomPercent: 50,
            isDirty: false, mode: .rgb, precision: "u16-linear", profileLabel: "Studio RGB"),
            "drawing @ 50% (RGB, u16-linear · Studio RGB)")
    }

    func testMissingLabelDoesNotMasqueradeAsADestinationProfile() {
        XCTAssertEqual(DocumentWindowController.title(name: "drawing", zoomPercent: 100,
            isDirty: false, mode: .grayscale, precision: "u8-non-linear", profileLabel: ""),
            "drawing @ 100% (Grayscale, u8-non-linear · Profile unavailable)")
    }

    func testWorkingLabelKeepsDirtyZoomAndRotationState() {
        XCTAssertEqual(DocumentWindowController.title(name: "image.xcf", zoomPercent: 200,
            isDirty: true, mode: .rgb, precision: "float-linear", profileLabel: "RGB Δ", viewRotation: 90),
            "• image.xcf @ 200% (RGB, float-linear · RGB Δ) · View 90°")
    }
}
