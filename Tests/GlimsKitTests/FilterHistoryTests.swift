import XCTest
@testable import GlimsKit

/// The Last Filter selection rule: which applied filter, plug-in or
/// native, becomes the one Command-F repeats, and how Recently Used
/// orders and deduplicates them.
final class FilterHistoryTests: XCTestCase {
    private func plugIn(_ name: String) -> AppliedFilter {
        .plugIn(EngineSession.Procedure(name: name, label: "\(name)…", menuPath: "",
                                        blurb: "", isSensitive: true))
    }

    private func native(_ operation: String, variant: String? = nil,
                        title: String, repeatable: Bool = true) -> AppliedFilter {
        .native(AppliedNativeFilter(operation: operation, variant: variant, title: title,
                                    capture: .names([]), isRepeatable: repeatable,
                                    settings: .properties([:])))
    }

    func testNewestApplyWinsAcrossKinds() {
        var history = FilterHistory()
        XCTAssertNil(history.last)
        history.record(plugIn("plug-in-checkerboard"), limit: 8)
        XCTAssertEqual(history.last, plugIn("plug-in-checkerboard"))
        history.record(native("gegl:gaussian-blur", title: "Gaussian Blur"), limit: 8)
        XCTAssertEqual(history.last, native("gegl:gaussian-blur", title: "Gaussian Blur"),
                       "a native filter applied after a plug-in becomes the last filter")
        history.record(plugIn("plug-in-checkerboard"), limit: 8)
        XCTAssertEqual(history.last, plugIn("plug-in-checkerboard"),
                       "a plug-in applied after a native filter becomes the last filter")
    }

    func testReapplyingMovesToFrontWithoutDuplicating() {
        var history = FilterHistory()
        history.record(native("gegl:gaussian-blur", title: "Gaussian Blur"), limit: 8)
        history.record(plugIn("plug-in-checkerboard"), limit: 8)
        history.record(native("gegl:gaussian-blur", title: "Gaussian Blur"), limit: 8)
        XCTAssertEqual(history.entries.map(\.title), ["Gaussian Blur", "plug-in-checkerboard"])
    }

    func testReapplyingAPlugInDedupesByName() {
        var history = FilterHistory()
        history.record(plugIn("plug-in-checkerboard"), limit: 8)
        history.record(native("gegl:gaussian-blur", title: "Gaussian Blur"), limit: 8)
        // The engine's list can change a command's label or sensitivity.
        history.record(.plugIn(EngineSession.Procedure(name: "plug-in-checkerboard", label: "Checkerboard…",
                                                       menuPath: "", blurb: "", isSensitive: false)), limit: 8)
        XCTAssertEqual(history.entries.map(\.title), ["Checkerboard", "Gaussian Blur"],
                       "a plug-in is one entry per procedure name")
    }

    func testSameOperationDifferentVariantStaysDistinct() {
        var history = FilterHistory()
        history.record(native("gegl:median-blur", variant: "maximum", title: "Maximum"), limit: 8)
        history.record(native("gegl:median-blur", variant: "minimum", title: "Minimum"), limit: 8)
        XCTAssertEqual(history.entries.count, 2,
                       "Maximum and Minimum are different filters of one operation")
        XCTAssertEqual(history.last, native("gegl:median-blur", variant: "minimum", title: "Minimum"))
    }

    func testListCapsAtTheLimitKeepingNewest() {
        var history = FilterHistory()
        for index in 0..<10 { history.record(plugIn("plug-in-\(index)"), limit: 8) }
        XCTAssertEqual(history.entries.count, 8)
        XCTAssertEqual(history.entries.first, plugIn("plug-in-9"))
        XCTAssertEqual(history.entries.last, plugIn("plug-in-2"))
    }

    func testNotRepeatableEntryIsStillLast() {
        var history = FilterHistory()
        history.record(native("gegl:gaussian-blur", title: "Gaussian Blur"), limit: 8)
        history.record(native("gegl:oilify", title: "Oilify", repeatable: false), limit: 8)
        guard case .native(let applied)? = history.last else {
            return XCTFail("a captured-source apply is still the last filter")
        }
        XCTAssertEqual(applied.title, "Oilify")
        XCTAssertFalse(applied.isRepeatable,
                       "a filter needing its source chooser is named but not repeatable")
    }

    func testTitlesNeverCarryEllipsis() {
        XCTAssertEqual(plugIn("plug-in-checkerboard").title, "plug-in-checkerboard")
        XCTAssertEqual(native("gegl:gaussian-blur", title: "Gaussian Blur").title, "Gaussian Blur")
    }
}
