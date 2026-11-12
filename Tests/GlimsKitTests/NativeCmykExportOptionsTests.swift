import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class NativeCmykExportOptionsTests: XCTestCase {
    func testNativeExportShowsSourceInksAndProfile() {
        var old = ExportSettings()
        old.psdColor = .cmyk
        old.psdLayout = .merged
        let form = ExportOptionsForm(settings: old, context: .nativeCmyk(profileName: "Press profile"))
        XCTAssertTrue(form.settings.permitsNativeCmykPSD)
        XCTAssertEqual(form.formatPopup.titleOfSelectedItem, "PSD")
        XCTAssertEqual(form.psdLayoutPopup.titleOfSelectedItem, "Native ink channels")
        XCTAssertEqual(form.psdColorPopup.titleOfSelectedItem, "Document CMYK")
        XCTAssertEqual(form.psdCmykProfilePopup.titleOfSelectedItem, "Press profile")
        for control in [form.formatPopup, form.psdLayoutPopup, form.psdColorPopup, form.psdCmykProfilePopup] {
            XCTAssertFalse(control.isEnabled)
            XCTAssertFalse(control.isHidden)
        }
        XCTAssertTrue(form.psdExplanation.stringValue.contains("hidden inks"))
        XCTAssertTrue(form.psdExplanation.stringValue.contains("metadata are omitted"))
        XCTAssertTrue(form.commitEditing())
        form.selectFormat(.png)
        XCTAssertEqual(form.settings.format, .psd)
    }

    func testIncompatibleExportSettingsAreRefused() {
        var value = ExportSettings()
        XCTAssertFalse(value.permitsNativeCmykPSD)
        value.format = .psd
        XCTAssertTrue(value.permitsNativeCmykPSD)
        value.psdLayout = .merged
        XCTAssertFalse(value.permitsNativeCmykPSD)
        value.psdLayout = .layers
        value.psdColor = .cmyk
        XCTAssertFalse(value.permitsNativeCmykPSD)
        value.psdColor = .document
        value.jpegQuality = .nan
        XCTAssertFalse(value.permitsNativeCmykPSD)
    }

    func testNativeSavePanelSuggestsPsdEvenWithOldSettings() {
        let export = ExportSavePanel(baseName: "Artwork", settings: ExportSettings(),
                                     context: .nativeCmyk(profileName: "Source profile"))
        XCTAssertEqual(export.panel.nameFieldStringValue, "Artwork.psd")
        XCTAssertEqual(export.panel.allowedContentTypes, [ExportFormat.psd.contentType])
        XCTAssertTrue(export.form.settings.permitsNativeCmykPSD)
    }

    func testOrdinaryExportKeepsExistingFormatChoices() {
        let form = ExportOptionsForm()
        XCTAssertEqual(form.settings.format, .png)
        XCTAssertTrue(form.formatPopup.isEnabled)
        form.selectFormat(.psd)
        XCTAssertTrue(form.psdLayoutPopup.isEnabled)
        XCTAssertTrue(form.psdColorPopup.isEnabled)
        XCTAssertEqual(form.psdLayoutPopup.titleOfSelectedItem, "Layers")
    }
}
