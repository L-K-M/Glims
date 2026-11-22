import XCTest
@testable import GlimsKit

/// Ruler units and Clear Guides' menu rule. Expected positions are worked
/// out by hand from the unit's definition.
final class RulerUnitTests: XCTestCase {
    private func majors(_ unit: RulerUnit, resolution: Double?, extent: Double,
                        pointsPerPixel: Double = 1) throws -> (positions: [Double], labels: [String]) {
        let plan = try XCTUnwrap(PixelRulerPlan.plan(visibleStart: 0, visibleEnd: extent,
                                                     pointsPerPixel: pointsPerPixel, imageExtent: extent,
                                                     unit: unit, resolution: resolution))
        XCTAssertEqual(plan.unit, unit)
        XCTAssertTrue(plan.ticks.filter { !$0.isMajor }.allSatisfy { $0.label == nil })
        let majors = plan.ticks.filter(\.isMajor)
        return (majors.map(\.imagePosition), majors.compactMap(\.label))
    }

    private func assertMajors(_ unit: RulerUnit, resolution: Double?, extent: Double, pointsPerPixel: Double = 1,
                              positions: [Double], labels: [String],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try majors(unit, resolution: resolution, extent: extent, pointsPerPixel: pointsPerPixel)
        XCTAssertEqual(found.labels, labels, file: file, line: line)
        XCTAssertEqual(found.positions.count, positions.count, file: file, line: line)
        for (got, want) in zip(found.positions, positions) {
            XCTAssertEqual(got, want, accuracy: 1e-6, file: file, line: line)
        }
    }

    func testEachPrintLengthLabelsInItsOwnUnit() throws {
        try assertMajors(.inches, resolution: 100, extent: 200,
                         positions: [0, 50, 100, 150, 200], labels: ["0", "0.5", "1", "1.5", "2"])
        try assertMajors(.centimeters, resolution: 254, extent: 200,
                         positions: [0, 50, 100, 150, 200], labels: ["0", "0.5", "1", "1.5", "2"])
        try assertMajors(.millimeters, resolution: 254, extent: 200,
                         positions: [0, 50, 100, 150, 200], labels: ["0", "5", "10", "15", "20"])
        try assertMajors(.points, resolution: 144, extent: 400,
                         positions: [0, 100, 200, 300, 400], labels: ["0", "50", "100", "150", "200"])
        try assertMajors(.picas, resolution: 72, extent: 240,
                         positions: [0, 60, 120, 180, 240], labels: ["0", "5", "10", "15", "20"])
    }

    func testPercentIsOfTheImageExtentAndKeepsItsFarEdge() throws {
        try assertMajors(.percent, resolution: nil, extent: 400,
                         positions: [0, 80, 160, 240, 320, 400], labels: ["0", "20", "40", "60", "80", "100"])
        try assertMajors(.percent, resolution: nil, extent: 333,
                         positions: [0, 66.6, 133.2, 199.8, 266.4, 333], labels: ["0", "20", "40", "60", "80", "100"])
    }

    func testEachAxisUsesItsOwnResolution() throws {
        try assertMajors(.inches, resolution: 300, extent: 600, pointsPerPixel: 0.5,
                         positions: [0, 150, 300, 450, 600], labels: ["0", "0.5", "1", "1.5", "2"])
        try assertMajors(.inches, resolution: 150, extent: 600, pointsPerPixel: 0.5,
                         positions: [0, 150, 300, 450, 600], labels: ["0", "1", "2", "3", "4"])
    }

    func testInchesStepInEighthsAndThenInDecimals() throws {
        try assertMajors(.inches, resolution: 100, extent: 50, pointsPerPixel: 4,
                         positions: [0, 12.5, 25, 37.5, 50], labels: ["0", "0.125", "0.25", "0.375", "0.5"])
        try assertMajors(.inches, resolution: 100, extent: 20, pointsPerPixel: 10,
                         positions: [0, 5, 10, 15, 20], labels: ["0", "0.05", "0.1", "0.15", "0.2"])
    }

