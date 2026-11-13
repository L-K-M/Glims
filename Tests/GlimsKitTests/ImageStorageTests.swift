import CGlimsEngine
import XCTest
@testable import GlimsKit

final class ImageStorageTests: XCTestCase {
    private func info(_ layout: UInt32, flags: UInt64 = 0) -> GlimsImageStorageInfo {
        var value = GlimsImageStorageInfo()
        value.struct_size = UInt32(MemoryLayout<GlimsImageStorageInfo>.size)
        value.layout = layout
        value.flags = flags
        return value
    }

    func testKnownLayoutsAndReadOnlyCapability() throws {
        let ordinary = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue))
        XCTAssertEqual(ordinary.layout, .ordinary)
        XCTAssertFalse(ordinary.readOnly)
        let flat = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_FLAT_COMPONENT.rawValue))
        XCTAssertEqual(flat.layout, .flatComponent)
        let layered = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
                                                                 flags: UInt64(GLIMS_IMAGE_STORAGE_READ_ONLY)))
        XCTAssertEqual(layered.layout, .layeredLab)
        XCTAssertTrue(layered.readOnly)
        XCTAssertFalse(layered.allowsLayerProperties)
        XCTAssertEqual(layered.restrictedEditingMessage, "This document is read-only. You can view it and save an XCF copy.")
        let editable = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES)))
        XCTAssertFalse(editable.readOnly)
        XCTAssertTrue(editable.allowsLayerProperties)
        XCTAssertFalse(editable.allowsLayerRename, "older engines do not advertise rename")
        XCTAssertEqual(editable.restrictedEditingMessage, "This layered Lab document supports viewing and limited layer-property edits.")
        let rename = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_RENAME)))
        XCTAssertTrue(rename.allowsLayerRename)
        XCTAssertFalse(rename.allowsLayerDuplicate, "older engines do not advertise duplication")
        let duplicate = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_RENAME | GLIMS_IMAGE_STORAGE_LAYER_DUPLICATE)))
        XCTAssertTrue(duplicate.allowsLayerDuplicate)
        XCTAssertFalse(duplicate.allowsLayerCreate, "older engines do not advertise creation")
        XCTAssertEqual(duplicate.restrictedEditingMessage, "This layered Lab document supports viewing and limited layer edits.")
        let create = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_CREATE)))
        XCTAssertTrue(create.allowsLayerCreate)
        XCTAssertFalse(create.allowsLayerDelete, "older engines do not advertise deletion")
        let delete = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_DELETE)))
        XCTAssertTrue(delete.allowsLayerDelete)
        XCTAssertFalse(delete.allowsLayerReorder, "older engines do not advertise reordering")
        let reorder = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAYER_REORDER)))
        XCTAssertTrue(reorder.allowsLayerReorder)
        XCTAssertFalse(reorder.allowsLabSelections, "older engines do not advertise layered Lab selections")
        let selection = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAB_SELECTIONS)))
        XCTAssertTrue(selection.allowsLabSelections)
        XCTAssertFalse(selection.allowsLabLayerColorFill, "older engines do not advertise Lab layer color fill")
        let fill = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES | GLIMS_IMAGE_STORAGE_LAB_LAYER_COLOR_FILL)))
        XCTAssertTrue(fill.allowsLabLayerColorFill)
    }

    func testUnknownOrInconsistentCapabilitiesFailClosed() {
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(UInt32.max)))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue, flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue)))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_RENAME))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_RENAME))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_DUPLICATE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_DUPLICATE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_CREATE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_CREATE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_DELETE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_DELETE))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_REORDER))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_REORDER))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAB_SELECTIONS))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAB_SELECTIONS))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_READ_ONLY | GLIMS_IMAGE_STORAGE_LAB_SELECTIONS))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAB_LAYER_COLOR_FILL))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAB_LAYER_COLOR_FILL))))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_READ_ONLY | GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES))))
        var short = info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue)
        short.struct_size -= 1
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(short))
    }

    func testLimitedLayerChangesRequireOnlyVisibilityOrOpacity() {
        XCTAssertFalse(EngineSession.LayerChange().isLimitedLayerPropertyChange)
        XCTAssertTrue(EngineSession.LayerChange(isVisible: false).isLimitedLayerPropertyChange)
        XCTAssertTrue(EngineSession.LayerChange(opacity: 0.5).isLimitedLayerPropertyChange)
        XCTAssertTrue(EngineSession.LayerChange(name: "Other").isLimitedLayerPropertyChange)
        XCTAssertFalse(EngineSession.LayerChange(name: "Other", opacity: 0.5).isLimitedLayerPropertyChange)
        XCTAssertFalse(EngineSession.LayerChange(name: "Other", isVisible: false).isLimitedLayerPropertyChange)
        XCTAssertFalse(EngineSession.LayerChange(isVisible: true, mode: "normal").isLimitedLayerPropertyChange)
    }
}
