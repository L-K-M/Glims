import AppKit
import XCTest
@testable import GlimsKit

/// Pure checks for the brush chooser's model and its persistence: the
/// per-tool identity encode/restore (never a session handle), the in-memory
/// search, and the captured-tool / cancel / missing semantics. No engine,
/// no AppKit windows.
final class BrushChooserTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.brushchooser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static func identity(_ name: String) -> EngineSession.ResourceIdentity {
        EngineSession.ResourceIdentity(name: name, collection: nil, isInternal: false)
    }

    private static func row(_ id: UInt64, _ name: String) -> BrushRow {
        BrushRow(id: id, name: name, identity: identity(name))
    }

    // MARK: Persistence

    func testIdentitiesPersistPerToolAcrossInstances() {
        withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            XCTAssertNil(store.identity(for: .paintbrush))
            store.set(Self.identity("2. Hardness 025"), for: .paintbrush)
            store.set(Self.identity("2. Block 01"), for: .eraser)
            let reopened = BrushSelectionStore(defaults: defaults)
            XCTAssertEqual(reopened.identity(for: .paintbrush), Self.identity("2. Hardness 025"))
            XCTAssertEqual(reopened.identity(for: .eraser), Self.identity("2. Block 01"))
            XCTAssertNil(reopened.identity(for: .pencil), "an unset tool stays the native default")
        }
    }

    func testResetToNativeDefaultRemovesTheStoredIdentity() {
        withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            store.set(Self.identity("2. Hardness 025"), for: .paintbrush)
            store.set(nil, for: .paintbrush)
            XCTAssertNil(store.identity(for: .paintbrush))
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
            let json = String(decoding: defaults.data(forKey: BrushSelectionStore.selectionsKey) ?? Data(), as: UTF8.self)
            XCTAssertFalse(json.contains("paintbrush"), "a nil choice is removed, not stored as null")
        }
    }

    /// The encoded form carries only identities keyed by tool — never a
    /// session ResourceID handle, which is local to the running engine.
    func testEncodingStoresIdentitiesNeverSessionHandles() throws {
        try withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            store.set(EngineSession.ResourceIdentity(name: "Round", collection: "Brushes", isInternal: true),
                      for: .paintbrush)
            let data = try XCTUnwrap(defaults.data(forKey: BrushSelectionStore.selectionsKey))
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(json.contains("\"paintbrush\""))
            XCTAssertTrue(json.contains("\"name\":\"Round\""))
            XCTAssertTrue(json.contains("\"collection\":\"Brushes\""))
            XCTAssertTrue(json.contains("\"isInternal\":true"))
            XCTAssertFalse(json.contains("\"id\""), "no numeric session handle is persisted")
            let decoded = try JSONDecoder().decode([String: EngineSession.ResourceIdentity].self, from: data)
            XCTAssertEqual(decoded["paintbrush"],
                           EngineSession.ResourceIdentity(name: "Round", collection: "Brushes", isInternal: true))
        }
    }

    func testInvalidStoredDataReadsAsEmpty() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: BrushSelectionStore.selectionsKey)
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
            defaults.set(["paintbrush": 42], forKey: BrushSelectionStore.selectionsKey)
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
        }
    }

    // MARK: Search

    func testSearchFiltersInMemoryCaseInsensitively() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        model.deliver(generation: model.generation, rows: [
            Self.row(1, "2. Hardness 025"),
            Self.row(2, "2. Block 01"),
            Self.row(3, "1. Pixel"),
        ], thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(model.rows(matching: "").count, 3)
        XCTAssertEqual(model.rows(matching: "  ").count, 3)
        XCTAssertEqual(model.rows(matching: "hardness").map(\.name), ["2. Hardness 025"])
        XCTAssertEqual(model.rows(matching: "2.").count, 2)
        XCTAssertEqual(model.rows(matching: "no such brush"), [])
    }

    // MARK: Captured tool, cancel, missing

    @MainActor
    func testTableRowsHaveVisibleNamesAndThumbnails() throws {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 0, 0, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        model.deliver(generation: model.generation, rows: [Self.row(7, "Stock Brush")],
                      thumbnails: [7: image], resolvedCurrent: nil, error: nil)
        let picker = BrushChooserPanel(document: nil, model: model)
        defer { picker.dismiss() }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let content = try XCTUnwrap(picker.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(findTable(content))
        XCTAssertEqual(table.numberOfRows, 2)
        let defaultCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let brushCell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(defaultCell.textField?.stringValue, "Default")
        XCTAssertEqual(brushCell.textField?.stringValue, "Stock Brush")
        XCTAssertNotNil(brushCell.imageView?.image, "the native brush preview must be visible in its row")
    }

    func testStaleGenerationDeliveryChangesNothing() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        model.invalidate()
        let applied = model.deliver(generation: model.generation - 1, rows: [Self.row(1, "A")],
                                    thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertFalse(applied)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.state, .loading, "a late native result cannot restore a stale view")
    }

    func testDeliverSelectsTheCurrentIdentityOrMarksItMissing() {
        let current = Self.identity("2. Hardness 025")
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        model.deliver(generation: model.generation, rows: [Self.row(7, "2. Hardness 025")],
                      thumbnails: [:], resolvedCurrent: 7, error: nil)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.selection, .resource(7))
        XCTAssertNil(model.missingIdentity)
        XCTAssertEqual(model.pendingIdentity(), current)

        let missing = BrushChooserModel(capturedTool: .pencil, currentIdentity: Self.identity("Gone"))
        missing.deliver(generation: missing.generation, rows: [Self.row(1, "Other")],
                        thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(missing.missingIdentity, Self.identity("Gone"),
                       "a persisted identity that no longer resolves is shown as missing")
        XCTAssertEqual(missing.selection, .none)
        XCTAssertEqual(missing.pendingIdentity(), Self.identity("Gone"),
                       "missing is never silently replaced by the default")
    }

    func testPendingIdentityCoversDefaultRowAndNoSelection() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: Self.identity("A"))
        model.select(.nativeDefault)
        XCTAssertNil(model.pendingIdentity(), "the Default row applies the native default (nil)")
        model.select(.none)
        XCTAssertEqual(model.pendingIdentity(), Self.identity("A"), "no highlight keeps the current choice")
    }

    @MainActor
    func testApplyWritesOnlyTheCapturedToolAndCancelPreservesThePreviousChoice() {
        withDefaults { defaults in
            let state = ToolState(brushStore: BrushSelectionStore(defaults: defaults))
            state.select(.paintbrush)
            let model = BrushChooserModel(capturedTool: state.current, currentIdentity: nil)
            model.deliver(generation: model.generation, rows: [Self.row(11, "Soft"), Self.row(12, "Block")],
                          thumbnails: [:], resolvedCurrent: nil, error: nil)
            model.select(.resource(11))
            // Switching tools while the chooser is open must not retarget.
            state.select(.eraser)
            XCTAssertEqual(model.capturedTool, .paintbrush)
            state.setBrushResource(model.pendingIdentity(), for: model.capturedTool)
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Soft"))
            XCTAssertNil(state.brush(for: .eraser).resource, "the other tool's brush is untouched")

            // Cancel: a second chooser picks another row but applies nothing.
            let cancelled = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: Self.identity("Soft"))
            cancelled.deliver(generation: cancelled.generation, rows: [Self.row(12, "Block")],
                              thumbnails: [:], resolvedCurrent: nil, error: nil)
            cancelled.select(.resource(12))
            XCTAssertEqual(cancelled.pendingIdentity(), Self.identity("Block"), "it would have applied Block")
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Soft"),
                           "cancel preserves the previous selection")

            // Applying then persists the identity, restored by a fresh state.
            state.setBrushResource(cancelled.pendingIdentity(), for: cancelled.capturedTool)
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Block"))
            let restored = ToolState(brushStore: BrushSelectionStore(defaults: defaults))
            XCTAssertEqual(restored.brush(for: .paintbrush).resource, Self.identity("Block"),
                           "the persisted identity restores into settings after a restart")
            XCTAssertNil(restored.brush(for: .eraser).resource)

            // Reset to the native Default persists nil.
            state.setBrushResource(nil, for: .paintbrush)
            XCTAssertNil(state.brush(for: .paintbrush).resource)
            XCTAssertNil(ToolState(brushStore: BrushSelectionStore(defaults: defaults)).brush(for: .paintbrush).resource)
        }
    }
}
