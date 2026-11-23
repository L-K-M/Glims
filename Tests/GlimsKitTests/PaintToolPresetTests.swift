import Foundation
import XCTest
@testable import GlimsKit

/// Pure checks for the paint tool preset value model and its persistent
/// CRUD store: encoded JSON is inspected explicitly, malformed and future
/// documents are seeded by hand, and every failure must leave the stored
/// bytes untouched. No engine, no AppKit windows.
final class PaintToolPresetTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = ScratchDefaults.suiteName("tests-painttoolpresets")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func assertPresetError(_ body: () throws -> Void,
                                   _ check: (PaintToolPresetError) -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected a PaintToolPresetError", file: file, line: line)
        } catch let error as PaintToolPresetError {
            XCTAssertTrue(check(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("expected a PaintToolPresetError, got \(error)", file: file, line: line)
        }
    }

    private static func settings(size: Double = 12, opacity: Double = 1, pressureSize: Bool = true,
                                 hardness: Double? = 0.5, rate: Double? = 50, flow: Double? = 10,
                                 exposure: Double? = 50,
                                 tones: PaintToolPreset.ToneRange = .midtones,
                                 antiErase: Bool = false,
                                 paintMode: String = EngineSession.PaintModes.normal,
                                 spacing: Double? = nil,
                                 fade: PaintToolPreset.Fade? = nil) -> PaintToolPreset.Settings {
        PaintToolPreset.Settings(size: size, opacity: opacity, pressureSize: pressureSize,
                                 hardness: hardness, rate: rate, flow: flow, exposure: exposure,
                                 tones: tones, antiErase: antiErase,
                                 paintMode: paintMode, spacing: spacing, fade: fade)
    }

    /// A real non-normal blend mode nick for the option tests.
    private static var paintMode: String {
        EngineSession.PaintModes.all.first { $0 != EngineSession.PaintModes.normal }!
    }

    private static func brushResource(_ name: String = "2. Hardness 025",
                                      collection: String? = nil,
                                      isInternal: Bool = false) -> PaintToolPreset.BrushResource {
        PaintToolPreset.BrushResource(EngineSession.ResourceIdentity(name: name,
                                                                      collection: collection,
                                                                      isInternal: isInternal))
    }

    private static func color(red: Double = 0.25, green: Double = 0.5,
                              blue: Double = 0.75) -> PaintToolPreset.SRGBColor {
        PaintToolPreset.SRGBColor(red: red, green: green, blue: blue)
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private static func forbiddenKeys(in value: Any) -> [String] {
        let forbidden: Set<String> = ["source", "cloneSource", "drawable", "sourceDrawable",
                                      "sourceX", "sourceY", "resourceId", "sessionId", "stroke"]
        var found: [String] = []
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if forbidden.contains(key) { found.append(key) }
                found += forbiddenKeys(in: child)
            }
        } else if let array = value as? [Any] {
            for child in array { found += forbiddenKeys(in: child) }
        }
        return found
    }

    // MARK: Encoded form

    func testFullPresetRoundTripsThroughStoredJSON() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let created = try store.create(tool: .dodge, name: "Dodge shadows",
                                           settings: Self.settings(size: 24.5, opacity: 0.8,
                                                                   pressureSize: false, hardness: 0.25,
                                                                   rate: 33, flow: 44, exposure: 66,
                                                                   tones: .shadows, antiErase: true),
                                           brushResource: Self.brushResource(),
                                           foregroundColor: Self.color())
            let data = try XCTUnwrap(store.storedData)
            let doc = try XCTUnwrap(try jsonObject(data) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 1)
            let presets = try XCTUnwrap(doc["presets"] as? [[String: Any]])
            XCTAssertEqual(presets.count, 1)
            let preset = presets[0]
            XCTAssertEqual(Set(preset.keys),
                           ["id", "tool", "name", "settings", "brushResource", "foregroundColor"])
            XCTAssertEqual(preset["id"] as? String, created.id.uuidString)
            XCTAssertEqual(preset["tool"] as? String, "dodge",
                           "the tool persists as its own tag string, not a raw enum number")
            XCTAssertEqual(preset["name"] as? String, "Dodge shadows")
            let settings = try XCTUnwrap(preset["settings"] as? [String: Any])
            XCTAssertEqual(Set(settings.keys),
                           ["size", "opacity", "pressureSize", "hardness", "rate", "flow",
                            "exposure", "tones", "antiErase"])
            XCTAssertEqual(settings["size"] as? Double, 24.5)
            XCTAssertEqual(settings["opacity"] as? Double, 0.8)
            XCTAssertEqual(settings["pressureSize"] as? Bool, false)
            XCTAssertEqual(settings["hardness"] as? Double, 0.25)
            XCTAssertEqual(settings["rate"] as? Double, 33)
            XCTAssertEqual(settings["flow"] as? Double, 44)
            XCTAssertEqual(settings["exposure"] as? Double, 66)
            XCTAssertEqual(settings["tones"] as? String, "shadows",
                           "the tonal range persists as its own tag, not a raw number")
            XCTAssertEqual(settings["antiErase"] as? Bool, true)
            let resource = try XCTUnwrap(preset["brushResource"] as? [String: Any])
            XCTAssertEqual(Set(resource.keys), ["kind", "identity"])
            XCTAssertEqual(resource["kind"] as? String, "brush")
            let identity = try XCTUnwrap(resource["identity"] as? [String: Any])
            XCTAssertEqual(Set(identity.keys), ["name", "isInternal"],
                           "a nil collection persists as no key; no handle crosses into the JSON")
            XCTAssertEqual(identity["name"] as? String, "2. Hardness 025")
            XCTAssertEqual(identity["isInternal"] as? Bool, false)
            let color = try XCTUnwrap(preset["foregroundColor"] as? [String: Any])
            XCTAssertEqual(Set(color.keys), ["red", "green", "blue"])
            XCTAssertEqual(color["red"] as? Double, 0.25)
            XCTAssertEqual(color["green"] as? Double, 0.5)
            XCTAssertEqual(color["blue"] as? Double, 0.75)

            let reopened = PaintToolPresetStore(defaults: defaults)
            XCTAssertEqual(try reopened.load(), [created])
        }
    }

    func testOptionalFieldsPersistAsAbsentKeys() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let created = try store.create(tool: .paintbrush, name: "Plain",
                                           settings: Self.settings(hardness: nil, rate: nil,
                                                                   flow: nil, exposure: nil))
            let doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            let preset = try XCTUnwrap(try XCTUnwrap(doc["presets"] as? [[String: Any]]).first)
            XCTAssertEqual(Set(preset.keys), ["id", "tool", "name", "settings"],
                           "no brushResource or foregroundColor key when nil")
            let settings = try XCTUnwrap(preset["settings"] as? [String: Any])
            XCTAssertEqual(Set(settings.keys),
                           ["size", "opacity", "pressureSize", "tones", "antiErase"],
                           "nil optionals persist as no key, like ResourceIdentity.collection")
            XCTAssertEqual(try PaintToolPresetStore(defaults: defaults).load(), [created])
            XCTAssertNil(created.settings.hardness)
            XCTAssertNil(created.brushResource)
            XCTAssertNil(created.foregroundColor)
        }
    }

    func testTransientFieldsAreNeverPersisted() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .clone, name: "Clone preset",
                                 settings: Self.settings(),
                                 brushResource: Self.brushResource(),
                                 foregroundColor: Self.color())
            let doc = try jsonObject(try XCTUnwrap(store.storedData))
            XCTAssertEqual(Self.forbiddenKeys(in: doc), [],
                           "no clone/heal source, drawable id, session handle or coordinates in the JSON")
        }
    }

    func testHandWrittenDocumentDecodesIndependently() throws {
        try withDefaults { defaults in
            let seed = Data(#"""
            {
                "schemaVersion": 1,
                "presets": [{
                    "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
                    "tool": "heal",
                    "name": "Healer",
                    "settings": {"size": 20, "opacity": 0.9, "pressureSize": false,
                                 "hardness": 0.1, "rate": null, "flow": 5, "exposure": null,
                                 "tones": "highlights", "antiErase": true},
                    "brushResource": {"kind": "brush",
                                      "identity": {"name": "1. Pixel", "collection": "", "isInternal": true}},
                    "foregroundColor": {"red": 1, "green": 0.5, "blue": 0}
                }]
            }
            """#.utf8)
            defaults.set(seed, forKey: PaintToolPresetStore.presetsKey)
            let store = PaintToolPresetStore(defaults: defaults)
            let loaded = try store.load()
            XCTAssertEqual(loaded.count, 1)
            let preset = try XCTUnwrap(loaded.first)
            XCTAssertEqual(preset.id, UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
            XCTAssertEqual(preset.tool, .heal)
            XCTAssertEqual(preset.name, "Healer")
            XCTAssertEqual(preset.settings.size, 20)
            XCTAssertEqual(preset.settings.opacity, 0.9)
            XCTAssertFalse(preset.settings.pressureSize)
            XCTAssertEqual(preset.settings.hardness, 0.1)
            XCTAssertNil(preset.settings.rate, "an explicit JSON null decodes to nil")
            XCTAssertEqual(preset.settings.flow, 5)
            XCTAssertNil(preset.settings.exposure)
            XCTAssertEqual(preset.settings.tones, .highlights)
            XCTAssertTrue(preset.settings.antiErase)
            XCTAssertEqual(preset.brushResource?.identity,
                           EngineSession.ResourceIdentity(name: "1. Pixel", collection: "", isInternal: true))
            XCTAssertEqual(preset.brushResource?.resourceKind, .brush)
            XCTAssertEqual(preset.foregroundColor, Self.color(red: 1, green: 0.5, blue: 0))

            // A rewrite re-encodes the same known fields.
            try store.rename(id: preset.id, to: "Healer 2")
            let doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            let rewritten = try XCTUnwrap(try XCTUnwrap(doc["presets"] as? [[String: Any]]).first)
            XCTAssertEqual(rewritten["name"] as? String, "Healer 2")
            XCTAssertEqual(rewritten["tool"] as? String, "heal")
            let identity = try XCTUnwrap(try XCTUnwrap(rewritten["brushResource"] as? [String: Any])["identity"] as? [String: Any])
            XCTAssertEqual(identity["collection"] as? String, "",
                           "an empty collection stays an empty string, not nil")
        }
    }

    // MARK: Paint options (schema 2)

    func testSchema2RoundTripsPaintModeSpacingAndFade() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let created = try store.create(tool: .airbrush, name: "Faded screen",
                                           settings: Self.settings(paintMode: Self.paintMode,
                                                                   spacing: 0.35,
                                                                   fade: PaintToolPreset.Fade(steps: 7, target: .background)))
            let doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 2)
            let presets = try XCTUnwrap(doc["presets"] as? [[String: Any]])
            let settings = try XCTUnwrap(presets[0]["settings"] as? [String: Any])
            XCTAssertEqual(settings["paintMode"] as? String, Self.paintMode)
            XCTAssertEqual(settings["spacing"] as? Double, 0.35)
            let storedFade = try XCTUnwrap(settings["fade"] as? [String: Any])
            XCTAssertEqual(Set(storedFade.keys), ["steps", "target"])
            XCTAssertEqual(storedFade["steps"] as? Int, 7)
            XCTAssertEqual(storedFade["target"] as? String, "background")
            XCTAssertTrue(created.settings.hasPaintOptions)
            XCTAssertEqual(try PaintToolPresetStore(defaults: defaults).load(), [created])
        }
    }

    func testDocumentWithoutPaintOptionsStaysSchema1() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .paintbrush, name: "Plain", settings: Self.settings())
            let doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 1)
            let presets = try XCTUnwrap(doc["presets"] as? [[String: Any]])
            let settings = try XCTUnwrap(presets[0]["settings"] as? [String: Any])
            for key in ["paintMode", "spacing", "fade"] {
                XCTAssertNil(settings[key], "\(key) stays absent for a preset without options")
            }
        }
    }

    func testAddingOrRemovingAPresetWithAnOptionChoosesTheSchemaVersion() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .paintbrush, name: "Plain", settings: Self.settings())
            var doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 1)

            let spaced = try store.create(tool: .pencil, name: "Spaced",
                                          settings: Self.settings(spacing: 0.2))
            doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 2,
                           "one preset with an option needs schema 2")

            try store.delete(id: spaced.id)
            doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            XCTAssertEqual(doc["schemaVersion"] as? Int, 1,
                           "the lowest expressible version is written")
        }
    }

    func testSchema1RejectsPaintOptionKeysAndKeepsBytes() throws {
        try withDefaults { defaults in
            let id = #""3F2504E0-4F89-41D3-9A0C-0305E82C3301""#
            let fields = #""size":10,"opacity":1,"pressureSize":true,"tones":"midtones","antiErase":false"#
            let extras: [(String, String)] = [
                ("paintMode", #""paintMode":"normal""#),
                ("spacing", #""spacing":0.5"#),
                ("fade", #""fade":{"steps":5,"target":"transparent"}"#),
            ]
            for (name, extra) in extras {
                let data = Data("{\"schemaVersion\":1,\"presets\":[{\"id\":\(id),\"tool\":\"paintbrush\","
                    + "\"name\":\"x\",\"settings\":{\(fields),\(extra)}}]}".utf8)
                defaults.set(data, forKey: PaintToolPresetStore.presetsKey)
                let store = PaintToolPresetStore(defaults: defaults)
                assertPresetError({ _ = try store.load() }) {
                    if case .malformed(let detail) = $0 { return detail.contains(name) }
                    return false
                }
                assertPresetError({ try store.create(tool: .paintbrush, name: "ok", settings: Self.settings()) }) {
                    _ in true
                }
                XCTAssertEqual(store.storedData, data, "\(name): the rejected bytes stay untouched")
            }
        }
    }

    func testPaintOptionValueValidation() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            assertPresetError({
                try store.create(tool: .paintbrush, name: "m",
                                 settings: Self.settings(paintMode: "bogus"))
            }) {
                if case .unknownPaintMode(let tag) = $0 { return tag == "bogus" }
                return false
            }
            for bad in [0.001, 11.0, -1.0, Double.nan, Double.infinity] {
                assertPresetError({
                    try store.create(tool: .paintbrush, name: "s\(bad)",
                                     settings: Self.settings(spacing: bad))
                }, fieldError("settings.spacing"))
            }
            for bad in [0, -1, 10_000] {
                assertPresetError({
                    try store.create(tool: .pencil, name: "f\(bad)",
                                     settings: Self.settings(fade: PaintToolPreset.Fade(steps: bad, target: .transparent)))
                }) {
                    if case .outOfRange(let field, _, _) = $0 { return field == "settings.fade.steps" }
                    return false
                }
            }
            // The boundaries are accepted.
            _ = try store.create(tool: .airbrush, name: "edges",
                                 settings: Self.settings(paintMode: Self.paintMode, spacing: 0.01,
                                                         fade: PaintToolPreset.Fade(steps: 9999, target: .transparent)))
            XCTAssertEqual(try store.load().count, 1)
        }
    }

    func testStoredPaintOptionTagsAndUnknownFieldsRejected() throws {
        try withDefaults { defaults in
            let id = #""3F2504E0-4F89-41D3-9A0C-0305E82C3301""#
            let fields = #""size":10,"opacity":1,"pressureSize":true,"tones":"midtones","antiErase":false"#
            let seeds: [(String, String, (PaintToolPresetError) -> Bool)] = [
                ("unknown fade target", "\"fade\":{\"steps\":5,\"target\":\"white\"}",
                 { if case .unknownFadeTarget(let tag) = $0 { return tag == "white" }; return false }),
                ("extra key inside fade", "\"fade\":{\"steps\":5,\"target\":\"transparent\",\"soften\":true}",
                 { if case .malformed = $0 { return true }; return false }),
                ("unknown paint mode", "\"paintMode\":\"bogus\"",
                 { if case .unknownPaintMode(let tag) = $0 { return tag == "bogus" }; return false }),
                ("spacing out of range", "\"spacing\":11",
                 { if case .outOfRange(let field, _, _) = $0 { return field == "settings.spacing" }; return false }),
            ]
            for (name, extra, check) in seeds {
                let data = Data("{\"schemaVersion\":2,\"presets\":[{\"id\":\(id),\"tool\":\"paintbrush\","
                    + "\"name\":\"x\",\"settings\":{\(fields),\(extra)}}]}".utf8)
                defaults.set(data, forKey: PaintToolPresetStore.presetsKey)
                let store = PaintToolPresetStore(defaults: defaults)
                assertPresetError({ _ = try store.load() }, check)
                assertPresetError({ try store.create(tool: .paintbrush, name: "ok", settings: Self.settings()) }) {
                    _ in true
                }
                XCTAssertEqual(store.storedData, data, "\(name): the rejected bytes stay untouched")
            }
        }
    }

    func testPaintOptionsRestrictedToTheirTools() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            XCTAssertThrowsError(try store.create(tool: .eraser, name: "mode",
                                                 settings: Self.settings(paintMode: Self.paintMode))) { error in
                guard let presetError = error as? PaintToolPresetError else {
                    return XCTFail("expected PaintToolPresetError, got \(error)")
                }
                XCTAssertEqual(presetError, PaintToolPresetError.optionNotForTool(option: "a blend mode", tool: .eraser))
                XCTAssertEqual(presetError.description, "The Eraser tool cannot keep a blend mode.")
            }
            XCTAssertThrowsError(try store.create(tool: .clone, name: "fade",
                                                 settings: Self.settings(fade: PaintToolPreset.Fade(steps: 5, target: .transparent)))) { error in
                guard let presetError = error as? PaintToolPresetError else {
                    return XCTFail("expected PaintToolPresetError, got \(error)")
                }
                XCTAssertEqual(presetError, PaintToolPresetError.optionNotForTool(option: "a fade", tool: .clone))
                XCTAssertEqual(presetError.description, "The Clone tool cannot keep a fade.")
            }
            // Spacing applies to every paint tool, and the mode and fade tools
            // accept their own options.
            _ = try store.create(tool: .eraser, name: "spacing", settings: Self.settings(spacing: 0.4))
            _ = try store.create(tool: .clone, name: "clone mode",
                                 settings: Self.settings(paintMode: Self.paintMode))
            _ = try store.create(tool: .airbrush, name: "brush fade",
                                 settings: Self.settings(fade: PaintToolPreset.Fade(steps: 1, target: .transparent)))
            XCTAssertEqual(try store.load().count, 3)
        }
    }

    func testFutureSchemaVersionMessageNamesTheReadRange() {
        withDefaults { defaults in
            let seed = Data(#"{"schemaVersion":3,"presets":[]}"#.utf8)
            defaults.set(seed, forKey: PaintToolPresetStore.presetsKey)
            let store = PaintToolPresetStore(defaults: defaults)
            XCTAssertThrowsError(try store.load()) { error in
                guard let presetError = error as? PaintToolPresetError else {
                    return XCTFail("expected PaintToolPresetError, got \(error)")
                }
                XCTAssertEqual(presetError, PaintToolPresetError.unsupportedSchemaVersion(found: 3, supported: 2))
                XCTAssertEqual(presetError.description,
                               "The stored paint tool presets use schema version 3; "
                                   + "this version reads schema versions 1 through 2. "
                                   + "The stored data was left untouched.")
            }
            XCTAssertEqual(store.storedData, seed, "the rejected bytes stay untouched")
        }
    }

    // MARK: Tool tags

    func testEveryPaintToolAcceptedAndEveryOtherToolRejected() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            for tool in ToolID.allCases where tool.paintTool != nil {
                let preset = try store.create(tool: tool, name: tool.rawValue, settings: Self.settings())
                XCTAssertEqual(preset.tool, tool)
                XCTAssertNotNil(tool.paintTool)
            }
            for tool in ToolID.allCases where tool.paintTool == nil {
                assertPresetError({ try store.create(tool: tool, name: "x", settings: Self.settings()) }) {
                    if case .nonPaintTool(let rejected) = $0 { return rejected == tool }
                    return false
                }
                assertPresetError({ _ = try store.presets(for: tool) }) {
                    if case .nonPaintTool = $0 { return true }
                    return false
                }
            }
            XCTAssertEqual(try store.load().count, ToolID.allCases.filter { $0.paintTool != nil }.count)
        }
    }

    func testUnknownToolTagRejected() {
        withDefaults { defaults in
            let seed = Data(#"{"schemaVersion":1,"presets":[{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","tool":"warp","name":"x","settings":{"size":10,"opacity":1,"pressureSize":true,"tones":"midtones","antiErase":false}}]}"#.utf8)
            defaults.set(seed, forKey: PaintToolPresetStore.presetsKey)
            let store = PaintToolPresetStore(defaults: defaults)
            assertPresetError({ _ = try store.load() }) {
                if case .unknownToolTag(let tag) = $0 { return tag == "warp" }
                return false
            }
            assertPresetError({ try store.create(tool: .paintbrush, name: "ok", settings: Self.settings()) }) {
                if case .unknownToolTag = $0 { return true }
                return false
            }
            XCTAssertEqual(store.storedData, seed, "a rejected mutation leaves the stored bytes untouched")
        }
    }

    // MARK: Numeric and field validation

    /// Matches an out-of-range or non-finite error for exactly `field`.
    private func fieldError(_ field: String) -> (PaintToolPresetError) -> Bool {
        { error in
            switch error {
            case .outOfRange(let f, _, _), .nonFinite(let f): return f == field
            default: return false
            }
        }
    }

    func testNumericLimitsEnforced() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            // Accepted boundaries (UI sliders 1...500 px and 0...100%, engine size > 0).
            _ = try store.create(tool: .paintbrush, name: "edges",
                                 settings: Self.settings(size: 10_000, opacity: 0, hardness: 0,
                                                         rate: 0, flow: 100, exposure: 100))
            _ = try store.create(tool: .pencil, name: "small", settings: Self.settings(size: 1, opacity: 1, hardness: 1))
            // Rejected sizes.
            for bad in [0.0, 0.5, -3.0, 10_000.5, .nan, .infinity] {
                assertPresetError({ try store.create(tool: .airbrush, name: "s\(bad)", settings: Self.settings(size: bad)) }) {
                    switch $0 {
                    case .sizeOutOfRange(let v): return v == bad && bad.isFinite
                    case .nonFinite: return !bad.isFinite
                    default: return false
                    }
                }
            }
            // Rejected opacity / hardness / rate / flow / exposure / color.
            for bad in [-0.01, 1.01, .nan] {
                assertPresetError({ try store.create(tool: .eraser, name: "o\(bad)", settings: Self.settings(opacity: bad)) },
                                  fieldError("settings.opacity"))
                assertPresetError({ try store.create(tool: .eraser, name: "h\(bad)", settings: Self.settings(hardness: bad)) },
                                  fieldError("settings.hardness"))
            }
            for bad in [-0.5, 100.5, .infinity] {
                assertPresetError({ try store.create(tool: .smudge, name: "r\(bad)", settings: Self.settings(rate: bad)) },
                                  fieldError("settings.rate"))
                assertPresetError({ try store.create(tool: .smudge, name: "f\(bad)", settings: Self.settings(flow: bad)) },
                                  fieldError("settings.flow"))
                assertPresetError({ try store.create(tool: .burn, name: "e\(bad)", settings: Self.settings(exposure: bad)) },
                                  fieldError("settings.exposure"))
            }
            assertPresetError({
                try store.create(tool: .paintbrush, name: "c", settings: Self.settings(),
                                 foregroundColor: Self.color(red: 1.2))
            }, fieldError("foregroundColor.red"))
            XCTAssertEqual(try store.load().count, 2, "every rejected create left the store untouched")
        }
    }

    func testResourceKindAndIdentityValidation() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            // An empty identity name is invalid.
            assertPresetError({
                try store.create(tool: .paintbrush, name: "r", settings: Self.settings(),
                                 brushResource: Self.brushResource(""))
            }) {
                if case .invalidResourceIdentity = $0 { return true }
                return false
            }
            // A NUL byte in the identity is invalid, as at resolve time.
            assertPresetError({
                try store.create(tool: .paintbrush, name: "r2", settings: Self.settings(),
                                 brushResource: Self.brushResource("bad\0name"))
            }) {
                if case .invalidResourceIdentity = $0 { return true }
                return false
            }
            // A valid reference persists and round-trips with its kind pinned to brush.
            let created = try store.create(tool: .paintbrush, name: "r3", settings: Self.settings(),
                                           brushResource: Self.brushResource("2. Block 01", collection: "My brushes"))
            XCTAssertEqual(created.brushResource?.kind, .brush)
            XCTAssertEqual(created.brushResource?.resourceKind, .brush)
            XCTAssertEqual(try PaintToolPresetStore(defaults: defaults).load().first?.brushResource?.identity.collection,
                           "My brushes")
        }
    }

    func testMalformedPersistedFieldsRejected() {
        withDefaults { defaults in
            let baseSettings = #"{"size":10,"opacity":1,"pressureSize":true,"tones":"midtones","antiErase":false}"#
            let id = #""3F2504E0-4F89-41D3-9A0C-0305E82C3301""#
            // Unknown tone tag.
            let badTone = Data(#"{"schemaVersion":1,"presets":[{"id":\#(id),"tool":"dodge","name":"x","settings":{"size":10,"opacity":1,"pressureSize":true,"tones":"ultra","antiErase":false}}]}"#.utf8)
            defaults.set(badTone, forKey: PaintToolPresetStore.presetsKey)
            let store = PaintToolPresetStore(defaults: defaults)
            assertPresetError({ _ = try store.load() }) {
                if case .unknownToneRange(let tag) = $0 { return tag == "ultra" }
                return false
            }
            // A brush resource of another kind.
            let badKind = Data(#"{"schemaVersion":1,"presets":[{"id":\#(id),"tool":"paintbrush","name":"x","settings":\#(baseSettings),"brushResource":{"kind":"pattern","identity":{"name":"p","isInternal":false}}}]}"#.utf8)
            defaults.set(badKind, forKey: PaintToolPresetStore.presetsKey)
            assertPresetError({ _ = try store.load() }) {
                if case .invalidResourceKind(let tag) = $0 { return tag == "pattern" }
                return false
            }
            // Out-of-range size in stored bytes.
            let badSize = Data(#"{"schemaVersion":1,"presets":[{"id":\#(id),"tool":"paintbrush","name":"x","settings":{"size":10001,"opacity":1,"pressureSize":true,"tones":"midtones","antiErase":false}}]}"#.utf8)
            defaults.set(badSize, forKey: PaintToolPresetStore.presetsKey)
            assertPresetError({ _ = try store.load() }) {
                if case .sizeOutOfRange(let v) = $0 { return v == 10001 }
                return false
            }
            XCTAssertEqual(store.storedData, badSize, "rejected documents are never rewritten")
        }
    }

    // MARK: Names and duplicates

    func testNameRules() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            assertPresetError({ try store.create(tool: .paintbrush, name: "", settings: Self.settings()) }) {
                if case .emptyName = $0 { return true }; return false
            }
            assertPresetError({ try store.create(tool: .paintbrush, name: "  \n\t ", settings: Self.settings()) }) {
                if case .emptyName = $0 { return true }; return false
            }
            assertPresetError({ try store.create(tool: .paintbrush, name: String(repeating: "a", count: 65), settings: Self.settings()) }) {
                if case .nameTooLong(let length, let max) = $0 { return length == 65 && max == PaintToolPresetLimits.maxNameLength }
                return false
            }
            // Accepted and stored trimmed.
            let created = try store.create(tool: .paintbrush, name: "  Soft brush  ", settings: Self.settings())
            XCTAssertEqual(created.name, "Soft brush")
            let doc = try XCTUnwrap(try jsonObject(try XCTUnwrap(store.storedData)) as? [String: Any])
            let preset = try XCTUnwrap(try XCTUnwrap(doc["presets"] as? [[String: Any]]).first)
            XCTAssertEqual(preset["name"] as? String, "Soft brush")
            _ = try store.create(tool: .paintbrush, name: String(repeating: "b", count: 64), settings: Self.settings())
            XCTAssertEqual(try store.load().count, 2)
        }
    }

    func testDuplicateNamePolicy() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let ink = try store.create(tool: .paintbrush, name: "Ink", settings: Self.settings())
            // The same name on another tool is allowed.
            _ = try store.create(tool: .eraser, name: "Ink", settings: Self.settings())
            assertPresetError({ try store.create(tool: .paintbrush, name: "Ink", settings: Self.settings()) }) {
                if case .duplicateName(let name, let tool) = $0 { return name == "Ink" && tool == .paintbrush }
                return false
            }
            // Renaming to the preset's own name is fine.
            try store.rename(id: ink.id, to: "Ink")
            // Renaming onto another preset of the same tool fails.
            let other = try store.create(tool: .paintbrush, name: "Other", settings: Self.settings())
            assertPresetError({ try store.rename(id: other.id, to: "Ink") }) {
                if case .duplicateName(let name, let tool) = $0 { return name == "Ink" && tool == .paintbrush }
                return false
            }
            XCTAssertEqual(try store.load().map(\.name), ["Ink", "Ink", "Other"])
        }
    }

    // MARK: CRUD semantics

    func testCRUDPreservesIdentitiesOrderAndSnapshots() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let first = try store.create(tool: .paintbrush, name: "A",
                                         settings: Self.settings(), brushResource: Self.brushResource())
            let second = try store.create(tool: .eraser, name: "B", settings: Self.settings(antiErase: true))
            let third = try store.create(tool: .paintbrush, name: "C", settings: Self.settings(size: 99))
            XCTAssertEqual(try store.load(), [first, second, third], "stored order is creation order")

            try store.rename(id: second.id, to: "B2")
            var loaded = try store.load()
            XCTAssertEqual(loaded.map(\.id), [first.id, second.id, third.id], "rename keeps the UUID and position")
            XCTAssertEqual(loaded[1].name, "B2")
            XCTAssertEqual(loaded[1].settings, second.settings, "rename keeps the immutable snapshot")

            let newSettings = Self.settings(size: 42, tones: .highlights)
            try store.replace(id: first.id, settings: newSettings, brushResource: nil, foregroundColor: Self.color())
            loaded = try store.load()
            XCTAssertEqual(loaded[0].id, first.id)
            XCTAssertEqual(loaded[0].name, "A", "replace keeps the name")
            XCTAssertEqual(loaded[0].settings, newSettings)
            XCTAssertNil(loaded[0].brushResource)
            XCTAssertEqual(loaded[0].foregroundColor, Self.color())

            try store.delete(id: third.id)
            loaded = try store.load()
            XCTAssertEqual(loaded.map(\.id), [first.id, second.id])

            // A fresh store instance reads the same durable values.
            let reopened = PaintToolPresetStore(defaults: defaults)
            XCTAssertEqual(try reopened.load(), loaded)
            XCTAssertEqual(try reopened.presets(for: .paintbrush).map(\.id), [first.id])
            XCTAssertEqual(try reopened.presets(for: .eraser).map(\.id), [second.id])

            assertPresetError({ try store.delete(id: UUID()) }) {
                if case .unknownPreset = $0 { return true }; return false
            }
            XCTAssertEqual(try store.load(), loaded, "a failed delete changes nothing")
        }
    }

    func testMutationAtomicityOnFailure() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let a = try store.create(tool: .paintbrush, name: "A", settings: Self.settings())
            let b = try store.create(tool: .paintbrush, name: "B", settings: Self.settings())
            let snapshot = try XCTUnwrap(store.storedData)

            assertPresetError({ try store.rename(id: b.id, to: "A") }) {
                if case .duplicateName = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, snapshot, "bytes unchanged after a validation failure")
            assertPresetError({ try store.create(tool: .paintbrush, name: "C", settings: Self.settings(size: -1)) }) {
                if case .sizeOutOfRange = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, snapshot)
            assertPresetError({ try store.replace(id: a.id, settings: Self.settings(opacity: 2),
                                                  brushResource: nil, foregroundColor: nil) }) {
                if case .outOfRange = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, snapshot)
            assertPresetError({ try store.delete(id: UUID()) }) {
                if case .unknownPreset = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, snapshot)
            XCTAssertEqual(try store.load(), [a, b], "the decoded snapshot is unchanged too")
        }
    }

    func testResetClearsTheStore() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            _ = try store.create(tool: .paintbrush, name: "A", settings: Self.settings())
            XCTAssertNotNil(store.storedData)
            try store.reset()
            XCTAssertNil(store.storedData)
            XCTAssertEqual(try store.load(), [])
        }
    }

    // MARK: Corrupt, future and unknown-field documents

    func testCorruptAndUnknownSchemaRejectedWithoutOverwrite() {
        withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let seeds: [(name: String, data: Data, check: (PaintToolPresetError) -> Bool)] = [
                ("garbage bytes", Data("this is not json".utf8), {
                    if case .malformed = $0 { return true }; return false
                }),
                ("missing schema version", Data(#"{"presets":[]}"#.utf8), {
                    if case .missingSchemaVersion = $0 { return true }; return false
                }),
                ("future schema version", Data(#"{"schemaVersion":3,"presets":[]}"#.utf8), {
                    if case .unsupportedSchemaVersion(let found, let supported) = $0 {
                        return found == 3 && supported == 2
                    }
                    return false
                }),
                ("missing presets array", Data(#"{"schemaVersion":1}"#.utf8), {
                    if case .malformed = $0 { return true }; return false
                }),
            ]
            for seed in seeds {
                defaults.set(seed.data, forKey: PaintToolPresetStore.presetsKey)
                assertPresetError({ _ = try store.load() }, seed.check)
                assertPresetError({ try store.create(tool: .paintbrush, name: "x", settings: Self.settings()) },
                                  { _ in true },
                                  file: #filePath, line: #line)
                XCTAssertEqual(store.storedData, seed.data,
                               "\(seed.name): a failed mutation never clobbers the stored bytes")
                XCTAssertNil(try? store.load(), "\(seed.name): no silent empty recovery")
            }
        }
    }

    func testUnreadableStorageAndDuplicateIdentifiersStayUntouched() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            defaults.set("unexpected property-list value", forKey: PaintToolPresetStore.presetsKey)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.create(tool: .paintbrush, name: "new", settings: Self.settings()))
            XCTAssertEqual(defaults.string(forKey: PaintToolPresetStore.presetsKey), "unexpected property-list value")

            let preset = try PaintToolPreset(tool: .paintbrush, name: "one", settings: Self.settings())
            let encoded = String(decoding: try JSONEncoder().encode(preset), as: UTF8.self)
            let duplicate = Data("{\"schemaVersion\":1,\"presets\":[\(encoded),\(encoded)]}".utf8)
            defaults.set(duplicate, forKey: PaintToolPresetStore.presetsKey)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.rename(id: preset.id, to: "renamed"))
            XCTAssertEqual(store.storedData, duplicate)
            let second = try PaintToolPreset(tool: .paintbrush, name: "one", settings: Self.settings())
            let secondJSON = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
            let duplicateName = Data("{\"schemaVersion\":1,\"presets\":[\(encoded),\(secondJSON)]}".utf8)
            defaults.set(duplicateName, forKey: PaintToolPresetStore.presetsKey)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.create(tool: .eraser, name: "new", settings: Self.settings()))
            XCTAssertEqual(store.storedData, duplicateName)

            let corrupt = Data("not JSON".utf8)
            defaults.set(corrupt, forKey: PaintToolPresetStore.presetsKey)
            XCTAssertThrowsError(try store.reset())
            XCTAssertEqual(store.storedData, corrupt)
        }
    }

    func testUnknownNestedFieldsCannotBeErasedByMutation() throws {
        try withDefaults { defaults in
            let store = PaintToolPresetStore(defaults: defaults)
            let preset = try PaintToolPreset(tool: .paintbrush, name: "one", settings: Self.settings(),
                                             brushResource: Self.brushResource("known"),
                                             foregroundColor: Self.color(red: 0.4))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
            for target in ["preset", "settings", "brushResource", "identity", "foregroundColor", "envelope"] {
                var row = value
                var envelope: [String: Any] = ["schemaVersion": 1]
                let future: [String: Any] = ["futureField": NSNumber(value: Int64(9_007_199_254_740_993))]
                if target == "preset" { row.merge(future) { _, new in new } }
                else if target == "identity" {
                    var resource = try XCTUnwrap(row["brushResource"] as? [String: Any])
                    var identity = try XCTUnwrap(resource["identity"] as? [String: Any])
                    identity.merge(future) { _, new in new }
                    resource["identity"] = identity; row["brushResource"] = resource
                } else if target == "envelope" { envelope.merge(future) { _, new in new } }
                else {
                    var nested = try XCTUnwrap(row[target] as? [String: Any])
                    nested.merge(future) { _, new in new }; row[target] = nested
                }
                envelope["presets"] = [row]
                let data = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
                defaults.set(data, forKey: PaintToolPresetStore.presetsKey)
                XCTAssertThrowsError(try store.load(), target)
                XCTAssertThrowsError(try store.rename(id: preset.id, to: "renamed"), target)
                XCTAssertEqual(store.storedData, data, target)
            }
        }
    }

}
