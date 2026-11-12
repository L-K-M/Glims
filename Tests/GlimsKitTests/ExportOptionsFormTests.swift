import AppKit
import XCTest
@testable import GlimsKit

/// The export options value types and the Export ▸ options form as it
/// behaves without a running engine or a window: defaults, extension
/// aliases, the validation gate, format-switch retention, real control
/// actions and the refusal of invalid field input. How the controller
/// hands the settings to a save panel and the engine is covered
/// elsewhere.
@MainActor
final class ExportOptionsFormTests: XCTestCase {

    /// Sends a control's wired action to its target, the same dispatch a
    /// click performs — popups, checkboxes and sliders alike.
    private func fire(_ control: NSControl) {
        guard let action = control.action else { return XCTFail("control has no action") }
        XCTAssertTrue(control.sendAction(action, to: control.target))
    }

    // MARK: Defaults and aliases

    func testDefaultsArePngCenteredAndValid() {
        let settings = ExportSettings()
        XCTAssertEqual(settings.format, .png)
        XCTAssertEqual(settings.jpegQuality, 0.9, accuracy: 1e-9)
        XCTAssertTrue(settings.jpegProgressive)
        XCTAssertTrue(settings.jpegOptimize)
        XCTAssertEqual(settings.jpegSubsampling, .full)
        XCTAssertEqual(settings.pngCompression, 9)
        XCTAssertFalse(settings.pngInterlaced)
        XCTAssertFalse(settings.pngPreserveTransparentColor)
        XCTAssertEqual(settings.tiffCompression, .none)
        XCTAssertTrue(settings.tiffPreserveTransparentColor)
        XCTAssertTrue(ExportSettings.validate(settings))
    }

    func testEveryFormatHasATitleAndAnExtensionThatParsesBack() {
        XCTAssertEqual(ExportFormat.allCases, [.png, .jpeg, .tiff, .psd, .gif])
        for format in ExportFormat.allCases {
            XCTAssertFalse(format.title.isEmpty)
            XCTAssertFalse(format.preferredExtension.isEmpty)
            XCTAssertEqual(ExportFormat.forFileExtension(format.preferredExtension), format,
                           "\(format)'s preferred extension must resolve to itself")
        }
    }

    func testFileExtensionAliasesAreCaseInsensitive() {
        XCTAssertEqual(ExportFormat.forFileExtension("png"), .png)
        XCTAssertEqual(ExportFormat.forFileExtension("PNG"), .png)
        for ext in ["jpg", "jpeg", "JPG", "JPEG", "jPg"] {
            XCTAssertEqual(ExportFormat.forFileExtension(ext), .jpeg, ext)
        }
        for ext in ["tif", "tiff", "TIF", "TIFF"] {
            XCTAssertEqual(ExportFormat.forFileExtension(ext), .tiff, ext)
        }
    }

    func testUnknownAndEmptyExtensionsGetNoFormat() {
        for ext in ["", "webp", "pngg", "jpe", "tiff2", " png", "png "] {
            XCTAssertNil(ExportFormat.forFileExtension(ext), ext)
        }
    }

    func testGifShowsItsConversionPolicyAndIgnoresHiddenDrafts() {
        let form = ExportOptionsForm()
        XCTAssertTrue(form.gifExplanation.isHidden)
        form.compressionRow.field.stringValue = "bad draft"
        XCTAssertFalse(form.commitEditing())
        for ext in ["gif", "GIF", ".GiF"] { XCTAssertEqual(ExportFormat.forFileExtension(ext), .gif) }
        form.selectFormat(.gif)
        XCTAssertFalse(form.gifExplanation.isHidden)
        XCTAssertTrue(form.psdLayoutPopup.isHidden)
        XCTAssertTrue(form.gifExplanation.stringValue.contains("256 colors"))
        XCTAssertTrue(form.gifExplanation.stringValue.contains("50% opacity"))
        XCTAssertTrue(form.commitEditing())
        form.selectFormat(.psd)
        XCTAssertTrue(form.gifExplanation.isHidden)
        XCTAssertFalse(form.psdLayoutPopup.isHidden)
        form.selectFormat(.gif)
        XCTAssertTrue(form.commitEditing())
    }

