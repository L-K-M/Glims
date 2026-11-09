import XCTest
import Darwin
import CGlimsEngine
@testable import GlimsKit

/// Pure contract tests for the read-only tag-descriptor wrapper (slot
/// 128): the facade-owned enum and bit raw values must match the C
/// header's, the decoder must map value kinds exactly and throw on an
/// unknown kind (never coerce it), and the bounded UTF-8 string decode
/// must read exactly to the NUL terminator, multi-byte codepoints
/// included. No engine is started.
final class MetadataTagInfoTests: XCTestCase {

    /// Copies a NUL-terminated C string into a fixed-size C char array
    /// field of a struct, exactly as the adapter would have left it.
    private func fill<T>(_ field: inout T, _ string: String) {
        string.withCString { cString in
            withUnsafeMutableBytes(of: &field) { buffer in
                let count = min(buffer.count, strlen(cString) + 1)
                buffer.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: count))
            }
        }
    }

    func testValueKindRawValuesMatchFacade() {
        XCTAssertEqual(EngineSession.MetadataValueKind.single.rawValue, GLIMS_METADATA_VALUE_SINGLE.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.repeatable.rawValue, GLIMS_METADATA_VALUE_REPEATABLE.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.bag.rawValue, GLIMS_METADATA_VALUE_BAG.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.seq.rawValue, GLIMS_METADATA_VALUE_SEQ.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.alt.rawValue, GLIMS_METADATA_VALUE_ALT.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.langAlt.rawValue, GLIMS_METADATA_VALUE_LANG_ALT.rawValue)
        XCTAssertEqual(EngineSession.MetadataValueKind.allCases.count, 6)
        XCTAssertNil(EngineSession.MetadataValueKind(rawValue: 0))
        XCTAssertNil(EngineSession.MetadataValueKind(rawValue: 7))
    }

    func testFormatPolicyBitsMatchFacade() {
        XCTAssertEqual(EngineSession.MetadataFormatPolicy.supportsSet.rawValue,
                       GLIMS_METADATA_FORMAT_SUPPORTS_SET.rawValue)
        XCTAssertEqual(EngineSession.MetadataFormatPolicy.supportsRemove.rawValue,
                       GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE.rawValue)
        XCTAssertTrue(EngineSession.MetadataFormatPolicy.supportsSet
                        .isDisjoint(with: .supportsRemove))
        let both = EngineSession.MetadataFormatPolicy([.supportsSet, .supportsRemove])
        XCTAssertEqual(both.rawValue,
                       GLIMS_METADATA_FORMAT_SUPPORTS_SET.rawValue | GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE.rawValue)
        XCTAssertEqual(EngineSession.MetadataFormatPolicy().rawValue, 0)
    }

    func testDecoderMapsKnownKindFlagsAndStrings() throws {
        var out = GlimsMetadataTagInfo()
        out.struct_size = UInt32(MemoryLayout<GlimsMetadataTagInfo>.size)
        out.present = true
        out.supports_multiple = true
        out.value_kind = GLIMS_METADATA_VALUE_BAG.rawValue
        out.format_policy = GLIMS_METADATA_FORMAT_SUPPORTS_SET.rawValue | GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE.rawValue
        fill(&out.label, "Subject")
        fill(&out.description, "Keywords describing the content — Échelle 山")
        fill(&out.type_name, "XmpBag")
        let info = try EngineSession.decodeMetadataTagInfo(from: out)
        XCTAssertEqual(info, EngineSession.MetadataTagInfo(
            present: true,
            supportsMultiple: true,
            valueKind: .bag,
            formatPolicy: [.supportsSet, .supportsRemove],
            label: "Subject",
            description: "Keywords describing the content — Échelle 山",
            typeName: "XmpBag"))
    }

    func testDecoderThrowsOnUnknownValueKind() {
        var out = GlimsMetadataTagInfo()
        out.struct_size = UInt32(MemoryLayout<GlimsMetadataTagInfo>.size)
        out.value_kind = 99
        XCTAssertThrowsError(try EngineSession.decodeMetadataTagInfo(from: out)) { error in
            guard let engineError = error as? EngineSession.EngineError else {
                return XCTFail("expected an EngineError, got \(error)")
            }
            XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testDecoderReadsBoundedStringsExactlyToNUL() throws {
        var out = GlimsMetadataTagInfo()
        out.struct_size = UInt32(MemoryLayout<GlimsMetadataTagInfo>.size)
        out.value_kind = GLIMS_METADATA_VALUE_SINGLE.rawValue
        // A full-capacity label with no room for a NUL would still decode
        // as the whole field (the adapter always NUL-terminates, so this
        // is the defensive fallback), and a multi-byte tail survives.
        fill(&out.label, String(repeating: "山", count: 40))
        fill(&out.type_name, "Ascii")
        let info = try EngineSession.decodeMetadataTagInfo(from: out)
        XCTAssertEqual(info.label, String(repeating: "山", count: 40))
        XCTAssertEqual(info.typeName, "Ascii")
        XCTAssertEqual(info.description, "")
        XCTAssertFalse(info.present)
        XCTAssertFalse(info.supportsMultiple)
        XCTAssertEqual(info.valueKind, .single)
        XCTAssertEqual(info.formatPolicy, [])
    }

    func testEmbeddedNULGuardIsSharedWithTheTagInfoWrapper() {
        // metadataTagInfo(_:tag:) rejects through the same metadata input
        // guard as the other metadata calls, before any bridge allocation.
        XCTAssertThrowsError(try EngineSession.validateMetadataStrings(tag: "Exif.Image.Artist\0x", values: []))
        XCTAssertNoThrow(try EngineSession.validateMetadataStrings(tag: "Xmp.dc.title", values: []))
    }
}
