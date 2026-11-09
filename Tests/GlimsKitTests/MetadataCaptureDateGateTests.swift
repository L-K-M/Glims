import XCTest
@testable import GlimsKit

final class MetadataCaptureDateGateTests: XCTestCase {
    private func descriptor(present: Bool = true) -> EngineSession.MetadataTagInfo {
        .init(present: present, supportsMultiple: false, valueKind: .single,
              formatPolicy: [.supportsSet, .supportsRemove], label: "Capture date",
              description: "Original capture time", typeName: "Ascii")
    }

    private func seed(_ descriptor: EngineSession.MetadataTagInfo?, tag: String? = "Exif.Photo.DateTimeOriginal",
                      ready: Bool = true, values: [String] = ["2024:02:29 12:34:56"],
                      dirty: Bool = false) -> [String]? {
        MetadataSheetLogic.captureDateInitialValues(tag: tag, descriptor: descriptor,
            valuesReady: ready, values: values, draftIsDirty: dirty)
    }

    func testRegisteredPresentAndAbsentValuesRemainExact() {
        XCTAssertEqual(seed(descriptor()), ["2024:02:29 12:34:56"])
        XCTAssertEqual(seed(descriptor(), values: ["unknown original text"]), ["unknown original text"])
        XCTAssertEqual(seed(descriptor(), values: [""]), [""])
        XCTAssertEqual(seed(descriptor(present: false), values: []), [])
    }

    func testNewTagPlaceholderNeedsNoIntermediateMetadataWrite() {
        XCTAssertEqual(seed(descriptor(present: false), values: [""], dirty: true), [])
        XCTAssertNil(seed(descriptor(present: false), values: ["typed draft"], dirty: true))
        XCTAssertNil(seed(descriptor(), dirty: true))
    }

    func testMissingOrStaleReadsAndUnexpectedCardinalityStayClosed() {
        XCTAssertNil(seed(nil))
        XCTAssertNil(seed(descriptor(), ready: false))
        XCTAssertNil(seed(descriptor(), tag: nil))
        XCTAssertNil(seed(descriptor(), tag: "Exif.Image.DateTime"))
        XCTAssertNil(seed(descriptor(), values: []))
        XCTAssertNil(seed(descriptor(present: false)))
        XCTAssertNil(seed(descriptor(), values: ["first", "second"]))
    }

    func testFormatAndKindPolicyRemainAuthoritative() {
        var info = descriptor()
        info.supportsMultiple = true
        XCTAssertNil(seed(info))
        info = descriptor(); info.typeName = "Short"
        XCTAssertNil(seed(info))
        info = descriptor(); info.formatPolicy = [.supportsRemove]
        XCTAssertNil(seed(info))
        for kind in [EngineSession.MetadataValueKind.repeatable, .bag, .seq, .alt, .langAlt] {
            info = descriptor(); info.valueKind = kind
            XCTAssertNil(seed(info), "unexpected kind \(kind) must remain gated")
        }
    }
}