    func testPsdContentChoiceSurvivesOtherFormatEdits() {
        let form = ExportOptionsForm()
        XCTAssertTrue(form.psdLayoutPopup.isHidden)
        for ext in ["psd", "PSD", ".PsD"] { XCTAssertEqual(ExportFormat.forFileExtension(ext), .psd) }
        form.selectFormat(.psd)
        XCTAssertFalse(form.psdLayoutPopup.isHidden)
        XCTAssertFalse(form.psdExplanation.isHidden)
        XCTAssertEqual(form.settings.psdLayout, .layers)
        XCTAssertTrue(form.psdExplanation.stringValue.contains("blending may change"))
        form.psdLayoutPopup.selectItem(at: 1)
        fire(form.psdLayoutPopup)
        XCTAssertEqual(form.settings.psdLayout, .merged)
        XCTAssertTrue(form.psdExplanation.stringValue.contains("transparency"))
        form.selectFormat(.png)
        form.compressionRow.field.stringValue = "bad draft"
        XCTAssertFalse(form.commitEditing())
        form.selectFormat(.psd)
        XCTAssertTrue(form.commitEditing(), "an unrelated hidden field draft cannot block PSD")
        XCTAssertEqual(form.settings.psdLayout, .merged)
        XCTAssertEqual(form.psdLayoutPopup.indexOfSelectedItem, 1)
    }

    // MARK: Validation gate

    func testValidateEnforcesTheTypedQualityRange() {
        var settings = ExportSettings()
        for quality in [0.0, 0.5, 1.0] {
            settings.jpegQuality = quality
            XCTAssertTrue(ExportSettings.validate(settings), "quality \(quality) is in range")
        }
        for quality in [-0.001, 1.001, -1.0, 2.0] {
            settings.jpegQuality = quality
            XCTAssertFalse(ExportSettings.validate(settings), "quality \(quality) is out of range")
        }
    }

