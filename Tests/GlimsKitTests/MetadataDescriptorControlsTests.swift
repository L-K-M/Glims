import XCTest
@testable import GlimsKit

/// Pure policy tests for the descriptor-adoption gates in
/// `MetadataSheetLogic.writeGates(_:valuesReady:locallyProtected:)` and
/// the read-currency/display helpers, derived from the stated native
/// semantics of facade slot 128 (docs/metadata-tag-info.md): SET and
/// REMOVE gate independently on the format-policy bits, a single-value
/// tag cannot gain a second value, LangAlt is read-only despite its
/// native multiple flag, an absent XMP container is Remove-only, and a
/// pending/failed descriptor or values read fails closed. No engine, no
/// AppKit state, no NSApplication — only the typed
/// `EngineSession.MetadataTagInfo` values and the pure helpers.
final class MetadataDescriptorControlsTests: XCTestCase {

    private func info(present: Bool = true,
                      supportsMultiple: Bool = false,
                      valueKind: EngineSession.MetadataValueKind = .single,
                      formatPolicy: EngineSession.MetadataFormatPolicy = [.supportsSet, .supportsRemove],
                      label: String = "Artist",
                      description: String = "Author of the image",
                      typeName: String = "Ascii") -> EngineSession.MetadataTagInfo {
        EngineSession.MetadataTagInfo(present: present,
                                      supportsMultiple: supportsMultiple,
                                      valueKind: valueKind,
                                      formatPolicy: formatPolicy,
                                      label: label,
                                      description: description,
                                      typeName: typeName)
    }

    // MARK: Single-value tags cannot add a second value

    func testSingleScalarCanSetAndRemoveButNeverAddValue() {
        let gates = MetadataSheetLogic.writeGates(descriptor: info(supportsMultiple: false, valueKind: .single),
                                                  valuesReady: true, locallyProtected: false)
        XCTAssertTrue(gates.canSet)
        XCTAssertTrue(gates.canRemove)
        XCTAssertFalse(gates.canAddValue, "a single-value tag cannot gain a second value")
        XCTAssertFalse(gates.isReadOnly)
        XCTAssertNil(gates.refusal)
    }

    func testSingleKindBlocksAddValueEvenWhenTheNativeMultipleFlagIsSet() {
        let gates = MetadataSheetLogic.writeGates(descriptor: info(supportsMultiple: true, valueKind: .single),
                                                  valuesReady: true, locallyProtected: false)
        XCTAssertTrue(gates.canSet)
        XCTAssertFalse(gates.canAddValue, "the .single kind wins over a stray native multiple flag")
    }

    func testAbsentSingleScalarKeepsApplyForItsInitialOneValueDraft() {
        // A registered absent scalar starts a local one-value draft; its
        // SET stays enabled even though Add Value is not available.
        let gates = MetadataSheetLogic.writeGates(descriptor: info(present: false, valueKind: .single),
                                                  valuesReady: true, locallyProtected: false)
        XCTAssertTrue(gates.canSet, "an absent single scalar can still be set once")
        XCTAssertTrue(gates.canRemove)
        XCTAssertFalse(gates.canAddValue)
    }

    // MARK: Multiple-value kinds

    func testRepeatableAndContainerKindsAllowAddValueWhenNativeMultiple() {
        for kind in [EngineSession.MetadataValueKind.repeatable,
                     .bag, .seq, .alt] as [EngineSession.MetadataValueKind] {
            let gates = MetadataSheetLogic.writeGates(
                descriptor: info(supportsMultiple: true, valueKind: kind),
                valuesReady: true, locallyProtected: false)
            XCTAssertTrue(gates.canAddValue, "\(kind) with native multiple support can add a value")
            XCTAssertTrue(gates.canSet && gates.canRemove)
            XCTAssertFalse(gates.isReadOnly)
        }
    }

    func testContainerKindWithoutNativeMultipleFlagCannotAddValue() {
        let gates = MetadataSheetLogic.writeGates(descriptor: info(supportsMultiple: false, valueKind: .bag),
                                                  valuesReady: true, locallyProtected: false)
        XCTAssertTrue(gates.canSet, "SET is governed by the policy bits, not the multiple flag")
        XCTAssertFalse(gates.canAddValue, "native supportsMultiple false blocks Add Value")
    }

