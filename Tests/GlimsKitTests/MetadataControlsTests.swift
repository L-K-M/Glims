import XCTest
@testable import GlimsKit

/// Pure tests for the Image ▸ Metadata… form and policy: the ordered
/// separate value draft (empty strings, duplicates, newlines, order), the
/// empty-list-is-not-a-SET rule, the dotted-name rule for Add Tag, the
/// full-catalog search, the normalization-protected read-only list, the
/// cached write admission and the per-action capture. No engine, no AppKit
/// state.
final class MetadataControlsTests: XCTestCase {

    // MARK: Ordered separate value draft

    func testAddValueAppendsOneEmptyStringAsARealValue() {
        XCTAssertEqual(MetadataSheetLogic.addValue(to: []), [""])
        XCTAssertEqual(MetadataSheetLogic.addValue(to: ["a"]), ["a", ""])
    }

    func testRemoveValueDeletesTheExplicitIndexOnlyAndPreservesOrder() {
        let values = ["one", "two", "two", ""]
        XCTAssertEqual(MetadataSheetLogic.removeValue(at: 1, from: values), ["one", "two", ""])
        XCTAssertEqual(MetadataSheetLogic.removeValue(at: 3, from: values), ["one", "two", "two"])
        XCTAssertEqual(MetadataSheetLogic.removeValue(at: 0, from: values), ["two", "two", ""])
        XCTAssertNil(MetadataSheetLogic.removeValue(at: 4, from: values))
        XCTAssertNil(MetadataSheetLogic.removeValue(at: -1, from: values))
        // The source array is untouched (value semantics).
        XCTAssertEqual(values, ["one", "two", "two", ""])
    }

    func testReplaceValueWritesMultilineTextExactlyWithoutSplittingOrJoining() {
        var values = ["a", "b"]
        let updated = MetadataSheetLogic.replaceValue(at: 1, with: "line1\nline2\n", in: values)
        XCTAssertEqual(updated, ["a", "line1\nline2\n"])
        XCTAssertNil(MetadataSheetLogic.replaceValue(at: 2, with: "x", in: values))
        XCTAssertNil(MetadataSheetLogic.replaceValue(at: -1, with: "x", in: values))
        // A newline inside one value never becomes two values.
        XCTAssertEqual(updated?.count, 2)
        XCTAssertEqual(values, ["a", "b"])
    }

    func testDraftRoundTripPreservesEmptyDuplicatesNewlinesAndOrder() {
        var draft: [String] = []
        for text in ["line1\nline2", "", "dup", "dup", ""] {
            draft = MetadataSheetLogic.addValue(to: draft)
            if let index = draft.indices.last,
               let replaced = MetadataSheetLogic.replaceValue(at: index, with: text, in: draft) {
                draft = replaced
            }
        }
        XCTAssertEqual(draft, ["line1\nline2", "", "dup", "dup", ""])
        // Remove the middle duplicate: the other survives, order intact.
        XCTAssertEqual(MetadataSheetLogic.removeValue(at: 2, from: draft),
                       ["line1\nline2", "", "dup", ""])
    }

    // MARK: SET validation: an empty list is not a set

    func testValidateSetValuesRefusesAnEmptyListWithTheRemoveTagExplanation() {
        guard case .failure(let rejection) = MetadataSheetLogic.validateSetValues([]) else {
            return XCTFail("an empty value list must be refused")
        }
        XCTAssertTrue(rejection.message.contains("Remove Tag"), rejection.message)
        XCTAssertTrue(rejection.message.contains("at least one"), rejection.message)
    }

    func testValidateSetValuesAcceptsASingleEmptyStringAndPassesValuesThroughUnchanged() {
        guard case .success(let values) = MetadataSheetLogic.validateSetValues([""]) else {
            return XCTFail("a single empty string is still one value")
        }
        XCTAssertEqual(values, [""])
        let tricky = ["a\nb", "", "dup", "dup", " spaced "]
        guard case .success(let passed) = MetadataSheetLogic.validateSetValues(tricky) else {
            return XCTFail("a non-empty list must validate")
        }
        XCTAssertEqual(passed, tricky)
    }

    // MARK: Dotted-name rule for Add Tag

    func testValidateNewTagNameRequiresTheDomainPrefixAndANonEmptyRemainder() {
        guard case .success(let name) = MetadataSheetLogic.validateNewTagName("Exif.Image.Artist", domain: .exif) else {
            return XCTFail("a well-formed EXIF name must validate")
        }
        XCTAssertEqual(name, "Exif.Image.Artist")
        guard case .failure = MetadataSheetLogic.validateNewTagName("Iptc.Application2.Caption", domain: .exif) else {
            return XCTFail("a foreign prefix must be refused for the chosen domain")
        }
        guard case .failure = MetadataSheetLogic.validateNewTagName("Exif.", domain: .exif) else {
            return XCTFail("an empty remainder must be refused")
        }
        guard case .failure = MetadataSheetLogic.validateNewTagName("  ", domain: .xmp) else {
            return XCTFail("a blank name must be refused")
        }
        guard case .failure = MetadataSheetLogic.validateNewTagName("Exif.Image.Artist\0x", domain: .exif) else {
            return XCTFail("a NUL must be refused before any bridge allocation")
        }
        guard case .success(let xmp) = MetadataSheetLogic.validateNewTagName(" Xmp.dc.title ", domain: .xmp) else {
            return XCTFail("surrounding whitespace trims")
        }
        XCTAssertEqual(xmp, "Xmp.dc.title")
    }

