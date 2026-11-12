import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

@MainActor
final class ExportIntegrationTests: XCTestCase {
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
