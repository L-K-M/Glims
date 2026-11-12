import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

@MainActor
final class ExportIntegrationTests: XCTestCase {
    func testBitmapChoicesKeepFilenamePolicyAndNativeRequestTogether() throws {
        let export = ExportSavePanel(baseName: "photo.version2", settings: ExportSettings())
        export.form.compressionRow.field.stringValue = "bad draft"
        XCTAssertFalse(export.form.commitEditing())
        for (format, native) in [(ExportFormat.bmp, GLIMS_EXPORT_BMP), (.tga, GLIMS_EXPORT_TGA)] {
            export.form.selectFormat(format)
            XCTAssertTrue(export.form.commitEditing(), "hidden PNG drafts cannot block bitmap output")
            XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2." + format.preferredExtension)
            XCTAssertEqual(export.panel.allowedContentTypes, [format.contentType])
            XCTAssertEqual(try export.form.settings.nativeValue().format, native.rawValue)
            XCTAssertEqual(ExportFormat.forFileExtension("." + format.preferredExtension.uppercased()), format)
            XCTAssertEqual(export.form.bmpExplanation.isHidden, format != .bmp)
            XCTAssertEqual(export.form.tgaExplanation.isHidden, format != .tga)
            XCTAssertTrue(export.form.gifExplanation.isHidden)
            XCTAssertTrue(export.form.psdLayoutPopup.isHidden)
        }
        export.form.selectFormat(.psd)
        XCTAssertTrue(export.form.bmpExplanation.isHidden)
        XCTAssertTrue(export.form.tgaExplanation.isHidden)
        XCTAssertTrue(export.form.bmpExplanation.stringValue.contains("32-bit sRGB"))
        XCTAssertTrue(export.form.tgaExplanation.stringValue.contains("No color profile"))
    }

    func testGifChoiceReachesNativeSettingsAndPanel() throws {
        var settings = ExportSettings()
        settings.format = .gif
        XCTAssertEqual(try settings.nativeValue().format, GLIMS_EXPORT_GIF.rawValue)
        let export = ExportSavePanel(baseName: "photo.version2", settings: settings)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.gif")
        XCTAssertEqual(export.panel.allowedContentTypes, [.gif])
        export.form.selectFormat(.psd)
        export.form.selectFormat(.gif)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.gif")
        XCTAssertTrue(export.form.commitEditing())
    }

    func testNativeMappingCarriesTheExactEncoderChoices() throws {
        var settings = ExportSettings()
        settings.format = .jpeg
        settings.jpegQuality = 0.123456789
        settings.jpegSubsampling = .vertical
        settings.jpegOptimize = false
        settings.jpegProgressive = false
        settings.pngCompression = 4
        settings.pngInterlaced = true
        settings.pngPreserveTransparentColor = true
        settings.tiffCompression = .deflate
        settings.tiffPreserveTransparentColor = false
        let native = try settings.nativeValue()
        XCTAssertEqual(native.struct_size, UInt32(MemoryLayout<GlimsExportSettings>.size))
        XCTAssertEqual(native.format, GLIMS_EXPORT_JPEG.rawValue)
        XCTAssertEqual(native.jpeg_quality, settings.jpegQuality)
        XCTAssertEqual(native.jpeg_subsampling, GLIMS_JPEG_VERTICAL.rawValue)
        XCTAssertEqual(native.jpeg_optimize, 0)
        XCTAssertEqual(native.jpeg_progressive, 0)
        XCTAssertEqual(native.png_compression, 4)
        XCTAssertEqual(native.png_interlaced, 1)
        XCTAssertEqual(native.png_preserve_transparent_color, 1)
        XCTAssertEqual(native.tiff_compression, GLIMS_TIFF_DEFLATE.rawValue)
        XCTAssertEqual(native.tiff_preserve_transparent_color, 0)
    }

    func testPsdChoiceReachesNativeSettingsAndPanel() throws {
        var settings = ExportSettings()
        settings.format = .psd
        settings.psdLayout = .merged
        let native = try settings.nativeValue()
        XCTAssertEqual(native.format, GLIMS_EXPORT_PSD.rawValue)
        XCTAssertEqual(native.psd_layout, GLIMS_PSD_MERGED.rawValue)
        settings.psdLayout = .layers
        XCTAssertEqual(try settings.nativeValue().psd_layout, GLIMS_PSD_LAYERS.rawValue)
        XCTAssertEqual(native.psd_layout, GLIMS_PSD_MERGED.rawValue, "native request detaches from later edits")
        let export = ExportSavePanel(baseName: "photo.version2", settings: settings)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.psd")
        XCTAssertEqual(export.panel.allowedContentTypes.map(\.identifier), ["com.adobe.photoshop-image"])
        export.form.selectFormat(.png)
        export.form.selectFormat(.psd)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.psd")
    }

    func testInvalidSettingsRefuseBeforeNativeConversion() {
        var settings = ExportSettings()
        settings.pngCompression = Int.max
        XCTAssertThrowsError(try settings.nativeValue())
        settings.pngCompression = 9
        settings.jpegQuality = .nan
        XCTAssertThrowsError(try settings.nativeValue())
    }

    func testSavePanelKeepsCompoundFilenameAndFormatTogether() {
        let export = ExportSavePanel(baseName: "photo.version2", settings: ExportSettings())
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.png")
        export.form.selectFormat(.jpeg)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.jpg")
        XCTAssertEqual(export.panel.allowedContentTypes, [.jpeg])
        export.form.selectFormat(.tiff)
        XCTAssertEqual(export.panel.nameFieldStringValue, "photo.version2.tiff")
        XCTAssertEqual(export.panel.allowedContentTypes, [.tiff])
    }

    func testSavePanelValidationActuallyImplementsTheNativeDelegate() {
        let export = ExportSavePanel(baseName: "photo", settings: ExportSettings())
        XCTAssertTrue(export.responds(to: NSSelectorFromString("panel:validateURL:error:")))
        export.form.compressionRow.field.stringValue = "100"
        XCTAssertThrowsError(try export.panel(export.panel, validate: URL(fileURLWithPath: "/tmp/photo.png")))
        export.form.compressionRow.field.stringValue = "5"
        XCTAssertNoThrow(try export.panel(export.panel, validate: URL(fileURLWithPath: "/tmp/photo.png")))
    }

    func testUneditedRoundedQualityPreservesItsStoredValue() {
        var settings = ExportSettings()
        settings.format = .jpeg
        settings.jpegQuality = 0.123456789
        let form = ExportOptionsForm(settings: settings)
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, settings.jpegQuality)
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, settings.jpegQuality)
    }

    func testExplicitlyTypingRoundedQualityAppliesThatValue() {
        var settings = ExportSettings()
        settings.format = .jpeg
        settings.jpegQuality = 0.123456789
        let form = ExportOptionsForm(settings: settings)
        let row = form.qualityRow
        row.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: row.field))
        row.field.stringValue = row.formatter.string(from: NSNumber(value: 12.3457))!
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: row.field))
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, 0.123457, accuracy: 1e-12)
        let committed = form.settings.jpegQuality
        XCTAssertTrue(form.commitEditing())
        XCTAssertEqual(form.settings.jpegQuality, committed)
    }
}