    func testDomainPrefixesAndTitlesCoverAllThreeDomains() {
        XCTAssertEqual(MetadataSheetLogic.domainPrefix(.exif), "Exif.")
        XCTAssertEqual(MetadataSheetLogic.domainPrefix(.iptc), "Iptc.")
        XCTAssertEqual(MetadataSheetLogic.domainPrefix(.xmp), "Xmp.")
        XCTAssertEqual(MetadataSheetLogic.domainTitle(.exif), "EXIF")
        XCTAssertEqual(MetadataSheetLogic.domainTitle(.iptc), "IPTC")
        XCTAssertEqual(MetadataSheetLogic.domainTitle(.xmp), "XMP")
        XCTAssertEqual(MetadataSheetLogic.domains.map(\.0), EngineSession.MetadataDomain.allCases)
    }

    // MARK: Full-catalog search

    func testFilterTagsKeepsTheWholeCatalogOrderAndNeverTruncates() {
        let catalog = ["Exif.Image.Artist", "Exif.Image.ImageWidth", "Exif.Photo.ColorSpace", "Iptc.Application2.Caption"]
        XCTAssertEqual(MetadataSheetLogic.filterTags(catalog, query: ""), catalog)
        XCTAssertEqual(MetadataSheetLogic.filterTags(catalog, query: "exif"), Array(catalog.prefix(3)))
        XCTAssertEqual(MetadataSheetLogic.filterTags(catalog, query: "IMAGE"), ["Exif.Image.Artist", "Exif.Image.ImageWidth"])
        XCTAssertEqual(MetadataSheetLogic.filterTags(catalog, query: "zzz"), [])
        // No truncation: a large catalog comes back whole.
        let big = (0..<5000).map { "Exif.Image.Tag\($0)" }
        XCTAssertEqual(MetadataSheetLogic.filterTags(big, query: "").count, 5000)
    }

    // MARK: Normalization-protected read-only tags

    func testProtectedTagsAreExactlyTheThirteenNormalizationRewrittenTags() {
        // Source-verified list from app/core/gimpimage-metadata.c's
        // gimp_image_metadata_update_* rewrites (docs/image-metadata.md).
        XCTAssertEqual(MetadataSheetLogic.protectedTags.count, 13)
        for tag in ["Exif.Image.ImageWidth", "Exif.Image.ImageLength", "Exif.Image.BitsPerSample",
                    "Exif.Image.XResolution", "Exif.Image.YResolution", "Exif.Image.ResolutionUnit",
                    "Exif.Photo.ColorSpace", "Exif.Photo.PixelXDimension", "Exif.Photo.PixelYDimension",
                    "Xmp.exif.ColorSpace", "Exif.Iop.InteroperabilityIndex",
                    "Exif.Nikon3.ColorSpace", "Exif.Canon.ColorSpace"] {
            XCTAssertTrue(MetadataSheetLogic.isProtected(tag), tag)
        }
        XCTAssertFalse(MetadataSheetLogic.isProtected("Exif.Image.Artist"))
        XCTAssertFalse(MetadataSheetLogic.isProtected("Iptc.Application2.Caption"))
        XCTAssertFalse(MetadataSheetLogic.isProtected("Xmp.dc.title"))
    }

    // MARK: Cached write admission

    func testWriteAdmissionRefusesCachedBusyPreviewClosingAndModalStates() {
        XCTAssertNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: false,
                                                       isTransferringClipboard: false, pluginRunning: false,
                                                       engineBusy: false, filterPreviewOpen: false))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: true, isSavingForClose: false,
                                                          isTransferringClipboard: false, pluginRunning: false,
                                                          engineBusy: false, filterPreviewOpen: false))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: true,
                                                          isTransferringClipboard: false, pluginRunning: false,
                                                          engineBusy: false, filterPreviewOpen: false))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: false,
                                                          isTransferringClipboard: true, pluginRunning: false,
                                                          engineBusy: false, filterPreviewOpen: false))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: false,
                                                          isTransferringClipboard: false, pluginRunning: false,
                                                          engineBusy: true, filterPreviewOpen: false))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: false,
                                                          isTransferringClipboard: false, pluginRunning: false,
                                                          engineBusy: false, filterPreviewOpen: true))
        XCTAssertNotNil(MetadataSheetLogic.writeAdmission(isClosing: false, isSavingForClose: false,
                                                          isTransferringClipboard: false, pluginRunning: true,
                                                          engineBusy: false, filterPreviewOpen: false))
    }

    // MARK: Per-action capture

    func testCaptureIsAnExplicitValueSnapshotOfImageTagActionAndOrderedValues() {
        var values = ["a", "b"]
        let capture = MetadataSheetLogic.Capture(image: 42, tag: "Exif.Image.Artist",
                                                 action: .setValues, values: values)
        values.append("late mutation")
        XCTAssertEqual(capture.values, ["a", "b"])
        XCTAssertEqual(capture, MetadataSheetLogic.Capture(image: 42, tag: "Exif.Image.Artist",
                                                           action: .setValues, values: ["a", "b"]))
        XCTAssertNotEqual(capture, MetadataSheetLogic.Capture(image: 42, tag: "Exif.Image.Artist",
                                                              action: .removeTag, values: []))
        XCTAssertNotEqual(capture, MetadataSheetLogic.Capture(image: 43, tag: "Exif.Image.Artist",
                                                              action: .setValues, values: ["a", "b"]))
        let removal = MetadataSheetLogic.Capture(image: 7, tag: "Iptc.Application2.Caption",
                                                 action: .removeTag, values: [])
        XCTAssertEqual(removal.values, [])
        XCTAssertEqual(removal.action, .removeTag)
    }
}
