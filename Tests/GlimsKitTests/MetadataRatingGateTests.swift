import XCTest
@testable import GlimsKit

final class MetadataRatingGateTests: XCTestCase {
    private func descriptor(present: Bool = true) -> EngineSession.MetadataTagInfo {
        .init(present: present, supportsMultiple: false, valueKind: .single,
              formatPolicy: [.supportsSet, .supportsRemove], label: "Rating",
              description: "Rating", typeName: "XmpText")
    }

    private func seed(_ info: EngineSession.MetadataTagInfo?, tag: String? = "Xmp.xmp.Rating",
                      ready: Bool = true, values: [String] = ["2.5"], dirty: Bool = false) -> [String]? {
        MetadataSheetLogic.ratingInitialValues(tag: tag, descriptor: info, valuesReady: ready,
                                              values: values, draftIsDirty: dirty)
    }

    func testPresentCanonicalAndUnknownSourceValuesRemainExact() {
        for values in [["0"], ["-1"], ["1"], ["2"], ["3"], ["4"], ["5"],
                       ["2.5"], ["03"], ["-1.0"], [" 3 "], [""]] {
            XCTAssertEqual(seed(descriptor(), values: values), values)
        }
        XCTAssertEqual(seed(descriptor(present: false), values: []), [])
    }

    func testAbsentLocalPlaceholderDoesNotEraseAPresentEmptyValue() {
        XCTAssertEqual(seed(descriptor(present: false), values: [""], dirty: true), [])
        XCTAssertEqual(seed(descriptor(), values: [""]), [""])
        XCTAssertEqual(seed(descriptor(), values: ["0"]), ["0"])
        XCTAssertNil(seed(descriptor(), values: [""], dirty: true))
        XCTAssertNil(seed(descriptor(present: false), values: ["edited"], dirty: true))
    }

    func testMissingMismatchedPendingAndDirtyReadsStayClosed() {
        XCTAssertNil(seed(nil))
        XCTAssertNil(seed(descriptor(), tag: nil))
        XCTAssertNil(seed(descriptor(), tag: "Xmp.xmpRights.Marked"))
        XCTAssertNil(seed(descriptor(), ready: false))
        XCTAssertNil(seed(descriptor(), dirty: true))
        XCTAssertNil(seed(descriptor(present: false), values: [], dirty: true))
    }

    func testPresenceAndCardinalityMustMatchTheCapturedValues() {
        XCTAssertFalse(MetadataSheetLogic.ratingDescriptorMatches(descriptor(), values: []))
        XCTAssertFalse(MetadataSheetLogic.ratingDescriptorMatches(descriptor(present: false), values: ["2.5"]))
        XCTAssertFalse(MetadataSheetLogic.ratingDescriptorMatches(descriptor(), values: ["1", "2"]))
        XCTAssertNil(seed(descriptor(), values: []))
        XCTAssertNil(seed(descriptor(present: false)))
        XCTAssertNil(seed(descriptor(), values: ["1", "2"]))
        XCTAssertTrue(MetadataSheetLogic.ratingDescriptorMatches(descriptor(), values: ["2.5"]))
        XCTAssertTrue(MetadataSheetLogic.ratingDescriptorMatches(descriptor(present: false), values: []))
    }

    func testStructuralDescriptorChangesRefuseOpeningAndApplying() {
        var invalid = [EngineSession.MetadataTagInfo]()
        var info = descriptor(); info.supportsMultiple = true; invalid.append(info)
        info = descriptor(); info.typeName = "Ascii"; invalid.append(info)
        for kind in [EngineSession.MetadataValueKind.repeatable, .bag, .seq, .alt, .langAlt] {
            info = descriptor(); info.valueKind = kind; invalid.append(info)
        }
        for info in invalid {
            XCTAssertNil(seed(info))
            XCTAssertFalse(MetadataSheetLogic.ratingDescriptorMatches(info, values: ["2.5"]))
            XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(.three, descriptor: info, capturedValues: ["2.5"]))
            XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(.unspecified, descriptor: info, capturedValues: ["2.5"]))
        }
    }

    func testSetAndRemovePoliciesAreIndependentForEveryChoice() {
        // Independent literal action table: zero and rejection are SET,
        // while only Not specified is REMOVE.
        let expected: [(MetadataRatingValue, Bool, Bool)] = [
            (.unspecified, false, true), (.unrated, true, false), (.rejected, true, false),
            (.one, true, false), (.two, true, false), (.three, true, false),
            (.four, true, false), (.five, true, false)
        ]
        var setOnly = descriptor(); setOnly.formatPolicy = [.supportsSet]
        var removeOnly = descriptor(); removeOnly.formatPolicy = [.supportsRemove]
        XCTAssertEqual(seed(setOnly), ["2.5"])
        XCTAssertEqual(seed(removeOnly), ["2.5"])
        for (choice, setAllowed, removeAllowed) in expected {
            XCTAssertEqual(MetadataSheetLogic.ratingActionAllowed(choice, descriptor: setOnly,
                                                                 capturedValues: ["2.5"]), setAllowed)
            XCTAssertEqual(MetadataSheetLogic.ratingActionAllowed(choice, descriptor: removeOnly,
                                                                 capturedValues: ["2.5"]), removeAllowed)
        }
        XCTAssertEqual(MetadataRatingValue.unrated.values, ["0"])
        XCTAssertEqual(MetadataRatingValue.rejected.values, ["-1"])
        XCTAssertEqual(MetadataRatingValue.unspecified.values, [])
    }

    func testUnavailableDescriptorAndUnchosenUnknownStayClosed() {
        XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(nil, descriptor: descriptor(), capturedValues: ["2.5"]))
        XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(.three, descriptor: nil, capturedValues: ["2.5"]))
        var info = descriptor(); info.formatPolicy = []
        XCTAssertNil(seed(info))
        for choice in MetadataRatingValue.allCases {
            XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(choice, descriptor: info, capturedValues: ["2.5"]))
        }
    }

    func testFreshDescriptorOverridesEarlierPolicyAndPresence() {
        let earlier = descriptor()
        XCTAssertTrue(MetadataSheetLogic.ratingActionAllowed(.three, descriptor: earlier, capturedValues: ["2.5"]))
        var fresh = earlier; fresh.formatPolicy = [.supportsRemove]
        XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(.three, descriptor: fresh, capturedValues: ["2.5"]))
        XCTAssertTrue(MetadataSheetLogic.ratingActionAllowed(.unspecified, descriptor: fresh, capturedValues: ["2.5"]))
        fresh.present = false
        XCTAssertFalse(MetadataSheetLogic.ratingActionAllowed(.unspecified, descriptor: fresh, capturedValues: ["2.5"]))
        XCTAssertTrue(MetadataSheetLogic.ratingActionAllowed(.unspecified, descriptor: fresh, capturedValues: []))
    }
}
