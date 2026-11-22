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

    func testChangingAUnitClearsAnInvalidEntry() throws {
        let form = ImageSizeForm(model: try XCTUnwrap(ImageSizeModel(width: 100, height: 50,
                                                                     resolutionX: 72, resolutionY: 72)))
        let width = try field("Print width", in: form)
        width.stringValue = "x"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
        XCTAssertFalse(form.isValid)

        let unit = try XCTUnwrap(popUp("Print unit", in: form))
        unit.selectItem(withTitle: "Centimeters")
        _ = unit.sendAction(unit.action, to: unit.target)
        XCTAssertTrue(form.isValid, "the refreshed fields are valid again")
    }

    func testNewKeepsTheSizeWhenTheUnitsChange() throws {
        let panel = NewImagePanel(supportsResolution: true)
        defer { panel.close() }
        let content = try XCTUnwrap(panel.window?.contentView)
        let width = try XCTUnwrap(textField("Width", in: content))
        let resolution = try XCTUnwrap(textField("Resolution", in: content))
        width.stringValue = "720"

        let size = try XCTUnwrap(popUp("Width and height unit", in: content))
        size.selectItem(withTitle: "in")
        _ = size.sendAction(size.action, to: size.target)
        XCTAssertEqual(Double(width.stringValue), 10)

        let unit = try XCTUnwrap(popUp("Resolution unit", in: content))
        unit.selectItem(withTitle: "pixels/cm")
        _ = unit.sendAction(unit.action, to: unit.target)
        XCTAssertEqual(try XCTUnwrap(Double(resolution.stringValue)), 72 / 2.54, accuracy: 1e-4)

        size.selectItem(withTitle: "px")
        _ = size.sendAction(size.action, to: size.target)
        XCTAssertEqual(width.stringValue, "720")
    }

    func testNewAcceptsADecimalComma() {
        let settings = NewImageSettings(width: "2,5", height: "1", sizeUnit: .inches, resolution: "100")
        XCTAssertEqual(settings?.width, 250)
    }

    func testNewPanelShowsEveryRow() throws {
        let panel = NewImagePanel(supportsLab: true, supportsContents: true, supportsResolution: true)
        defer { panel.close() }
        let content = try XCTUnwrap(panel.window?.contentView)
        let modes = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains(NewImageSettings.Kind.cmyk.title) })
        for title in modes.itemTitles {
            modes.selectItem(withTitle: title)
            _ = modes.sendAction(modes.action, to: modes.target)
            content.layoutSubtreeIfNeeded()
            let create = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }
                .first { $0.title == "Create" })
            XCTAssertTrue(content.bounds.contains(create.convert(create.bounds, to: content)),
                          "Create is clipped in \(title)")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func popUp(_ label: String, in view: NSView) -> NSPopUpButton? {
        descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label }
    }

    private func textField(_ label: String, in view: NSView) -> NSTextField? {
        descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.accessibilityLabel() == label }
    }
}
