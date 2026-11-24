import XCTest
@testable import GlimsKit

final class PaintOptionsTests: XCTestCase {
    func testPaintModesAreDistinctWithNormalFirst() {
        let modes = EngineSession.PaintModes.named
        XCTAssertEqual(modes.first?.nick, EngineSession.PaintModes.normal)
        XCTAssertEqual(Set(modes.map(\.nick)).count, modes.count)
        // The Tool Options pop-up drops repeated titles.
        XCTAssertEqual(Set(modes.map(\.title)).count, modes.count)
        XCTAssertTrue(modes.allSatisfy { !$0.nick.isEmpty && $0.nick.utf8.count < 64 })
        XCTAssertTrue(EngineSession.PaintModes.all.contains("behind"))
        XCTAssertFalse(EngineSession.PaintModes.all.contains("erase"))
    }

    func testModeToolsAndFadeToolsMatchTheEngineRules() {
        typealias Modes = EngineSession.PaintModes
        XCTAssertEqual(EngineSession.Brush.Tool.allCases.filter(Modes.applies(to:)),
                       [.paintbrush, .pencil, .airbrush, .clone])
        XCTAssertEqual(Modes.fadeTools, [.paintbrush, .pencil, .airbrush])
    }

    func testDefaultsHaveNoPaintOptionsAndClearingRestoresThem() {
        var brush = EngineSession.Brush()
        XCTAssertFalse(brush.hasPaintOptions)
        brush.paintMode = "normal"
        XCTAssertFalse(brush.hasPaintOptions, "an explicit Normal is the default")

        for change in [{ (b: inout EngineSession.Brush) in b.paintMode = "multiply" },
                       { $0.spacing = 0.5 },
                       { $0.fade = .init(steps: 10, target: .transparent) },
                       { $0.clonePattern = .init(resource: .init(name: "Pine", collection: nil, isInternal: false),
                                                 aligned: true) }] {
            var changed = EngineSession.Brush()
            change(&changed)
            XCTAssertTrue(changed.hasPaintOptions)
            changed.fadeBackground = .init(red: 0, green: 0, blue: 1)
            changed.clearPaintOptions()
            XCTAssertEqual(changed, EngineSession.Brush())
        }
    }

    func testStrokesWithPaintOptionsRecordByTool() {
        var brush = EngineSession.Brush()
        brush.tool = .pencil
        XCTAssertNotNil(RecorderStrokeCommand.Settings(brush))
        brush.spacing = 0.25
        XCTAssertNotNil(RecorderStrokeCommand.Settings(brush))
        brush.paintMode = "screen"
        XCTAssertNotNil(RecorderStrokeCommand.Settings(brush))
        brush.tool = .spongeDesaturate
        XCTAssertNil(RecorderStrokeCommand.Settings(brush), "a Sponge stroke keeps refusing options")
        brush.tool = .eraser
        brush.paintMode = "normal"
        XCTAssertNotNil(RecorderStrokeCommand.Settings(brush), "the Eraser records spacing alone")
        brush.paintMode = "screen"
        XCTAssertNil(RecorderStrokeCommand.Settings(brush), "the Eraser does not record a blend mode")
        brush.tool = .pencil
        brush.clonePattern = .init(resource: .init(name: "Pine", collection: nil, isInternal: false),
                                   aligned: true)
        XCTAssertNil(RecorderStrokeCommand.Settings(brush), "a clone pattern stays unrecorded")
    }

    func testStrokeSelectionPaintsWithoutTheToolsPaintOptions() throws {
        var captured = EngineSession.Brush()
        captured.paintMode = "multiply"
        captured.spacing = 2
        captured.fade = .init(steps: 5, target: .background)
        let result = StrokeSelectionFormValidation.brush(tool: .paintbrush, capturedBrush: captured,
                                                         sizeText: "3", opacityText: "100", color: .black)
        let brush = try result.get()
        XCTAssertFalse(brush.hasPaintOptions)
        XCTAssertEqual(brush.size, 3)
    }
}
