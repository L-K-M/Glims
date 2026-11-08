import AppKit
import XCTest
@testable import GlimsKit

/// Pure checks for the Fill Path / To Vector Layer slice: the engine
/// version capability, the Paths palette's command metadata (menu titles
/// and the honest vector-style tooltip) and ToolState's fill settings.
@MainActor
final class PathFillVectorTests: XCTestCase {
    func testVectorLayerCapabilityFollowsTheEngineVersion() {
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "3.2.0"), true)
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "3.2.8"), true)
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "3.3.1-dev"), true)
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "4.0"), true)
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "3.0.8"), false)
        XCTAssertEqual(EngineSession.supportsVectorLayers(version: "3.1.9"), false)
        XCTAssertNil(EngineSession.supportsVectorLayers(version: "master"))
        XCTAssertNil(EngineSession.supportsVectorLayers(version: "3"))
    }

    func testLinkLayerCapabilitySharesTheSameParser() {
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.2.0"), true)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.0.8"), false)
        XCTAssertEqual(EngineSession.supportsLinkLayers(version: "3.2.0"),
                       EngineSession.supportsVectorLayers(version: "3.2.0"))
        XCTAssertNil(EngineSession.supportsLinkLayers(version: "glims"))
    }

    func testPathsPaletteCommandsNameFillAndToVectorLayer() {
        let titles = PathsPaletteController.Command.allCases.map(\.menuTitle)
        XCTAssertEqual(titles, ["New Path", "Delete Path", "Path to Selection", "Stroke Path",
                               "Fill Path", "To Vector Layer"])
        XCTAssertEqual(PathsPaletteController.Command.fill.toolTip, "Fill Path")
        let vectorTip = PathsPaletteController.Command.toVectorLayer.toolTip
        XCTAssertTrue(vectorTip.contains("white fill") && vectorTip.contains("black stroke"),
                      "the tooltip states the engine's default style: \(vectorTip)")
        XCTAssertTrue(vectorTip.contains("foreground color is not applied"),
                      "the tooltip does not claim foreground styling: \(vectorTip)")
    }

    func testPathFillSettingsFollowTheForegroundColorOpacityAndAntialias() {
        let state = ToolState.shared
        let savedForeground = state.foreground
        let savedOpacity = state.pathFillOpacity
        let savedAntialias = state.pathFillAntialias
        state.foreground = .red
        state.pathFillOpacity = 0.5
        state.pathFillAntialias = false
        defer {
            state.foreground = savedForeground
            state.pathFillOpacity = savedOpacity
            state.pathFillAntialias = savedAntialias
        }
        let fill = state.pathFill
        XCTAssertEqual(fill.opacity, 0.5)
        XCTAssertEqual(fill.antialias, false)
        let rgb = fill.color.usingColorSpace(.sRGB)
        XCTAssertEqual(rgb.map { Double($0.redComponent) } ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(rgb.map { Double($0.greenComponent) } ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(rgb.map { Double($0.blueComponent) } ?? -1, 0, accuracy: 0.01)
    }
}
