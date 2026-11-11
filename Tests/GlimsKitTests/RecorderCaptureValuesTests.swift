import XCTest
import AppKit
@testable import GlimsKit

final class RecorderCaptureValuesTests: XCTestCase {
    func testColorKeepsAllFourLiteralComponentsIncludingTransparency() throws {
        let color = try RecorderColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 0.8)
        XCTAssertEqual([color.red, color.green, color.blue, color.alpha], [0.2, 0.35, 0.6, 0.8])
        XCTAssertEqual(try RecorderColor(red: 0, green: 1, blue: 0.5, alpha: 0).alpha, 0)
    }

    func testColorRejectsInvalidComponentsWithoutClamping() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            for index in 0..<4 {
                var values = [0.2, 0.3, 0.4, 0.5]
                values[index] = invalid
                XCTAssertThrowsError(try RecorderColor(red: values[0], green: values[1], blue: values[2], alpha: values[3]))
            }
        }
    }

    func testNativeColorBridgeKeepsTheIndependentSRGBFixture() throws {
        let captured = try EngineSession.recorderColor(NSColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 0.8))
        XCTAssertEqual(captured.red, 0.2)
        XCTAssertEqual(captured.green, 0.35)
        XCTAssertEqual(captured.blue, 0.6)
        XCTAssertEqual(captured.alpha, 0.8)
    }

    func testFirstLayerDescriptionSurvivesLaterRenameAndGeometryChanges() {
        let symbol = UUID()
        let ancestor = RecorderTargetDescription.Ancestor(name: "Original group", kind: .group, siblingIndex: 1)
        let original = RecorderTargetDescription(name: "Original layer", kind: .text, ancestors: [ancestor],
            siblingIndex: 2, bounds: .init(x: -4, y: 7, width: 41, height: 29))
        let renamed = RecorderTargetDescription(name: "Renamed", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 1, height: 1))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(original)])
        catalog.acceptFirst([symbol: .available(renamed)])
        catalog.acceptFirst([symbol: .unavailable("Deleted after recording")])
        XCTAssertEqual(catalog.values[symbol], .available(original))
    }

    func testUnavailableFirstDescriptionCannotBeGuessedFromLaterState() {
        let symbol = UUID()
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .unavailable("The original target was missing")])
        catalog.acceptFirst([symbol: .available(.init(name: "A later namesake", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 3, height: 2)))])
        XCTAssertEqual(catalog.values[symbol], .unavailable("The original target was missing"))
    }

    func testEqualNamesDoNotCollapseDistinctSymbolsAndFreshCatalogHasNoOldDescriptions() {
        let first = UUID(), second = UUID()
        let row = RecorderTargetDescription(name: "Duplicate name", kind: .channel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([first: .available(row), second: .available(row)])
        XCTAssertEqual(catalog.values.count, 2)
        let snapshot = catalog
        catalog = RecorderDescriptionCatalog()
        XCTAssertTrue(catalog.values.isEmpty)
        XCTAssertEqual(snapshot.values.count, 2)
    }
}
