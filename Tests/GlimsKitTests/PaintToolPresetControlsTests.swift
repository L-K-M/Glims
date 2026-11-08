import AppKit
import XCTest
@testable import GlimsKit

/// Pure checks for the preset CONTROLS slice (docs/tool-preset-controls.md):
/// value-based capture/apply against an injected `ToolState` plus
/// UserDefaults-backed stores, and the retained panel's UUID selection and
/// inline error behavior. Separate from `PaintToolPresetTests` (the model and
/// store). No engine, no document state.
@MainActor
final class PaintToolPresetControlsTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.presetcontrols.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func makeState(_ defaults: UserDefaults) -> ToolState {
        ToolState(brushStore: BrushSelectionStore(defaults: defaults))
    }

    private static func identity(_ name: String = "2. Hardness 025",
                                 collection: String? = nil,
                                 isInternal: Bool = false) -> EngineSession.ResourceIdentity {
        EngineSession.ResourceIdentity(name: name, collection: collection, isInternal: isInternal)
    }

    private static func fullSettings() -> PaintToolPreset.Settings {
        PaintToolPreset.Settings(size: 24.5, opacity: 0.8, pressureSize: false,
                                 hardness: 0.25, rate: 33, flow: 44, exposure: 66,
                                 tones: .shadows, antiErase: true)
    }

    // MARK: Capture

    /// Capture copies EVERY stable brush setting and the resource identity;
    /// the transient clone source rides along on the read brush but is not
    /// part of the captured value.
    func testCaptureCopiesEveryStableSettingAndTheResourceIdentity() throws {
        try withDefaults { defaults in
            let state = makeState(defaults)
            state.select(.dodge)
            state.setBrushResource(Self.identity(), for: .dodge)
            state.update(.dodge) { brush in
                brush.size = 24.5
                brush.opacity = 0.8
                brush.pressureSize = false
                brush.hardness = 0.25
                brush.rate = 33
                brush.flow = 44
                brush.exposure = 66
                brush.tones = .shadows
                brush.antiErase = true
            }
            state.cloneSource = EngineSession.Brush.Source(drawable: 9, x: 1.5, y: 2.5)
            let brush = state.brush(for: .dodge)
            XCTAssertEqual(brush.source, state.cloneSource,
                           "the read brush carries the transient source point")
            XCTAssertEqual(PaintToolPresetControls.captureSettings(from: brush), Self.fullSettings())
            let resource = try XCTUnwrap(PaintToolPresetControls.captureBrushResource(from: brush))
            XCTAssertEqual(resource.identity, Self.identity())
            XCTAssertEqual(resource.resourceKind, .brush)
        }
    }

    /// The captured settings encode to exactly the stable keys — never the
    /// clone source, a drawable id, a session handle or the derived color.
    func testCapturedSettingsPersistNoTransientOrDerivedField() throws {
        try withDefaults { defaults in
            let state = makeState(defaults)
            state.select(.clone)
            state.update(.clone) { $0.hardness = 0.4; $0.rate = 22; $0.flow = 33; $0.exposure = 44 }
            state.cloneSource = EngineSession.Brush.Source(drawable: 3, x: 4, y: 5)
            state.setBrushResource(Self.identity(), for: .clone)
            state.foreground = .red
            let brush = state.brush(for: .clone)
            let data = try JSONEncoder().encode(PaintToolPresetControls.captureSettings(from: brush))
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(Set((try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])).keys),
                           ["size", "opacity", "pressureSize", "hardness", "rate", "flow",
                            "exposure", "tones", "antiErase"])
            for forbidden in ["source", "drawable", "resourceId", "red", "green", "blue", "tool"] {
                XCTAssertFalse(json.contains("\"\(forbidden)\""), "the captured settings persist no \(forbidden)")
            }
        }
    }

    /// The foreground color is captured only when deliberately included, as
    /// sRGB primitive RGB components.
    func testCaptureForegroundOnlyWhenDeliberatelyIncluded() throws {
        try withDefaults { defaults in
            let state = makeState(defaults)
            state.foreground = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
            XCTAssertNil(PaintToolPresetControls.captureForeground(state.foreground, include: false),
                         "an unchecked deliberate checkbox captures no color at all")
            let color = try XCTUnwrap(PaintToolPresetControls.captureForeground(state.foreground, include: true))
            XCTAssertEqual(color.red, 0.25, accuracy: 1e-6)
            XCTAssertEqual(color.green, 0.5, accuracy: 1e-6)
            XCTAssertEqual(color.blue, 0.75, accuracy: 1e-6)
        }
    }

    // MARK: Apply

    /// Applying selects the preset's tool, copies every stable field and the
    /// resource identity, and persists the identity through the brushStore
    /// path so a fresh ToolState restores it. Without a carried color the
    /// foreground is untouched.
    func testApplySelectsToolCopiesEveryFieldAndPersistsIdentity() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            let preset = try store.create(tool: .dodge, name: "Dodge shadows",
                                          settings: Self.fullSettings(),
                                          brushResource: PaintToolPreset.BrushResource(Self.identity()),
                                          foregroundColor: nil)
            state.select(.eraser)
            state.setBrushResource(Self.identity("2. Block 01"), for: .eraser)
            state.update(.eraser) { $0.size = 77; $0.opacity = 0.1 }
            state.foreground = .red
            let foregroundBefore = state.foreground

            PaintToolPresetControls.apply(preset, to: state)

            XCTAssertEqual(state.current, .dodge, "apply selects the preset's tool")
            let brush = state.brush(for: .dodge)
            XCTAssertEqual(brush.size, 24.5)
            XCTAssertEqual(brush.opacity, 0.8)
            XCTAssertEqual(brush.pressureSize, false)
            XCTAssertEqual(brush.hardness, 0.25)
            XCTAssertEqual(brush.rate, 33)
            XCTAssertEqual(brush.flow, 44)
            XCTAssertEqual(brush.exposure, 66)
            XCTAssertEqual(brush.tones, .shadows)
            XCTAssertEqual(brush.antiErase, true)
            XCTAssertEqual(brush.resource, Self.identity())
            XCTAssertEqual(state.brushStore.identity(for: .dodge), Self.identity(),
                           "the resource choice persists through the existing brushStore path")
            XCTAssertEqual(makeState(defaults).brush(for: .dodge).resource, Self.identity(),
                           "a fresh ToolState over the same store restores the persisted identity")
            XCTAssertEqual(state.foreground, foregroundBefore,
                           "a preset without an explicit color never changes the foreground")
        }
    }

    /// A preset with no resource applies nil through setBrushResource: the
    /// native Default brush, persisted as no stored identity.
    func testApplyWithNilResourceResetsToTheDefaultBrush() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            let preset = try store.create(tool: .paintbrush, name: "Plain", settings: Self.fullSettings())
            state.setBrushResource(Self.identity(), for: .paintbrush)
            XCTAssertNotNil(state.brush(for: .paintbrush).resource)

            PaintToolPresetControls.apply(preset, to: state)

            XCTAssertNil(state.brush(for: .paintbrush).resource)
            XCTAssertNil(state.brushStore.identity(for: .paintbrush),
                         "nil resets to the Default through the brushStore path")
        }
    }

    /// A preset carrying an explicit color changes the global foreground to
    /// its sRGB components; a preset without one leaves it alone.
    func testApplyChangesForegroundOnlyWhenPresetCarriesAnExplicitColor() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            let withColor = try store.create(tool: .paintbrush, name: "Colored",
                                             settings: Self.fullSettings(),
                                             foregroundColor: PaintToolPreset.SRGBColor(red: 0.25, green: 0.5, blue: 0.75))
            let withoutColor = try store.create(tool: .pencil, name: "Plain", settings: Self.fullSettings())

            PaintToolPresetControls.apply(withColor, to: state)
            let applied = try XCTUnwrap(state.foreground.usingColorSpace(.sRGB))
            XCTAssertEqual(Double(applied.redComponent), 0.25, accuracy: 1e-6)
            XCTAssertEqual(Double(applied.greenComponent), 0.5, accuracy: 1e-6)
            XCTAssertEqual(Double(applied.blueComponent), 0.75, accuracy: 1e-6)

            let carried = state.foreground
            PaintToolPresetControls.apply(withoutColor, to: state)
            XCTAssertEqual(state.current, .pencil)
            XCTAssertEqual(state.foreground, carried,
                           "applying a preset without a color leaves the foreground unchanged")
        }
    }

    /// The current cloneSource survives an apply exactly; it is never written
    /// by the apply path, and the read brush still derives it.
    func testApplyPreservesTheCurrentCloneSourceExactly() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            let preset = try store.create(tool: .clone, name: "Clone", settings: Self.fullSettings())
            let source = EngineSession.Brush.Source(drawable: 42, x: 5, y: 6)
            state.cloneSource = source

            PaintToolPresetControls.apply(preset, to: state)

            XCTAssertEqual(state.cloneSource, source,
                           "cloneSource is preserved exactly; a preset never restores a source point")
            XCTAssertEqual(state.brush(for: .clone).source, source,
                           "the read brush still derives the preserved source")
        }
    }

    /// A brush captured before Apply is a value: Apply cannot mutate it.
    func testApplyLeavesAnAlreadyCapturedBrushUnchanged() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            state.select(.paintbrush)
            state.update(.paintbrush) { $0.size = 9; $0.opacity = 0.5 }
            state.setBrushResource(Self.identity(), for: .paintbrush)
            let snapshot = state.brush(for: .paintbrush)
            let copy = snapshot
            let preset = try store.create(tool: .eraser, name: "Other", settings: Self.fullSettings())

            PaintToolPresetControls.apply(preset, to: state)

            XCTAssertEqual(snapshot, copy, "the already-captured brush value is unchanged after Apply")
            XCTAssertEqual(snapshot.size, 9)
            XCTAssertEqual(snapshot.opacity, 0.5)
            XCTAssertEqual(snapshot.resource, Self.identity())
        }
    }

    // MARK: Selection by UUID

    /// The selection helper follows the UUID across reloads and reorders, and
    /// a deleted UUID has no row — never a first-row fallback.
    func testSelectionIndexFollowsTheUUIDNotTheRow() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let a = try store.create(tool: .paintbrush, name: "A", settings: Self.fullSettings())
            let b = try store.create(tool: .paintbrush, name: "B", settings: Self.fullSettings())
            _ = try store.create(tool: .paintbrush, name: "C", settings: Self.fullSettings())
            XCTAssertEqual(PaintToolPresetControls.index(of: b.id, in: try store.load()), 1)
            try store.delete(id: a.id)
            let reloaded = try store.load()
            XCTAssertEqual(PaintToolPresetControls.index(of: b.id, in: reloaded), 0)
            XCTAssertNil(PaintToolPresetControls.index(of: a.id, in: reloaded))
        }
    }

    // MARK: Store errors throw and never rewrite the stored bytes

    func testStoreFailuresThrowAndLeaveTheStoredBytesUntouched() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .paintbrush, name: "One", settings: Self.fullSettings())
            let bytes = store.storedData
            XCTAssertThrowsError(try store.create(tool: .paintbrush, name: "One", settings: Self.fullSettings())) { error in
                XCTAssertEqual(error as? PaintToolPresetError, .duplicateName("One", tool: .paintbrush))
            }
            let unknown = UUID()
            XCTAssertThrowsError(try store.rename(id: unknown, to: "X")) { error in
                guard case .unknownPreset(let id) = error as? PaintToolPresetError else {
                    return XCTFail("expected unknownPreset, got \(error)")
                }
                XCTAssertEqual(id, unknown)
            }
            XCTAssertThrowsError(try store.delete(id: unknown)) { error in
                guard case .unknownPreset = error as? PaintToolPresetError else {
                    return XCTFail("expected unknownPreset, got \(error)")
                }
            }
            XCTAssertEqual(store.storedData, bytes, "failures never rewrite the stored document")
            XCTAssertEqual(try store.load().count, 1)
        }
    }

    // MARK: Panel controller: UUID selection and inline errors

    @MainActor
    func testPanelKeepsSelectionByUUIDAndShowsStoreErrorsInline() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            state.select(.paintbrush)
            let panel = PaintToolPresetPanelController(toolState: state, store: store)
            panel.open()
            defer { panel.closePanel(nil) }

            panel.saveCurrent(name: "First", includeForeground: false)
            let first = try XCTUnwrap(try store.load().first)
            XCTAssertEqual(panel.rows.count, 1)
            XCTAssertEqual(panel.selectedPresetID, first.id, "the new preset is selected by UUID")

            // A duplicate name fails inline and changes neither rows nor bytes.
            let bytes = store.storedData
            panel.saveCurrent(name: "  First  ", includeForeground: false)
            XCTAssertNotNil(panel.lastError)
            XCTAssertTrue(panel.lastError?.contains("already has a preset named") == true,
                          "the actionable store error is shown inline: \(panel.lastError ?? "nil")")
            XCTAssertEqual(panel.rows.count, 1)
            XCTAssertEqual(store.storedData, bytes, "a failed save never rewrites the stored document")
            XCTAssertEqual(panel.selectedPresetID, first.id, "the selection survives the failed save")

            // Rename keeps the UUID; the selection is preserved by UUID.
            panel.renameSelected(to: "Renamed")
            XCTAssertEqual(try store.load().first?.name, "Renamed")
            XCTAssertEqual(try store.load().first?.id, first.id)
            XCTAssertEqual(panel.selectedPresetID, first.id)

            // A second preset with distinctive settings; deleting the selected
            // one clears the selection instead of substituting the first row.
            state.update(.paintbrush) { $0.size = 24.5; $0.opacity = 0.8 }
            panel.saveCurrent(name: "Second", includeForeground: false)
            XCTAssertEqual(panel.rows.count, 2)
            let second = try XCTUnwrap(try store.load().last)
            XCTAssertEqual(second.settings.size, 24.5)
            panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertEqual(panel.selectedPresetID, first.id)
            panel.deleteSelected()
            XCTAssertNil(panel.selectedPresetID, "a deleted UUID is not replaced by another row")
            XCTAssertEqual(panel.rows.count, 1)
            XCTAssertEqual(panel.rows.first?.id, second.id)

            // Apply through the panel switches the tool and copies the stored
            // snapshot, not the other tool's live settings.
            panel.showsAllTools = true
            panel.reload()
            state.select(.eraser)
            state.update(.eraser) { $0.size = 77 }
            panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertEqual(panel.selectedPresetID, second.id)
            panel.applySelected()
            XCTAssertEqual(state.current, .paintbrush)
            XCTAssertEqual(state.brush(for: .paintbrush).size, 24.5)
            XCTAssertEqual(state.brush(for: .paintbrush).opacity, 0.8,
                           "apply copies the stored snapshot, not the eraser's live settings")
        }
    }

    /// The panel's All-tools filter is explicit: unchecked it lists only the
    /// current paint tool's presets, checked it lists every tool's.
    @MainActor
    func testPanelAllToolsFilterIsExplicitAndTransparent() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let state = makeState(defaults)
            _ = try store.create(tool: .paintbrush, name: "Brush preset", settings: Self.fullSettings())
            _ = try store.create(tool: .eraser, name: "Eraser preset", settings: Self.fullSettings())
            state.select(.paintbrush)
            let panel = PaintToolPresetPanelController(toolState: state, store: store)
            panel.open()
            defer { panel.closePanel(nil) }

            XCTAssertEqual(panel.rows.map(\.name), ["Brush preset"],
                           "by default only the current paint tool's presets are listed")
            panel.showsAllTools = true
            panel.reload()
            XCTAssertEqual(panel.rows.count, 2, "the explicit All-tools filter shows every tool's presets")
            state.select(.eraser)
            panel.showsAllTools = false
            panel.reload()
            XCTAssertEqual(panel.rows.map(\.name), ["Eraser preset"],
                           "switching the tool re-filters to the new current tool")
        }
    }
}
