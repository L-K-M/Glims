import AppKit
import XCTest
@testable import GlimsKit

/// NSAlert lays out its accessory view at the view's own frame size and
/// does not size it from Auto Layout, so an accessory built from stack
/// views must set its frame or its controls end up zero-sized and
/// invisible on the sheet. These tests lay out the real accessories in an
/// alert without showing it.
@MainActor
final class AlertAccessoryLayoutTests: XCTestCase {

    private func assertLaidOut(_ controls: [NSView], in accessory: NSView,
                               file: StaticString = #filePath, line: UInt = #line) {
        let alert = NSAlert()
        alert.messageText = "Layout"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.layoutIfNeeded()

        let content = alert.window.contentView!.bounds
        for control in controls {
            let frame = control.convert(control.bounds, to: alert.window.contentView)
            XCTAssertGreaterThanOrEqual(frame.width, 40, "\(type(of: control)) is too narrow: \(frame)",
                                        file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 16, "\(type(of: control)) is too short: \(frame)",
                                        file: file, line: line)
            XCTAssertTrue(content.contains(frame), "\(type(of: control)) lies outside the sheet: \(frame)",
                          file: file, line: line)
        }
    }

    func testConvertedCmykCopyAccessoryShowsBothPopups() {
        let form = DocumentWindowController.convertedCopyAccessory(
            profileNames: ["Generic CMYK Profile", "Coated Press"], precision: .u16)
        XCTAssertEqual(form.precisionPopup.indexOfSelectedItem, 1)
        guard let profilePopup = form.profilePopup else {
            return XCTFail("The CMYK copy sheet lost its profile popup")
        }
        assertLaidOut([profilePopup, form.precisionPopup], in: form.view)
    }

    func testConvertedRgbCopyAccessoryShowsThePrecisionPopup() {
        let form = DocumentWindowController.convertedCopyAccessory(profileNames: nil, precision: .float)
        XCTAssertNil(form.profilePopup)
        XCTAssertEqual(form.precisionPopup.indexOfSelectedItem, 2)
        assertLaidOut([form.precisionPopup], in: form.view)
    }
}
