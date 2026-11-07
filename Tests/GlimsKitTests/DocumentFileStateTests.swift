import XCTest
@testable import GlimsKit

/// The file-state book-keeping behind Save, Save As and the close
/// prompt: which file a plain Save writes, when a document counts as
/// unsaved, and which commands move that state.
@MainActor
final class DocumentFileStateTests: XCTestCase {
    private let xcf = URL(fileURLWithPath: "/tmp/image.xcf")
    private let otherXcf = URL(fileURLWithPath: "/tmp/other.xcf")
    private let png = URL(fileURLWithPath: "/tmp/photo.png")
    private let jpeg = URL(fileURLWithPath: "/tmp/photo.jpg")

    func testANewImageHasNoFileAndNeedsNoSave() {
        let state = DocumentFileState()
        XCTAssertNil(state.nativeURL)
        XCTAssertNil(state.importedSourceURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .askForFile)
    }

    func testAnOpenedXCFSavesBackToItself() {
        let state = DocumentFileState(openedFrom: xcf)
        XCTAssertEqual(state.nativeURL, xcf)
        XCTAssertNil(state.importedSourceURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .write(xcf))
    }

    /// Cmd-S must never write XCF data over the file an image was
    /// imported from.
    func testAnImportedFileIsNeverASaveTarget() {
        let state = DocumentFileState(openedFrom: png)
        XCTAssertNil(state.nativeURL)
        XCTAssertEqual(state.importedSourceURL, png)
        XCTAssertEqual(state.saveRoute, .askForFile)
    }

    /// An imported image counts as unsaved until a native save exists —
    /// even when the engine reports nothing to undo.
    func testAnImportedImageCountsAsUnsavedUntilANativeSave() {
        var state = DocumentFileState(openedFrom: png)
        XCTAssertTrue(state.hasUnsavedChanges)
        state.syncDirty(false)
        XCTAssertTrue(state.hasUnsavedChanges)
    }

    /// Name, target and dirty flag move only on a successful save.
    func testASuccessfulSaveAsMakesTheFileNative() {
        var state = DocumentFileState(openedFrom: png)
        state.noteSaved(to: xcf)
        XCTAssertEqual(state.nativeURL, xcf)
        XCTAssertNil(state.importedSourceURL)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .write(xcf))
    }

    func testCompressedNativeImagesKeepTheirOriginalSaveTarget() {
        for name in ["drawing.xcf.gz", "drawing.XCF.BZ2"] {
            let url = URL(fileURLWithPath: "/tmp/" + name)
            let state = DocumentFileState(openedFrom: url)
            XCTAssertEqual(state.saveRoute, .write(url))
            XCTAssertFalse(state.hasUnsavedChanges)
            XCTAssertNil(state.importedSourceURL)
        }
    }

    /// GIMP registers the compressed XCF types under the dotless
    /// suffixes too: those files are native, not imports.
    func testRegisteredCompressedSuffixesAreNative() {
        for name in ["drawing.xcfgz", "drawing.xcfbz2", "DRAWING.XCFGZ", "DRAWING.XCFBZ2"] {
            let url = URL(fileURLWithPath: "/tmp/" + name)
            XCTAssertTrue(DocumentFileState.isNative(url), name)
            let state = DocumentFileState(openedFrom: url)
            XCTAssertEqual(state.saveRoute, .write(url), name)
            XCTAssertFalse(state.hasUnsavedChanges, name)
            XCTAssertNil(state.importedSourceURL, name)
        }
    }

    /// A compressed file that is not XCF data stays an import: never a
    /// save target, and unsaved until a native save exists.
    func testANonXCFCompressedFileIsImported() {
        for name in ["photo.gz", "photo.GZ", "photo.tar.gz"] {
            let url = URL(fileURLWithPath: "/tmp/" + name)
            XCTAssertFalse(DocumentFileState.isNative(url), name)
            let state = DocumentFileState(openedFrom: url)
            XCTAssertNil(state.nativeURL, name)
            XCTAssertEqual(state.importedSourceURL, url, name)
            XCTAssertTrue(state.hasUnsavedChanges, name)
            XCTAssertEqual(state.saveRoute, .askForFile, name)
        }
    }

    func testSaveAsCanRetargetAnExistingNativeFile() {
        var state = DocumentFileState(openedFrom: xcf)
        state.syncDirty(true)
        state.noteSaved(to: otherXcf)
        XCTAssertEqual(state.nativeURL, otherXcf)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .write(otherXcf))
    }

    func testDirtyClearsOnSaveAndReturnsOnEdit() {
        var state = DocumentFileState(openedFrom: xcf)
        state.syncDirty(true)
        XCTAssertTrue(state.hasUnsavedChanges)
        state.noteSaved(to: xcf)
        XCTAssertFalse(state.hasUnsavedChanges)
        state.syncDirty(true)
        XCTAssertTrue(state.hasUnsavedChanges)
    }

    /// Exporting writes a foreign-format copy: the native file target
    /// and the dirty flag both stay.
    func testExportNeverTouchesNativeState() {
        var state = DocumentFileState(openedFrom: xcf)
        state.syncDirty(true)
        let before = state
        state.noteExported(to: jpeg)
        XCTAssertEqual(state, before)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .write(xcf))
    }

    /// Exporting an imported image writes no native file: it still has
    /// none and still counts as unsaved.
    func testExportKeepsAnImportedImageUnsaved() {
        var state = DocumentFileState(openedFrom: png)
        state.noteExported(to: jpeg)
        XCTAssertNil(state.nativeURL)
        XCTAssertEqual(state.importedSourceURL, png)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(state.saveRoute, .askForFile)
    }

    func testTheNativeExtensionIsCaseInsensitive() {
        let upper = URL(fileURLWithPath: "/tmp/UPPER.XCF")
        XCTAssertTrue(DocumentFileState.isNative(upper))
        XCTAssertEqual(DocumentFileState(openedFrom: upper).saveRoute, .write(upper))
    }

    /// The title's bullet tracks the unsaved-changes flag.
    func testTitleMarksUnsavedChanges() {
        XCTAssertEqual(
            DocumentWindowController.title(name: "image.xcf", zoomPercent: 100, isDirty: true, precision: "u8-non-linear"),
            "• image.xcf @ 100% (RGB, u8-non-linear)")
        XCTAssertEqual(
            DocumentWindowController.title(name: "image.xcf", zoomPercent: 50, isDirty: false, precision: "u8-non-linear"),
            "image.xcf @ 50% (RGB, u8-non-linear)")
    }
}