    // MARK: LangAlt is read-only before any native edit

    func testLangAltIsReadOnlyDespiteNativeMultipleFlag() {
        let native = info(supportsMultiple: true, valueKind: .langAlt,
                          formatPolicy: [], label: "Title", typeName: "LangAlt")
        let gates = MetadataSheetLogic.writeGates(descriptor: native, valuesReady: true, locallyProtected: false)
        XCTAssertFalse(gates.canSet)
        XCTAssertFalse(gates.canRemove)
        XCTAssertFalse(gates.canAddValue)
        XCTAssertTrue(gates.isReadOnly)
        XCTAssertEqual(gates.refusal, MetadataSheetLogic.langAltReadOnlyReason)
        XCTAssertTrue(gates.refusal?.contains("read-only") == true)
    }

    func testLangAltStaysReadOnlyEvenIfPolicyBitsWereSet() {
        // Defensive: the kind itself forces read-only, never a setter that
        // would flatten the language alternatives.
        let gates = MetadataSheetLogic.writeGates(
            descriptor: info(supportsMultiple: true, valueKind: .langAlt,
                             formatPolicy: [.supportsSet, .supportsRemove]),
            valuesReady: true, locallyProtected: false)
        XCTAssertFalse(gates.canSet)
        XCTAssertFalse(gates.canRemove)
        XCTAssertTrue(gates.isReadOnly)
    }

    // MARK: SET and REMOVE are independent; absent container is Remove-only

    func testAbsentContainerIsRemoveOnlyWithAnActionableReason() {
        for kind in [EngineSession.MetadataValueKind.bag,
                     .seq, .alt] as [EngineSession.MetadataValueKind] {
            let gates = MetadataSheetLogic.writeGates(
                descriptor: info(present: false, supportsMultiple: true, valueKind: kind,
                                 formatPolicy: [.supportsRemove]),
                valuesReady: true, locallyProtected: false)
            XCTAssertFalse(gates.canSet, "\(kind): a new absent container has no SET")
            XCTAssertTrue(gates.canRemove, "\(kind): removing the absent tag is the native no-op")
            XCTAssertFalse(gates.canAddValue)
            XCTAssertFalse(gates.isReadOnly, "REMOVE stays permitted, so the tag is not read-only")
            XCTAssertTrue(gates.refusal?.contains("Remove Tag") == true, gates.refusal ?? "nil")
        }
    }

    func testSetAndRemoveGateIndependentlyOnTheirOwnBits() {
        let setOnly = MetadataSheetLogic.writeGates(descriptor: info(formatPolicy: [.supportsSet]),
                                                    valuesReady: true, locallyProtected: false)
        XCTAssertTrue(setOnly.canSet)
        XCTAssertFalse(setOnly.canRemove)
        let removeOnly = MetadataSheetLogic.writeGates(descriptor: info(formatPolicy: [.supportsRemove]),
                                                       valuesReady: true, locallyProtected: false)
        XCTAssertFalse(removeOnly.canSet)
        XCTAssertTrue(removeOnly.canRemove)
    }

    // MARK: Protected fallback and fail-closed reads

    func testProtectedTagWithNoBitsIsReadOnly() {
        let gates = MetadataSheetLogic.writeGates(descriptor: info(formatPolicy: []),
                                                  valuesReady: true, locallyProtected: true)
        XCTAssertFalse(gates.canSet)
        XCTAssertFalse(gates.canRemove)
        XCTAssertFalse(gates.canAddValue)
        XCTAssertTrue(gates.isReadOnly)
        XCTAssertEqual(gates.refusal, MetadataSheetLogic.protectedNote)
    }

    func testMissingPendingOrFailedDescriptorFailsClosed() {
        let gates = MetadataSheetLogic.writeGates(descriptor: nil, valuesReady: true, locallyProtected: false)
        XCTAssertFalse(gates.canSet)
        XCTAssertFalse(gates.canRemove)
        XCTAssertFalse(gates.canAddValue)
        XCTAssertFalse(gates.isReadOnly)
        XCTAssertTrue(gates.refusal?.contains("descriptor") == true, gates.refusal ?? "nil")
    }

