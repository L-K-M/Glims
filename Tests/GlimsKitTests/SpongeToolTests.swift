import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class SpongeToolTests: XCTestCase {
    func testSpongeChoicesHaveStableRoutesAndCapturedSettings() {
        let state = ToolState()
        state.select(.burn)
        state.select(shortcut: "O", cycle: true)
        XCTAssertEqual(state.current, .spongeDesaturate)
        state.update(.spongeDesaturate) { $0.size = 31; $0.opacity = 0.25 }
        let captured = state.brush(for: .spongeDesaturate)
        state.select(shortcut: "O", cycle: true)
        XCTAssertEqual(state.current, .spongeSaturate)
        XCTAssertEqual(state.brush(for: .spongeSaturate).tool, .spongeSaturate)
        XCTAssertEqual(state.brush(for: .spongeSaturate).opacity, 0.5)
        state.update(.spongeDesaturate) { $0.opacity = 0.75 }
        XCTAssertEqual(captured.tool, .spongeDesaturate)
        XCTAssertEqual(captured.size, 31)
        XCTAssertEqual(captured.opacity, 0.25)
        XCTAssertNil(RecorderStrokeCommand.Settings(captured), "unsupported Recorder tools must remain explicit")
        XCTAssertEqual(ToolMenuCatalog.tool(forTag: 27), .spongeDesaturate)
        XCTAssertEqual(ToolMenuCatalog.tool(forTag: 28), .spongeSaturate)
    }

    func testSpongePresetRoundTripKeepsDirectionBrushAndStrength() throws {
        let suite = "ch.lkmc.Glims.Tests.Sponge." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ToolState(brushStore: BrushSelectionStore(defaults: defaults))
        let store = PaintToolPresetStore(defaults: defaults)
        for tool in [ToolID.spongeDesaturate, .spongeSaturate] {
            state.update(tool) { $0.size = 42; $0.opacity = 0.3; $0.hardness = 0.7; $0.pressureSize = false }
            let settings = PaintToolPresetControls.captureSettings(from: state.brush(for: tool))
            let preset = try store.create(tool: tool, name: tool.name, settings: settings)
            let loaded = try XCTUnwrap(store.load().first { $0.id == preset.id })
            state.update(tool) { $0.size = 1; $0.opacity = 1 }
            PaintToolPresetControls.apply(loaded, to: state)
            XCTAssertEqual(state.current, tool)
            XCTAssertEqual(state.brush(for: tool).tool, tool.paintTool)
            XCTAssertEqual(state.brush(for: tool).size, 42)
            XCTAssertEqual(state.brush(for: tool).opacity, 0.3)
            XCTAssertEqual(state.brush(for: tool).hardness, 0.7)
            XCTAssertFalse(state.brush(for: tool).pressureSize)
        }
    }
}
