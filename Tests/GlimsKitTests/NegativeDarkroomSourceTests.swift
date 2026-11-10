import XCTest
@testable import GlimsKit

/// Pure enum/catalog role/support gates for the Negative Darkroom
/// captured-source contract. No windows or engine calls.
@MainActor
final class NegativeDarkroomSourceTests: XCTestCase {
    func testNegativeDarkroomOperationIdentityAndRole() {
        XCTAssertEqual(SourceFilterOperation(rawValue: "gegl:negative-darkroom"), .negativeDarkroom)
        XCTAssertEqual(SourceFilterOperation.negativeDarkroom.title, "Negative Darkroom")
        XCTAssertEqual(SourceFilterOperation.negativeDarkroom.accessibilityName, "Negative darkroom")
        XCTAssertEqual(SourceFilterOperation.negativeDarkroom.sourceLabel, "Dodge/burn map")
    }

    func testExistingSourceOperationsRemainUnchanged() {
        let bump = SourceFilterOperation.bumpMap
        XCTAssertEqual(bump.rawValue, "gegl:bump-map")
        XCTAssertEqual(bump.title, "Bump Map")
        XCTAssertEqual(bump.accessibilityName, "Bump map")
        XCTAssertEqual(bump.sourceLabel, "Height map")

        let variable = SourceFilterOperation.variableBlur
        XCTAssertEqual(variable.rawValue, "gegl:variable-blur")
        XCTAssertEqual(variable.title, "Variable Blur")
        XCTAssertEqual(variable.accessibilityName, "Variable blur")
        XCTAssertEqual(variable.sourceLabel, "Blur mask")

        let selective = SourceFilterOperation.selectiveGaussianBlur
        XCTAssertEqual(selective.rawValue, "gegl:gaussian-blur-selective")
        XCTAssertEqual(selective.title, "Selective Gaussian Blur")
        XCTAssertEqual(selective.accessibilityName, "Selective Gaussian blur")
        XCTAssertEqual(selective.sourceLabel, "Contrast reference")
    }

    func testUnknownOrIncorrectSourceSupportIsRefused() {
        XCTAssertNil(SourceFilterOperation(rawValue: "gegl:gaussian-blur"))
        XCTAssertNil(SourceFilterOperation(rawValue: "gegl:unknown"))

        let unknown = EngineSession.FilterOperation(
            name: "gegl:unknown", title: "Unknown", categories: [], blurb: "", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesSourceChooser(unknown))

        let wrongName = EngineSession.FilterOperation(
            name: "gegl:gaussian-blur", title: "Gaussian Blur", categories: [], blurb: "", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesSourceChooser(wrongName))

        let wrongSupport = EngineSession.FilterOperation(
            name: "gegl:negative-darkroom", title: "Negative Darkroom", categories: [], blurb: "", support: .supported)
        XCTAssertFalse(NativeFilterMenuLayout.usesSourceChooser(wrongSupport))

        let correct = EngineSession.FilterOperation(
            name: "gegl:negative-darkroom", title: "Negative Darkroom", categories: [], blurb: "", support: .needsAuxInput)
        XCTAssertTrue(NativeFilterMenuLayout.usesSourceChooser(correct))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(correct), "Negative Darkroom…")
    }
}
