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
        let editable = try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue,
            flags: UInt64(GLIMS_IMAGE_STORAGE_LAYER_PROPERTIES)))
        XCTAssertFalse(editable.readOnly)
        XCTAssertTrue(editable.allowsLayerProperties)
    }

    func testUnknownOrInconsistentCapabilitiesFailClosed() {
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(UInt32.max)))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue, flags: 2)))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue)))
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(info(GLIMS_IMAGE_LAYOUT_LAYERED_LAB.rawValue, flags: 3)))
        var short = info(GLIMS_IMAGE_LAYOUT_ORDINARY.rawValue)
        short.struct_size -= 1
        XCTAssertThrowsError(try EngineSession.ImageStorage.decode(short))
    }
}