    func testMissingDescriptorKeepsTheConservativeProtectedFallback() {
        let gates = MetadataSheetLogic.writeGates(descriptor: nil, valuesReady: true, locallyProtected: true)
        XCTAssertFalse(gates.canSet && gates.canRemove && gates.canAddValue)
        XCTAssertTrue(gates.isReadOnly, "the local protected check stays conservative while the descriptor is unknown")
    }

    func testPendingOrFailedValuesReadFailsClosedEvenWithAGoodDescriptor() {
        let gates = MetadataSheetLogic.writeGates(descriptor: info(), valuesReady: false, locallyProtected: false)
        XCTAssertFalse(gates.canSet, "writes stay disabled until the values read succeeded for the same tag")
        XCTAssertFalse(gates.canRemove)
        XCTAssertFalse(gates.canAddValue)
        XCTAssertTrue(gates.refusal?.contains("values") == true, gates.refusal ?? "nil")
    }

    // MARK: Read currency: generation and same-tag facts

    func testAReadLandsOnlyForTheSameTagAndCurrentGeneration() {
        XCTAssertTrue(MetadataSheetLogic.readIsCurrent(tag: "Exif.Image.Artist", generation: 3,
                                                       selectedTag: "Exif.Image.Artist", currentGeneration: 3))
        XCTAssertFalse(MetadataSheetLogic.readIsCurrent(tag: "Exif.Image.Artist", generation: 2,
                                                        selectedTag: "Exif.Image.Artist", currentGeneration: 3),
                       "an older generation is stale")
        XCTAssertFalse(MetadataSheetLogic.readIsCurrent(tag: "Exif.Image.Copyright", generation: 3,
                                                        selectedTag: "Exif.Image.Artist", currentGeneration: 3),
                       "another tag's result must not land on this selection")
        XCTAssertFalse(MetadataSheetLogic.readIsCurrent(tag: "Exif.Image.Artist", generation: 3,
                                                        selectedTag: nil, currentGeneration: 3),
                       "a deselected tag accepts nothing")
    }

    // MARK: Displayed descriptor strings

    func testDescriptorTitleUsesNativeLabelAndTypeNameWithTagFallback() {
        let titled = info(label: "Artist", typeName: "Ascii")
        XCTAssertEqual(MetadataSheetLogic.descriptorTitle(tag: "Exif.Image.Artist", info: titled),
                       "Artist — Ascii")
        let unlabeled = info(label: "", typeName: "XmpBag")
        XCTAssertEqual(MetadataSheetLogic.descriptorTitle(tag: "Xmp.dc.subject", info: unlabeled),
                       "Xmp.dc.subject — XmpBag", "an empty native label falls back to the dotted tag")
        let untyped = info(label: "Keywords", typeName: "")
        XCTAssertEqual(MetadataSheetLogic.descriptorTitle(tag: "Iptc.Application2.Keywords", info: untyped),
                       "Keywords")
    }

    func testDescriptorPresenceTextReflectsTheNativeFlag() {
        XCTAssertEqual(MetadataSheetLogic.descriptorPresenceText(info(present: true)),
                       "Present on this image.")
        XCTAssertEqual(MetadataSheetLogic.descriptorPresenceText(info(present: false)),
                       "Not present on this image yet.")
    }

    func testSuccessfulInfoStringsFlowIntoTheGatesUnchanged() {
        let native = info(present: true, supportsMultiple: true, valueKind: .seq,
                          formatPolicy: [.supportsSet, .supportsRemove],
                          label: "Creator — Échelle 山", description: "Who made it", typeName: "XmpSeq")
        XCTAssertEqual(native.label, "Creator — Échelle 山")
        XCTAssertEqual(native.description, "Who made it")
        XCTAssertEqual(MetadataSheetLogic.descriptorTitle(tag: "Xmp.dc.creator", info: native),
                       "Creator — Échelle 山 — XmpSeq")
        let gates = MetadataSheetLogic.writeGates(descriptor: native, valuesReady: true, locallyProtected: false)
        XCTAssertTrue(gates.canSet && gates.canRemove && gates.canAddValue)
        XCTAssertNil(gates.refusal)
    }
}
