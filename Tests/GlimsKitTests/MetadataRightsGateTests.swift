import XCTest
@testable import GlimsKit

final class MetadataRightsGateTests: XCTestCase {
    private func descriptor(present: Bool = true) -> EngineSession.MetadataTagInfo {
        .init(present: present, supportsMultiple: false, valueKind: .single,
              formatPolicy: [.supportsSet, .supportsRemove], label: "Marked",
              description: "Rights-managed marker", typeName: "XmpText")
    }

    private func seed(_ info: EngineSession.MetadataTagInfo?, tag: String? = "Xmp.xmpRights.Marked",
                      ready: Bool = true, values: [String] = ["True"], dirty: Bool = false) -> [String]? {
        MetadataSheetLogic.rightsInitialValues(tag: tag, descriptor: info, valuesReady: ready,
                                              values: values, draftIsDirty: dirty)
    }

    func testRegisteredPresentAbsentAndUnknownValuesRemainExact() {
        XCTAssertEqual(seed(descriptor()), ["True"])
        XCTAssertEqual(seed(descriptor(), values: ["False"]), ["False"])
        XCTAssertEqual(seed(descriptor(), values: ["unrecognized original"]), ["unrecognized original"])
        XCTAssertEqual(seed(descriptor(), values: [""]), [""])
        XCTAssertEqual(seed(descriptor(present: false), values: []), [])
        XCTAssertEqual(seed(descriptor(present: false), values: [""], dirty: true), [])
    }

    func testMissingMismatchedAndDirtyReadsStayClosed() {
        XCTAssertNil(seed(nil))
        XCTAssertNil(seed(descriptor(), tag: "Exif.Image.Orientation"))
        XCTAssertNil(seed(descriptor(), tag: nil))
        XCTAssertNil(seed(descriptor(), ready: false))
        XCTAssertNil(seed(descriptor(), values: []))
        XCTAssertNil(seed(descriptor(present: false)))
        XCTAssertNil(seed(descriptor(), values: ["True", "False"]))
        XCTAssertNil(seed(descriptor(), dirty: true))
        XCTAssertNil(seed(descriptor(present: false), values: ["edited"], dirty: true))
    }

    func testEachNativePolicyAndStructuralKindIsAuthoritative() {
        var info = descriptor()
        info.formatPolicy = [.supportsSet]
        XCTAssertNotNil(seed(info))
        info.formatPolicy = [.supportsRemove]
        XCTAssertNotNil(seed(info))
        info.formatPolicy = []
        XCTAssertNil(seed(info))
        info = descriptor(); info.supportsMultiple = true
        XCTAssertNil(seed(info))
        info = descriptor(); info.typeName = "Ascii"
        XCTAssertNil(seed(info))
        for kind in [EngineSession.MetadataValueKind.repeatable, .bag, .seq, .alt, .langAlt] {
            info = descriptor(); info.valueKind = kind
            XCTAssertNil(seed(info))
        }
    }
}
