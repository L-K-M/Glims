import AppKit
import XCTest
@testable import GlimsKit

/// The pure rules behind Layer ▸ New Adjustment Layer…: the menu wiring,
/// the name rule, the known-set filtering against catalog support, the
/// default-name uniquifier and the cached color-mode gate.
@MainActor
final class AdjustmentLayerControlsTests: XCTestCase {
    private func operation(_ name: String, title: String? = nil,
                           support: EngineSession.FilterOpSupport = .supported) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title ?? name, categories: ["color"],
                                      blurb: "", support: support)
    }

    // MARK: Menu wiring

    func testTheLayerMenuListsNewAdjustmentLayerAfterNewLayerGroup() {
        let menu = MainMenu.make()
        let layer = menu.items.first { $0.title == "Layer" }?.submenu
        let titles = layer?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        let group = titles.firstIndex(of: "New Layer Group") ?? -1
        let adjustment = titles.firstIndex(of: "New Adjustment Layer…") ?? -1
        XCTAssertGreaterThan(group, -1)
        XCTAssertEqual(adjustment, group + 1, "New Adjustment Layer… sits right after New Layer Group")
        let item = layer?.items.first { $0.title == "New Adjustment Layer…" }
        XCTAssertEqual(item?.action, #selector(DocumentWindowController.newAdjustmentLayer(_:)))
        XCTAssertEqual(item?.keyEquivalent, "", "the item carries no new keyboard shortcut")
    }

    // MARK: Name rule (trim/full-string/NUL/length policy)

    func testNameIsTrimmedAsAWholeString() {
        XCTAssertEqual(try? AdjustmentLayerLogic.validateName("  My Layer\n").get(), "My Layer")
        XCTAssertEqual(try? AdjustmentLayerLogic.validateName("My Layer").get(), "My Layer")
        // Full-string parsing: a valid prefix alone is not accepted.
        XCTAssertNil(try? AdjustmentLayerLogic.validateName("   ").get())
        XCTAssertNil(try? AdjustmentLayerLogic.validateName("").get())
    }

    func testNameRejectsNULAnywhere() {
        XCTAssertNil(try? AdjustmentLayerLogic.validateName("ok\0name").get())
        XCTAssertNil(try? AdjustmentLayerLogic.validateName("\0").get())
        XCTAssertEqual(try? AdjustmentLayerLogic.validateName("ok name").get(), "ok name")
    }

    func testNameLengthCountsUTF8Bytes() {
        XCTAssertEqual(try? AdjustmentLayerLogic.validateName(String(repeating: "a", count: 255)).get(),
                       String(repeating: "a", count: 255))
        XCTAssertNil(try? AdjustmentLayerLogic.validateName(String(repeating: "a", count: 256)).get())
        // A multibyte character counts its bytes, not its characters.
        XCTAssertNil(try? AdjustmentLayerLogic.validateName(String(repeating: "é", count: 128)).get())
        XCTAssertEqual(try? AdjustmentLayerLogic.validateName(String(repeating: "é", count: 127)).get(),
                       String(repeating: "é", count: 127))
    }

    // MARK: Operation filtering (known set, actual native support)

    func testOnlySupportedKnownOperationsAreOfferedInKnownOrder() {
        let catalog = [
            operation("gegl:invert-linear"),
            operation("gegl:saturation", support: .needsConfig),
            operation("gegl:brightness-contrast", title: "Brightness-Contrast"),
            operation("gegl:color-temperature", support: .needsAuxInput),
            operation("gegl:hue-chroma"),
            operation("gegl:some-other-op"),
            operation("gegl:exposure"),
        ]
        let offered = AdjustmentLayerLogic.availableOperations(in: catalog)
        XCTAssertEqual(offered.map(\.name),
                       ["gegl:brightness-contrast", "gegl:exposure", "gegl:hue-chroma", "gegl:invert-linear"],
                       "unsupported, config/aux operations and unknown names never appear, in known-set order")
        XCTAssertEqual(offered.first?.title, "Brightness-Contrast", "the native title is shown, not a fallback")
    }

    func testNoSupportedKnownOperationOffersNothing() {
        XCTAssertTrue(AdjustmentLayerLogic.availableOperations(in: []).isEmpty)
        XCTAssertTrue(AdjustmentLayerLogic.availableOperations(in: [
            operation("gegl:invert-linear", support: .needsConfig),
            operation("gegl:gaussian-blur"),
        ]).isEmpty, "no unsupported fallback to an unlisted operation")
    }

    func testDedicatedConfigOperationsWithNativeEditorsAreOffered() {
        let catalog = [
            operation("gimp:curves", title: "Curves", support: .needsConfig),
            operation("gimp:levels", title: "Levels", support: .needsConfig),
            operation("gimp:hue-saturation", title: "Hue-Saturation", support: .needsConfig),
            operation("gimp:color-balance", title: "Color Balance", support: .needsConfig),
            operation("gimp:brightness-contrast", title: "Brightness-Contrast", support: .needsConfig),
            operation("gimp:unknown-dedicated", support: .needsConfig),
            operation("gegl:saturation", support: .needsConfig),
        ]
        XCTAssertEqual(AdjustmentLayerLogic.availableOperations(in: catalog).map(\.name),
                       ["gimp:levels", "gimp:curves", "gimp:color-balance", "gimp:hue-saturation"],
                       "dedicated config ops the effect editor drives appear in known-set order; "
                           + "config ops outside the known set never do")
    }

    func testColorPosterizeUsesTheAlphaPreservingOperation() {
        let safe = operation("glims:posterize", title: "Posterize")
        let changesAlpha = operation("gimp:posterize", title: "Posterize")
        XCTAssertEqual(AdjustmentLayerLogic.availableOperations(in: [safe, changesAlpha]).map(\.name),
                       ["glims:posterize"])
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(safe), "Posterize…")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(changesAlpha), "Posterize Including Transparency…")
    }

    func testCanonicalInvertOperationsFromTheNativeCatalogAreOffered() {
        let catalog = [operation("gegl:invert-gamma"), operation("gegl:invert-linear")]
        XCTAssertEqual(AdjustmentLayerLogic.availableOperations(in: catalog).map(\.name),
                       ["gegl:invert-linear", "gegl:invert-gamma"])
    }

    // MARK: Default name

    func testDefaultNameUniquifiesAgainstExistingLayers() {
        XCTAssertEqual(AdjustmentLayerLogic.defaultName(for: "Invert", existingNames: []), "Invert")
        XCTAssertEqual(AdjustmentLayerLogic.defaultName(for: "Invert", existingNames: ["Invert"]), "Invert 2")
        XCTAssertEqual(AdjustmentLayerLogic.defaultName(for: "Invert",
                                                        existingNames: ["Invert", "Invert 2"]), "Invert 3")
    }

    // MARK: Cached mode gate

    func testModeAdmissionAllowsRGBAndGrayscaleOnly() {
        XCTAssertEqual(AdjustmentLayerLogic.modeAdmission(.rgb), .init(allowed: true, reason: nil))
        XCTAssertEqual(AdjustmentLayerLogic.modeAdmission(.grayscale), .init(allowed: true, reason: nil))
        let indexed = AdjustmentLayerLogic.modeAdmission(.indexed)
        XCTAssertFalse(indexed.allowed)
        XCTAssertEqual(indexed.reason?.contains("indexed"), true, "Indexed is visibly unavailable with a reason")
        XCTAssertFalse(AdjustmentLayerLogic.modeAdmission(.unknown).allowed)
    }
}