    func testInchesDivideIntoQuarters() throws {
        let plan = try XCTUnwrap(PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 100, pointsPerPixel: 1,
                                                     imageExtent: 100, unit: .inches, resolution: 100))
        XCTAssertEqual(plan.minorSpacing, 12.5)
        XCTAssertEqual(plan.ticks.count, 9)
    }

    func testLabelsHaveNoFloatNoise() throws {
        try assertMajors(.millimeters, resolution: 25.4, extent: 0.5, pointsPerPixel: 500,
                         positions: [0, 0.1, 0.2, 0.3, 0.4, 0.5], labels: ["0", "0.1", "0.2", "0.3", "0.4", "0.5"])
    }

    func testAnUnmeasurableLengthFallsBackToPixels() throws {
        let pixels = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 400, pointsPerPixel: 1, imageExtent: 400)
        XCTAssertEqual(pixels?.unit, .pixels)
        for resolution in [nil, 0, -72, Double.nan, Double.infinity] as [Double?] {
            for unit in RulerUnit.allCases where unit.length != nil {
                XCTAssertEqual(PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 400, pointsPerPixel: 1,
                                                   imageExtent: 400, unit: unit, resolution: resolution), pixels)
            }
        }
        let empty = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 100, pointsPerPixel: 1,
                                        imageExtent: 0, unit: .percent)
        XCTAssertEqual(empty?.ticks, [])
    }

    func testEveryUnitStaysBoundedAndLegibleAtTheExtremes() throws {
        for unit in RulerUnit.allCases {
            for resolution in [ImageSizeModel.minimumResolution, 72, 3000] {
                for extent in [1.0, 4001, 262_144] {
                    for scale in [0.0001, 0.05, 1, 32, 10_000] {
                        let plan = try XCTUnwrap(PixelRulerPlan.plan(visibleStart: -10, visibleEnd: extent + 10,
                                                                     pointsPerPixel: scale, imageExtent: extent,
                                                                     unit: unit, resolution: resolution))
                        let context = "\(unit) at \(resolution) ppi, \(extent) px, \(scale) pt/px"
                        let positions = plan.ticks.map(\.imagePosition)
                        XCTAssertLessThanOrEqual(plan.ticks.count, PixelRulerPlan.maximumTicks, context)
                        XCTAssertEqual(positions, positions.sorted(), context)
                        XCTAssertTrue(positions.allSatisfy { $0 >= 0 && $0 <= extent }, context)
                        let labels = plan.ticks.compactMap(\.label)
                        XCTAssertEqual(Set(labels).count, labels.count, context)
                        for label in labels {
                            if let dot = label.firstIndex(of: ".") {
                                XCTAssertLessThanOrEqual(label.distance(from: dot, to: label.endIndex) - 1, 6, context)
                            }
                        }
                        // Only the pixel floor and the finest step may crowd.
                        let floor = unit == .pixels ? 1
                            : (PixelRulerPlan.pixelsPerUnit(unit, resolution: resolution, imageExtent: extent) ?? 1) * 1e-6
                        if plan.majorSpacing > floor * (1 + 1e-6) {
                            XCTAssertGreaterThanOrEqual(plan.majorSpacing * scale,
                                                        PixelRulerPlan.targetMajorSpacingPoints * (1 - 1e-6), context)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testTheAxesSwapOnlyAtQuarterTurns() {
        for degrees in [90.0, -90, 270, 450] {
            XCTAssertTrue(PixelRulerView.axesSwap(rotationDegrees: degrees), "\(degrees)")
        }
        for degrees in [0.0, 45, 89, 180, 360] {
            XCTAssertFalse(PixelRulerView.axesSwap(rotationDegrees: degrees), "\(degrees)")
        }
    }

    func testMenuTagsRoundTrip() {
        XCTAssertEqual(RulerUnit.allCases.map(\.title),
                       ["Pixels", "Inches", "Centimeters", "Millimeters", "Points", "Picas", "Percent"])
        for unit in RulerUnit.allCases { XCTAssertEqual(RulerUnit(tag: unit.tag), unit) }
        XCTAssertNil(RulerUnit(tag: -1))
        XCTAssertNil(RulerUnit(tag: RulerUnit.allCases.count))
    }

    @MainActor
    func testTheUnitPersistsAndResets() throws {
        let suite = FileManager.default.temporaryDirectory
            .appendingPathComponent("glims-ruler-units-\(UUID().uuidString)").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.rulerUnit, .pixels)
        preferences.rulerUnit = .picas
        XCTAssertEqual(EditorPreferences(defaults: defaults).rulerUnit, .picas)
        preferences.reset()
        XCTAssertEqual(preferences.rulerUnit, .pixels)
        defaults.set("cubits", forKey: "editor.rulerUnit")
        XCTAssertEqual(preferences.rulerUnit, .pixels)
    }

    @MainActor
    func testClearGuidesNeedsGuidesAndNoLock() {
        XCTAssertFalse(GuidesSheetLogic.canClear(guideCount: 0, locksGuides: false))
        XCTAssertFalse(GuidesSheetLogic.canClear(guideCount: 3, locksGuides: true))
        XCTAssertTrue(GuidesSheetLogic.canClear(guideCount: 3, locksGuides: false))
    }
}