    func testValidateRefusesNonfiniteQuality() {
        var settings = ExportSettings()
        for quality in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            settings.jpegQuality = quality
            XCTAssertFalse(ExportSettings.validate(settings), "quality \(quality) is not finite")
        }
    }

    func testValidateEnforcesTheWholeCompressionRange() {
        var settings = ExportSettings()
        settings.pngCompression = 0
        XCTAssertTrue(ExportSettings.validate(settings))
        settings.pngCompression = 9
        XCTAssertTrue(ExportSettings.validate(settings))
        for level in [-1, 10, 256] {
            settings.pngCompression = level
            XCTAssertFalse(ExportSettings.validate(settings), "compression \(level) is out of range")
        }
    }

    // MARK: Choice lists

    func testSubsamplingTitlesAreTheChromaRatios() {
        XCTAssertEqual(ExportSettings.JpegSubsampling.allCases.map(\.title),
                       ["4:4:4", "4:2:2", "4:4:0", "4:2:0"])
        XCTAssertEqual(ExportSettings.JpegSubsampling.allCases,
                       [.full, .horizontal, .vertical, .both])
    }

    func testTiffCompressionTitles() {
        XCTAssertEqual(ExportSettings.TiffCompression.allCases.map(\.title),
                       ["None", "LZW", "Deflate", "Pack Bits"])
        XCTAssertEqual(ExportSettings.TiffCompression.allCases, [.none, .lzw, .deflate, .packBits])
    }

    // MARK: Seeding and format swaps

    func testTheFormSeedsItsControlsFromTheSettings() {
        var seed = ExportSettings()
        seed.format = .jpeg
        seed.jpegQuality = 0.75
        seed.jpegOptimize = false
        seed.jpegSubsampling = .both
        let form = ExportOptionsForm(settings: seed)
        XCTAssertEqual(form.settings, seed)
        XCTAssertEqual(form.formatPopup.indexOfSelectedItem,
                       ExportFormat.allCases.firstIndex(of: .jpeg))
        XCTAssertEqual(form.qualityRow.field.stringValue, "75")
        XCTAssertEqual(form.optimizeBox.state, .off)
        XCTAssertEqual(form.progressiveBox.state, .on)
        XCTAssertEqual(form.subsamplingPopup.indexOfSelectedItem, 3)
        XCTAssertTrue(form.commitEditing(), "a seeded valid form commits")
    }

    func testOnlyTheCurrentFormatsControlsAreVisible() {
        let form = ExportOptionsForm()
        XCTAssertFalse(form.compressionRow.isHidden, "PNG is the default format")
        XCTAssertTrue(form.qualityRow.isHidden)
        XCTAssertTrue(form.subsamplingPopup.isHidden)
        XCTAssertTrue(form.tiffCompressionPopup.isHidden)
    }

    func testTheFormatPopupActionReportsAndSwaps() {
        let form = ExportOptionsForm()
        var reported: [ExportFormat] = []
        form.onFormatChange = { reported.append($0) }

        form.formatPopup.selectItem(at: 1)
        fire(form.formatPopup)
        XCTAssertEqual(reported, [.jpeg])
        XCTAssertEqual(form.settings.format, .jpeg)
        XCTAssertFalse(form.qualityRow.isHidden)
        XCTAssertTrue(form.compressionRow.isHidden)

        form.formatPopup.selectItem(at: 2)
        fire(form.formatPopup)
        XCTAssertEqual(reported, [.jpeg, .tiff])
        XCTAssertEqual(form.settings.format, .tiff)
        XCTAssertFalse(form.tiffCompressionPopup.isHidden)
        XCTAssertTrue(form.qualityRow.isHidden)
    }

    func testInitDoesNotReportAFormatChange() {
        var calls = 0
        let form = ExportOptionsForm(settings: {
            var s = ExportSettings(); s.format = .tiff; return s
        }())
        form.onFormatChange = { _ in calls += 1 }
        XCTAssertEqual(calls, 0, "the seeded format is not a change")
    }

    func testTheFormWidthStaysStableAcrossFormats() {
        let form = ExportOptionsForm()
        var widths: [CGFloat] = []
        for format in ExportFormat.allCases {
            form.selectFormat(format)
            widths.append(form.fittingSize.width)
        }
        XCTAssertEqual(widths[0], widths[1], "a format swap keeps the width")
        XCTAssertTrue(widths.allSatisfy { $0 == widths[0] }, "all formats keep the width")
    }

    // MARK: Per-format retention

    func testEveryFormatsSettingsSurviveSwitching() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.qualityRow.field.stringValue = "75"
        XCTAssertTrue(form.commitEditing())
        form.selectFormat(.png)
        form.compressionRow.field.stringValue = "4"
        XCTAssertTrue(form.commitEditing())
        form.selectFormat(.tiff)
        form.tiffCompressionPopup.selectItem(at: 2)
        fire(form.tiffCompressionPopup)

        form.selectFormat(.jpeg)
        XCTAssertEqual(form.settings.jpegQuality, 0.75, accuracy: 1e-9,
                       "the JPEG settings survive a PNG/TIFF detour")
        XCTAssertEqual(form.qualityRow.field.stringValue, "75")
        form.selectFormat(.png)
        XCTAssertEqual(form.settings.pngCompression, 4)
        XCTAssertEqual(form.compressionRow.field.stringValue, "4")
        form.selectFormat(.tiff)
        XCTAssertEqual(form.settings.tiffCompression, .deflate)
        XCTAssertEqual(form.settings.pngCompression, 4, "hidden formats keep their settings too")
    }

    // MARK: Control actions

    func testCheckboxAndPopupActionsUpdateTheSettings() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.progressiveBox.state = .off
        fire(form.progressiveBox)
        XCTAssertFalse(form.settings.jpegProgressive)

        form.optimizeBox.state = .off
        fire(form.optimizeBox)
        XCTAssertFalse(form.settings.jpegOptimize)

        form.subsamplingPopup.selectItem(at: 1)
        fire(form.subsamplingPopup)
        XCTAssertEqual(form.settings.jpegSubsampling, .horizontal)

        form.selectFormat(.png)
        form.interlacedBox.state = .on
        fire(form.interlacedBox)
        XCTAssertTrue(form.settings.pngInterlaced)
        form.pngTransparentBox.state = .on
        fire(form.pngTransparentBox)
        XCTAssertTrue(form.settings.pngPreserveTransparentColor)

        form.selectFormat(.tiff)
        form.tiffTransparentBox.state = .off
        fire(form.tiffTransparentBox)
        XCTAssertFalse(form.settings.tiffPreserveTransparentColor)
    }

    func testSliderActionsUpdateFieldAndSettings() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.qualityRow.slider.doubleValue = 42
        fire(form.qualityRow.slider)
        XCTAssertEqual(form.settings.jpegQuality, 0.42, accuracy: 1e-9)
        XCTAssertEqual(form.qualityRow.field.stringValue, "42")

        form.selectFormat(.png)
        form.compressionRow.slider.doubleValue = 3
        fire(form.compressionRow.slider)
        XCTAssertEqual(form.settings.pngCompression, 3)
        XCTAssertEqual(form.compressionRow.field.stringValue, "3")
    }

    // MARK: Field commits

    func testAValidTypedQualityCommitsExactly() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.qualityRow.field.stringValue = "90.5"
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, 0.905, accuracy: 1e-9,
                       "a fractional percent is kept, not truncated")
        form.qualityRow.field.stringValue = "0"
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, 0, accuracy: 1e-9)
        form.qualityRow.field.stringValue = "100"
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, 1, accuracy: 1e-9)
    }

    func testAnInvalidQualityDraftRefusesTheExport() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        for text in ["abc", "500", "-3", "nan", "∞", ""] {
            form.qualityRow.field.stringValue = text
            XCTAssertFalse(form.commitEditing(), "\"\(text)\" must refuse")
            XCTAssertEqual(form.settings.jpegQuality, 0.9, accuracy: 1e-9,
                           "\"\(text)\" must not reach the settings")
            XCTAssertFalse(form.lastError?.isEmpty ?? true,
                           "\"\(text)\" must leave a readable inline reason")
            XCTAssertEqual(form.qualityRow.field.stringValue, text,
                           "\"\(text)\" stays for correction, not reset to a default")
        }
    }

    func testAnInvalidCompressionDraftRefusesTheExport() {
        let form = ExportOptionsForm()
        for text in ["12", "5.5", "-1", "x"] {
            form.compressionRow.field.stringValue = text
            XCTAssertFalse(form.commitEditing(), "\"\(text)\" must refuse")
            XCTAssertEqual(form.settings.pngCompression, 9,
                           "\"\(text)\" must not reach the settings")
            XCTAssertTrue(form.lastError?.isEmpty == false)
        }
    }

    func testACorrectedFieldCommitsAndClearsTheMessage() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.qualityRow.field.stringValue = "700"
        XCTAssertFalse(form.commitEditing())
        XCTAssertFalse(form.lastError?.isEmpty ?? true)

        form.qualityRow.field.stringValue = "80"
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, 0.8, accuracy: 1e-9)
        XCTAssertNil(form.lastError)
        XCTAssertEqual(form.messageLabel.stringValue, "")
    }

    func testAHiddenFormatsStaleDraftDoesNotBlockTheExport() {
        var seed = ExportSettings()
        seed.format = .jpeg
        let form = ExportOptionsForm(settings: seed)

        form.qualityRow.field.stringValue = "not a number"
        form.selectFormat(.png)
        XCTAssertTrue(form.commitEditing(),
                      "a hidden JPEG draft must not block a PNG export")
        XCTAssertEqual(form.settings.jpegQuality, 0.9, accuracy: 1e-9)
        form.selectFormat(.jpeg)
        XCTAssertFalse(form.commitEditing(),
                       "the preserved JPEG draft refuses again once visible")
    }

    func testASeededOutOfRangeValueCannotCommit() {
        var seed = ExportSettings()
        seed.pngCompression = 42
        let form = ExportOptionsForm(settings: seed)
        XCTAssertFalse(form.commitEditing(),
                       "an out-of-range seeded value refuses instead of exporting")
        XCTAssertEqual(form.settings.pngCompression, 42,
                       "the stored value is left alone, not rewritten")
    }
}
