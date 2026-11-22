import AppKit
import XCTest
@testable import GlimsKit

/// Image > Image Size's form: the fields must show the model's real values
/// and the Constrain proportions choice must be inert without resampling.
@MainActor
final class ImageSizeFormTests: XCTestCase {
    private func field(_ label: String, in form: ImageSizeForm) throws -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let match = view as? NSTextField, match.isEditable, match.accessibilityLabel() == label {
                return match
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(form), "Missing field: \(label)")
    }

    private func button(_ title: String, in form: ImageSizeForm) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let match = view as? NSButton, match.title == title { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(form), "Missing button: \(title)")
    }

    func testResolutionShowsItsExactValue() throws {
        let model = try XCTUnwrap(ImageSizeModel(width: 100, height: 50,
                                                 resolutionX: 0.005, resolutionY: 0.005))
        let form = ImageSizeForm(model: model)
        XCTAssertEqual(try field("Resolution", in: form).stringValue, "0.005")
    }

    func testConstrainProportionsFollowsTheResampleChoice() throws {
        let fixed = try XCTUnwrap(ImageSizeModel(width: 100, height: 50,
                                                 resolutionX: 300, resolutionY: 300, resample: false))
        let form = ImageSizeForm(model: fixed)
        XCTAssertFalse(try button("Constrain proportions", in: form).isEnabled)

        try button("Resample image", in: form).performClick(nil)
        XCTAssertTrue(try button("Constrain proportions", in: form).isEnabled)
    }
}
