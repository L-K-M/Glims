import AppKit
import XCTest
@testable import GlimsKit

final class ResourceReferenceMigrationTests: XCTestCase {
    private let old = EngineSession.ResourceIdentity(name: "Original", collection: "file:///owned", isInternal: false)
    private let new = EngineSession.ResourceIdentity(name: "Renamed Ω", collection: "file:///owned", isInternal: false)
    private let other = EngineSession.ResourceIdentity(name: "Original", collection: "", isInternal: false)
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
    private func settings(_ size: Double) -> PaintToolPreset.Settings {
        .init(size: size, opacity: 0.75, pressureSize: true, hardness: 0.5,
              rate: 30, flow: 20, exposure: 40, tones: .midtones, antiErase: false)
    }
    func testNormalizationOnlyRenameUsesNativeByteIdentity() throws {
        let composed = EngineSession.ResourceIdentity(name: "é", collection: "file:///owned", isInternal: false)
        let decomposed = EngineSession.ResourceIdentity(name: "e\u{301}", collection: "file:///owned", isInternal: false)
        XCTAssertEqual(composed.name, decomposed.name)
        XCTAssertNotEqual(composed, decomposed)
        try withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            store.set(composed, for: .paintbrush)
            XCTAssertEqual(try store.migrateIdentity(from: composed, to: decomposed), 1)
            let saved = try XCTUnwrap(store.identity(for: .paintbrush))
            XCTAssertEqual(Array(saved.name.utf8), Array(decomposed.name.utf8))
            XCTAssertNotEqual(saved, composed)
        }
    }
    func testPresetMigrationPreservesEveryOtherFieldAndOrder() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .paintbrush, name: "First", settings: settings(9),
                brushResource: .init(old), foregroundColor: .init(red: 0.25, green: 0.5, blue: 0.75))
            _ = try store.create(tool: .eraser, name: "Second", settings: settings(23), brushResource: .init(old))
            _ = try store.create(tool: .pencil, name: "Other collection", settings: settings(17), brushResource: .init(other))
            let before = try store.load()
            XCTAssertEqual(try store.migrateBrushResource(from: old, to: new), 2)
            let after = try store.load()
            XCTAssertEqual(after.map(\.id), before.map(\.id))
            for (left, right) in zip(before, after) {
                XCTAssertEqual(left.name, right.name); XCTAssertEqual(left.tool, right.tool)
                XCTAssertEqual(left.settings, right.settings); XCTAssertEqual(left.foregroundColor, right.foregroundColor)
                XCTAssertEqual(right.brushResource?.identity, left.brushResource?.identity == old ? new : left.brushResource?.identity)
            }
            let bytes = store.storedData
            XCTAssertEqual(try store.migrateBrushResource(from: old, to: new), 0)
            XCTAssertEqual(store.storedData, bytes)
            XCTAssertEqual(try store.migrateBrushResource(from: new, to: new), 0)
            XCTAssertEqual(store.storedData, bytes)
        }
    }
    func testCorruptAndFuturePresetsRemainByteIdentical() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            for bytes in [Data("{broken".utf8), Data("{\"schemaVersion\":999,\"presets\":[]}".utf8)] {
                defaults.set(bytes, forKey: PaintToolPresetStore.presetsKey)
                XCTAssertThrowsError(try store.migrateBrushResource(from: old, to: new))
                XCTAssertEqual(defaults.data(forKey: PaintToolPresetStore.presetsKey), bytes)
            }
        }
    }
    func testBrushMigrationIncludesUnshownToolsAndPreservesRawExtras() throws {
        try withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            let encoded = try JSONEncoder().encode(["paintbrush": old, "eraser": old, "future-tool": old, "pencil": other])
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: [String: Any]])
            object["paintbrush"]?["extra"] = "keep"
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: BrushSelectionStore.selectionsKey)
            XCTAssertEqual(try store.migrateIdentity(from: old, to: new), 3)
            XCTAssertEqual(store.all["future-tool"], new); XCTAssertEqual(store.identity(for: .pencil), other)
            let data = try XCTUnwrap(defaults.data(forKey: BrushSelectionStore.selectionsKey))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
            XCTAssertEqual(result["paintbrush"]?["extra"] as? String, "keep")
            XCTAssertEqual(try store.migrateIdentity(from: old, to: new), 0)
            XCTAssertEqual(defaults.data(forKey: BrushSelectionStore.selectionsKey), data)
        }
    }
    func testGradientAndPatternMigrationsKeepSettingsAndNewerChoices() throws {
        try withDefaults { defaults in
            let gradient = GradientToolStore(defaults: defaults), pattern = PatternFillStore(defaults: defaults)
            var prefs = GradientToolPreferences(identity: old)
            prefs.shape = .radial; prefs.reverse = true; prefs.opacity = 0.375
            gradient.set(prefs); pattern.set(old)
            XCTAssertEqual(try gradient.migrateIdentity(from: old, to: new), 1)
            prefs.identity = new; XCTAssertEqual(gradient.preferences, prefs)
            XCTAssertEqual(try pattern.migrateIdentity(from: old, to: new), 1); XCTAssertEqual(pattern.identity, new)
            gradient.setIdentity(other); pattern.set(other)
            let g = defaults.data(forKey: GradientToolStore.preferencesKey), p = defaults.data(forKey: PatternFillStore.selectionKey)
            XCTAssertEqual(try gradient.migrateIdentity(from: old, to: new), 0)
            XCTAssertEqual(try pattern.migrateIdentity(from: old, to: new), 0)
            XCTAssertEqual(defaults.data(forKey: GradientToolStore.preferencesKey), g)
            XCTAssertEqual(defaults.data(forKey: PatternFillStore.selectionKey), p)
        }
    }
    func testMalformedChoiceDomainsAreNeverRewritten() throws {
        try withDefaults { defaults in
            let invalid = Data("{\"name\":\"\",\"isInternal\":false}".utf8)
            defaults.set(invalid, forKey: PatternFillStore.selectionKey)
            XCTAssertThrowsError(try PatternFillStore(defaults: defaults).migrateIdentity(from: old, to: new))
            XCTAssertEqual(defaults.data(forKey: PatternFillStore.selectionKey), invalid)
            let brush = Data("{\"paintbrush\":{\"name\":\"\",\"isInternal\":false}}".utf8)
            defaults.set(brush, forKey: BrushSelectionStore.selectionsKey)
            XCTAssertThrowsError(try BrushSelectionStore(defaults: defaults).migrateIdentity(from: old, to: new))
            XCTAssertEqual(defaults.data(forKey: BrushSelectionStore.selectionsKey), brush)
            var prefs = GradientToolPreferences(identity: old); prefs.opacity = 2
            let gradient = try JSONEncoder().encode(prefs)
            defaults.set(gradient, forKey: GradientToolStore.preferencesKey)
            XCTAssertThrowsError(try GradientToolStore(defaults: defaults).migrateIdentity(from: old, to: new))
            XCTAssertEqual(defaults.data(forKey: GradientToolStore.preferencesKey), gradient)
        }
    }
    @MainActor func testLiveBrushCacheFollowsMigrationButKeepsChangedChoice() throws {
        try withDefaults { defaults in
            let brushes = BrushSelectionStore(defaults: defaults), gradients = GradientToolStore(defaults: defaults)
            let tools = ToolState(brushStore: brushes, gradientStore: gradients)
            tools.setBrushResource(old, for: .paintbrush); tools.setBrushResource(old, for: .eraser)
            brushes.set(other, for: .eraser)
            try tools.migrateResourceIdentity(kind: .brush, from: old, to: new)
            XCTAssertEqual(tools.brush(for: .paintbrush).resource, new)
            XCTAssertEqual(tools.brush(for: .eraser).resource, other)
            XCTAssertEqual(brushes.identity(for: .eraser), other)
        }
    }
}
