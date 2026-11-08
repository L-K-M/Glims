import AppKit
import XCTest
@testable import GlimsKit

/// The pure rules behind Edit ▸ Stroke Selection…: strict finite
/// whole-string parsing with inline reasons, the by-value brush build,
/// and the Edit menu wiring. No engine, no windows.
@MainActor
final class StrokeSelectionFormTests: XCTestCase {
    // MARK: Whole-string finite parsing

    func testParseFiniteAcceptsWholeFiniteDecimals() {
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("0"), 0)
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("12"), 12)
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("12.5"), 12.5)
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("0.1"), 0.1)
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("500"), 500)
        XCTAssertEqual(StrokeSelectionFormValidation.parseFinite("1e2"), 100)
    }

    func testParseFiniteRejectsEmptyWhitespaceJunkAndNonFinite() {
        for text in ["", " ", "12 ", " 12", "\t12", "12px", "px12", "abc", "12.5.3",
                     "1,5", "--3", "+", "nan", "NaN", "inf", "-inf", "Infinity", "1e999"] {
            XCTAssertNil(StrokeSelectionFormValidation.parseFinite(text), "\"\(text)\" must not parse")
        }
    }

    // MARK: Size and opacity ranges with inline reasons

    func testValidateSizeRangeAndReasons() {
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateSize("12").get(), 12)
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateSize("500").get(), 500)
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateSize("0.5").get(), 0.5)
        if case .failure(let reason) = StrokeSelectionFormValidation.validateSize("0") {
            XCTAssertTrue(reason.message.contains("above 0"), reason.message)
        } else { XCTFail("zero size must fail") }
        if case .failure(let reason) = StrokeSelectionFormValidation.validateSize("-3") {
            XCTAssertTrue(reason.message.contains("above 0"), reason.message)
        } else { XCTFail("negative size must fail") }
        if case .failure(let reason) = StrokeSelectionFormValidation.validateSize("501") {
            XCTAssertTrue(reason.message.contains("500"), reason.message)
        } else { XCTFail("over-max size must fail") }
        if case .failure(let reason) = StrokeSelectionFormValidation.validateSize("12px") {
            XCTAssertFalse(reason.message.isEmpty)
        } else { XCTFail("junk size must fail") }
    }

    func testValidateOpacityRangeAndReasons() {
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateOpacity("0").get(), 0)
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateOpacity("50").get(), 0.5)
        XCTAssertEqual(try? StrokeSelectionFormValidation.validateOpacity("100").get(), 1)
        if case .failure(let reason) = StrokeSelectionFormValidation.validateOpacity("100.5") {
            XCTAssertTrue(reason.message.contains("0 to 100"), reason.message)
        } else { XCTFail("over-100 opacity must fail") }
        if case .failure(let reason) = StrokeSelectionFormValidation.validateOpacity("-1") {
            XCTAssertTrue(reason.message.contains("0 to 100"), reason.message)
        } else { XCTFail("negative opacity must fail") }
        if case .failure = StrokeSelectionFormValidation.validateOpacity("50%") {
            // junk after the number is rejected
        } else { XCTFail("\"50%\" must fail whole-string validation") }
        if case .failure = StrokeSelectionFormValidation.validateOpacity("nan") {
            // non-finite is rejected
        } else { XCTFail("\"nan\" must fail finiteness") }
    }

    // MARK: Brush display name and by-value brush build

    func testBrushDisplayNameUsesIdentityOrDefault() {
        XCTAssertEqual(StrokeSelectionFormValidation.brushDisplayName(nil), "Default")
        let identity = EngineSession.ResourceIdentity(name: "2. Hardness 025",
                                                      collection: nil, isInternal: false)
        XCTAssertEqual(StrokeSelectionFormValidation.brushDisplayName(identity), "2. Hardness 025")
    }

    func testBrushBuildCarriesCapturedIdentityAndLocalValuesByValue() {
        let identity = EngineSession.ResourceIdentity(name: "2. Block 01",
                                                      collection: "Brushes", isInternal: false)
        let result = StrokeSelectionFormValidation.brush(tool: .eraser,
                                                         capturedBrush: EngineSession.Brush(resource: identity),
                                                         sizeText: "9",
                                                         opacityText: "50",
                                                         color: .red)
        guard case .success(let brush) = result else {
            return XCTFail("valid input must build a brush")
        }
        XCTAssertEqual(brush.tool, .eraser)
        XCTAssertEqual(brush.size, 9)
        XCTAssertEqual(brush.opacity, 0.5)
        XCTAssertEqual(brush.red, 1)
        XCTAssertEqual(brush.green, 0)
        XCTAssertEqual(brush.blue, 0)
        // The persistent identity crosses by value — never a session handle.
        XCTAssertEqual(brush.resource, identity)
    }

    func testBrushBuildKeepsUnexposedCapturedSettings() throws {
        var captured = EngineSession.Brush()
        captured.tool = .eraser
        captured.pressureSize = false
        captured.hardness = 0.17
        captured.rate = 0.25
        captured.flow = 0.35
        captured.exposure = 0.45
        captured.tones = .highlights
        captured.antiErase = true
        captured.source = EngineSession.Brush.Source(drawable: 91, x: 1.5, y: 2.5)
        captured.resource = EngineSession.ResourceIdentity(name: "Captured", collection: nil, isInternal: false)
        let result = try StrokeSelectionFormValidation.brush(tool: .eraser, capturedBrush: captured,
                                                             sizeText: "9", opacityText: "50", color: .red).get()
        var expected = captured
        expected.size = 9
        expected.opacity = 0.5
        expected.red = 1
        expected.green = 0
        expected.blue = 0
        XCTAssertEqual(result, expected, "Unexposed settings, including anti-erase, remain captured")
    }

    func testBrushBuildPropagatesTheFirstInlineReason() {
        let identity = EngineSession.ResourceIdentity(name: "B", collection: nil, isInternal: false)
        if case .failure(let reason) = StrokeSelectionFormValidation.brush(tool: .paintbrush,
                                                                           capturedBrush: EngineSession.Brush(resource: identity),
                                                                           sizeText: "junk",
                                                                           opacityText: "50",
                                                                           color: .black) {
            XCTAssertFalse(reason.message.isEmpty)
        } else { XCTFail("invalid size must fail the build") }
        if case .failure(let reason) = StrokeSelectionFormValidation.brush(tool: .pencil,
                                                                           capturedBrush: EngineSession.Brush(),
                                                                           sizeText: "9",
                                                                           opacityText: "1000",
                                                                           color: .black) {
            XCTAssertTrue(reason.message.contains("0 to 100"), reason.message)
        } else { XCTFail("invalid opacity must fail the build") }
        // A nil captured resource keeps the inherit convention (nil), never
        // a substituted handle.
        if case .success(let brush) = StrokeSelectionFormValidation.brush(tool: .paintbrush,
                                                                          capturedBrush: EngineSession.Brush(),
                                                                          sizeText: "9",
                                                                          opacityText: "100",
                                                                          color: .black) {
            XCTAssertNil(brush.resource)
        } else { XCTFail("valid input must build a brush") }
    }

    func testOfferedToolsAreTheThreePaintTools() {
        XCTAssertEqual(StrokeSelectionFormValidation.offeredTools, [.paintbrush, .pencil, .eraser])
        XCTAssertEqual(StrokeSelectionFormValidation.offeredTools.map(\.paintTool),
                       [.paintbrush, .pencil, .eraser])
    }

    // MARK: Menu wiring

    func testTheEditMenuListsStrokeSelectionOnTheDocumentSelector() {
        let menu = MainMenu.make()
        let edit = menu.items.first { $0.title == "Edit" }?.submenu
        let item = edit?.items.first { $0.title == "Stroke Selection…" }
        XCTAssertEqual(item?.action, #selector(DocumentWindowController.strokeSelection(_:)))
        // It sits with the other fill/stroke commands, after Fill….
        let titles = edit?.items.map(\.title) ?? []
        XCTAssertTrue(titles.firstIndex(of: "Stroke Selection…") ?? 0
            > titles.firstIndex(of: "Fill…") ?? -1)
    }
}
