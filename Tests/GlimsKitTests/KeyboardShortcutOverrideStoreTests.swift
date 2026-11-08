import Foundation
import XCTest
@testable import GlimsKit

/// Pure checks for the persistent keyboard shortcut override store: schema-1
/// UserDefaults document, validated mutations, strict load (corrupt, unknown
/// keys, wrong version/types, duplicate ids all throw and never reset), orphan
/// retention, and failed mutations leaving the stored bytes untouched. No
/// engine, no AppKit windows.
final class KeyboardShortcutOverrideStoreTests: XCTestCase {

    // MARK: - Helpers

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.shortcutstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func seed(_ defaults: UserDefaults, json: String) {
        defaults.set(Data(json.utf8), forKey: KeyboardShortcutOverrideStore.overridesKey)
    }

    private func seed(_ defaults: UserDefaults, object: Any) {
        defaults.set(object, forKey: KeyboardShortcutOverrideStore.overridesKey)
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func assertError<T>(_ body: () throws -> T,
                                _ check: (KeyboardShortcutError) -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try body()
            XCTFail("expected a KeyboardShortcutError", file: file, line: line)
        } catch let error as KeyboardShortcutError {
            XCTAssertTrue(check(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("expected a KeyboardShortcutError, got \(error)", file: file, line: line)
        }
    }

    private func shortcut(_ keyInput: String, _ modifiers: ShortcutModifiers) -> KeyboardShortcut {
        KeyboardShortcut(keyInput: keyInput, modifiers: modifiers)!
    }

    /// A small catalog used across the tests.
    private func catalog() throws -> KeyboardShortcutCatalog {
        try KeyboardShortcutCatalog([
            ("edit.undo", shortcut("z", [.command])),
            ("edit.redo", shortcut("z", [.command, .shift])),
            ("tool.paintbrush", shortcut("b", [])),
        ])
    }

    // MARK: - Round trip

    func testEmptyStoreWhenNothingStored() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            XCTAssertEqual(try store.load(), [:])
            XCTAssertNil(store.storedData)
        }
    }

    func testAssignDisableResetRoundTrip() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let catalog = try catalog()

            try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: catalog)
            XCTAssertEqual(try store.load()["edit.undo"], .assign(shortcut("u", [.command])))

            try store.disable("edit.undo", catalog: catalog)
            XCTAssertEqual(try store.load()["edit.undo"], .disable)

            try store.reset("edit.undo", catalog: try self.catalog())
            XCTAssertEqual(try store.load(), [:])

            try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: catalog)
            try store.resetAll(catalog: try self.catalog())
            XCTAssertEqual(try store.load(), [:])
            XCTAssertNil(store.storedData)
        }
    }

    func testStoredDocumentShape() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            try store.assign(shortcut("u", [.command, .shift]), to: "edit.undo", catalog: try catalog())
            try store.disable("edit.redo", catalog: try catalog())

            let data = try XCTUnwrap(store.storedData)
            let document = try XCTUnwrap(try jsonObject(data) as? [String: Any])
            XCTAssertEqual(document["schemaVersion"] as? Int, 1)
            let entries = try XCTUnwrap(document["overrides"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 2)
            for entry in entries {
                XCTAssertEqual(Set(entry.keys), ["command", "override"])
                let override = try XCTUnwrap(entry["override"] as? [String: Any])
                let kind = try XCTUnwrap(override["kind"] as? String)
                XCTAssertEqual(Set(override.keys), kind == "disable" ? ["kind"] : ["kind", "shortcut"])
                if let shortcutObject = override["shortcut"] as? [String: Any] {
                    XCTAssertEqual(Set(shortcutObject.keys), ["key", "modifiers"])
                    XCTAssertEqual(shortcutObject["key"] as? String, "u")
                    XCTAssertEqual(shortcutObject["modifiers"] as? Int, ShortcutModifiers.command.rawValue | ShortcutModifiers.shift.rawValue)
                }
            }
            let commands = entries.compactMap { $0["command"] as? String }.sorted()
            XCTAssertEqual(commands, ["edit.redo", "edit.undo"])
        }
    }

    // MARK: - Mutation rules

    func testAssignToUnknownCommandThrows() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            assertError({ try store.assign(shortcut("u", [.command]), to: "no.such.command", catalog: try catalog()) }) {
                if case .unknownCommand("no.such.command") = $0 { return true }; return false
            }
            XCTAssertNil(store.storedData)
        }
    }

    func testAssignWithoutCommandOrControlThrowsAndPreservesStore() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let catalog = try catalog()
            try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: catalog)
            let before = store.storedData

            assertError({ try store.assign(shortcut("p", []), to: "edit.redo", catalog: catalog) }) {
                if case .missingCommandOrControl = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, before, "a failed mutation must leave the stored bytes untouched")
            XCTAssertEqual(try store.load().keys.sorted(), ["edit.undo"])
        }
    }

    func testAssignConflictThrowsNamesCommandsAndPreservesStore() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let catalog = try catalog()
            try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: catalog)
            let before = store.storedData

            // edit.redo would take edit.undo's effective override.
            assertError({ try store.assign(shortcut("u", [.command]), to: "edit.redo", catalog: catalog) }) {
                if case .conflict(_, "edit.redo", "edit.undo") = $0 { return true }; return false
            }
            // ...or another command's factory base.
            assertError({ try store.assign(shortcut("z", [.command, .shift]), to: "tool.paintbrush", catalog: catalog) }) {
                if case .conflict(_, "tool.paintbrush", "edit.redo") = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, before)
            let effective = try catalog.effectiveShortcuts(overrides: try store.load())
            XCTAssertEqual(effective.shortcut(forCommand: "edit.undo"), shortcut("u", [.command]))
            XCTAssertEqual(effective.shortcut(forCommand: "edit.redo"), shortcut("z", [.command, .shift]))
        }
    }

    func testAssignReservedCombinationThrows() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let catalog = try catalog()
            assertError({ try store.assign(shortcut("h", [.command]), to: "edit.undo", catalog: catalog) }) {
                if case .reserved(_, "edit.undo") = $0 { return true }; return false
            }
            assertError({ try store.assign(shortcut(" ", [.command]), to: "edit.redo", catalog: catalog) }) {
                if case .reserved = $0 { return true }; return false
            }
            XCTAssertNil(store.storedData)
        }
    }

    func testDisableThenReassignOnesOwnFreedShortcut() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let catalog = try catalog()
            try store.disable("edit.undo", catalog: catalog)
            try store.assign(shortcut("z", [.command]), to: "edit.redo", catalog: catalog)
            let effective = try catalog.effectiveShortcuts(overrides: try store.load())
            XCTAssertNil(effective.shortcut(forCommand: "edit.undo"))
            XCTAssertEqual(effective.shortcut(forCommand: "edit.redo"), shortcut("z", [.command]))
            // Reset restores the factory base.
            try store.reset("edit.redo", catalog: try self.catalog())
            try store.reset("edit.undo", catalog: try self.catalog())
            let restored = try catalog.effectiveShortcuts(overrides: try store.load())
            XCTAssertEqual(restored.shortcut(forCommand: "edit.undo"), shortcut("z", [.command]))
            XCTAssertEqual(restored.shortcut(forCommand: "edit.redo"), shortcut("z", [.command, .shift]))
        }
    }

    // MARK: - Strict load

    func testCorruptBytesThrowAndAreNotReset() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: "this is not json")
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
            // The bytes stay; nothing resets them.
            XCTAssertEqual(store.storedData, Data("this is not json".utf8))
        }
    }

    func testNonDataStoredValueThrows() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, object: "a string, not data")
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
            XCTAssertEqual(defaults.string(forKey: KeyboardShortcutOverrideStore.overridesKey), "a string, not data")
        }
    }

    func testWrongTopLevelShapeThrows() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: #"["not","an","object"]"#)
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
            seed(defaults, json: #"{"schemaVersion":1,"overrides":{"edit.undo":{"kind":"disable"}}}"#)
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
        }
    }

    func testUnknownKeysThrowAtEveryLevel() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[],"futureField":1}"#)
            assertError({ try store.load() }) { if case .malformed(let detail) = $0 { return detail.contains("futureField") }; return false }
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"disable"},"extra":1}]}"#)
            assertError({ try store.load() }) { if case .malformed(let detail) = $0 { return detail.contains("extra") }; return false }
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"u","modifiers":1},"extra":1}}]}"#)
            assertError({ try store.load() }) { if case .malformed(let detail) = $0 { return detail.contains("extra") }; return false }
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"u","modifiers":1,"extra":1}}}]}"#)
            assertError({ try store.load() }) { if case .malformed(let detail) = $0 { return detail.contains("extra") }; return false }
        }
    }

    func testSchemaVersionValidation() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: #"{"schemaVersion":2,"overrides":[]}"#)
            assertError({ try store.load() }) {
                if case .unsupportedSchemaVersion(let found, let supported) = $0 { return found == 2 && supported == 1 }
                return false
            }
            seed(defaults, json: #"{"overrides":[]}"#)
            assertError({ try store.load() }) { if case .missingSchemaVersion = $0 { return true }; return false }
            seed(defaults, json: #"{"schemaVersion":"1","overrides":[]}"#)
            XCTAssertThrowsError(try store.load())
        }
    }

    func testDuplicateStoredCommandIDsThrow() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"disable"}},{"command":"a","override":{"kind":"disable"}}]}"#)
            assertError({ try store.load() }) {
                if case .duplicateStoredOverride("a") = $0 { return true }; return false
            }
        }
    }

    func testInvalidStoredValuesThrow() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            // Unknown override kind.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"remove"}}]}"#)
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
            // Disable carrying a shortcut.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"disable","shortcut":{"key":"u","modifiers":1}}}]}"#)
            assertError({ try store.load() }) { if case .malformed = $0 { return true }; return false }
            // Unknown modifier bits.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"u","modifiers":16}}}]}"#)
            assertError({ try store.load() }) { if case .unknownModifierBits(16) = $0 { return true }; return false }
            // Multi-character key.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"uu","modifiers":1}}}]}"#)
            assertError({ try store.load() }) { if case .invalidKey("uu") = $0 { return true }; return false }
            // Control-character key.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"\t","modifiers":1}}}]}"#)
            XCTAssertThrowsError(try store.load())
            // Override without Command or Control.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a","override":{"kind":"assign","shortcut":{"key":"u","modifiers":0}}}]}"#)
            assertError({ try store.load() }) { if case .missingCommandOrControl = $0 { return true }; return false }
            // Empty / control command id.
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"","override":{"kind":"disable"}}]}"#)
            assertError({ try store.load() }) { if case .emptyCommandID = $0 { return true }; return false }
            seed(defaults, json: #"{"schemaVersion":1,"overrides":[{"command":"a\nb","override":{"kind":"disable"}}]}"#)
            assertError({ try store.load() }) { if case .invalidCommandID = $0 { return true }; return false }
        }
    }

    // MARK: - Orphans and catalog evolution

    private func seedOrphanDocument(_ defaults: UserDefaults) {
        seed(defaults, json: """
        {"schemaVersion":1,"overrides":[
          {"command":"edit.undo","override":{"kind":"assign","shortcut":{"key":"u","modifiers":1}}},
          {"command":"legacy.command","override":{"kind":"assign","shortcut":{"key":"j","modifiers":1}}}
        ]}
        """)
    }

    func testOrphanOverridesLoadAndAreRetainedUntouched() throws {
        try withDefaults { defaults in
            seedOrphanDocument(defaults)
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let loaded = try store.load()
            XCTAssertEqual(loaded["legacy.command"], .assign(shortcut("j", [.command])))

            // Mutations for known commands work and keep the orphan bytes.
            let catalogV1 = try KeyboardShortcutCatalog([("edit.undo", shortcut("z", [.command]))])
            try store.assign(shortcut("y", [.command]), to: "edit.undo", catalog: catalogV1)
            let data = try XCTUnwrap(store.storedData)
            let document = try XCTUnwrap(try jsonObject(data) as? [String: Any])
            let entries = try XCTUnwrap(document["overrides"] as? [[String: Any]])
            XCTAssertEqual(Set(entries.compactMap { $0["command"] as? String }), ["edit.undo", "legacy.command"])
            XCTAssertEqual(try store.load()["legacy.command"], .assign(shortcut("j", [.command])))

            // The orphan is inactive in the effective catalog.
            let effective = try catalogV1.effectiveShortcuts(overrides: try store.load())
            XCTAssertNil(effective.command(forShortcut: shortcut("j", [.command])))

            // Reset removes the orphan explicitly.
            try store.reset("legacy.command", catalog: try self.catalog())
            XCTAssertEqual(try store.load().keys.sorted(), ["edit.undo"])
        }
    }

    func testKnownAgainOverrideIsRevalidatedBeforeApply() throws {
        try withDefaults { defaults in
            seedOrphanDocument(defaults)
            let store = KeyboardShortcutOverrideStore(defaults: defaults)

            // The catalog grows: legacy.command is known again and now
            // conflicts with edit.redo's factory base.
            let catalogV2 = try KeyboardShortcutCatalog([
                ("edit.undo", shortcut("z", [.command])),
                ("edit.redo", shortcut("j", [.command])),
                ("legacy.command", nil),
            ])
            assertError({ try catalogV2.effectiveShortcuts(overrides: try store.load()) }) {
                if case .conflict(_, "legacy.command", "edit.redo") = $0 { return true }; return false
            }
            // Any persisting mutation with the new catalog fails the same way,
            // before writing.
            let before = store.storedData
            assertError({ try store.assign(shortcut("y", [.command, .option]), to: "edit.undo", catalog: catalogV2) }) {
                if case .conflict(_, "legacy.command", "edit.redo") = $0 { return true }; return false
            }
            XCTAssertEqual(store.storedData, before)
        }
    }

    func testTypedAssignmentRejectsUnknownModifierBitsBeforeWriting() throws {
        for raw in [ShortcutModifiers.command.rawValue | (1 << 10), Int.min | ShortcutModifiers.command.rawValue] {
            try withDefaults { defaults in
                let store = KeyboardShortcutOverrideStore(defaults: defaults)
                let key = try XCTUnwrap(ShortcutKey(input: "k"))
                let bad = KeyboardShortcut(key: key, modifiers: ShortcutModifiers(rawValue: raw))
                XCTAssertThrowsError(try store.assign(bad, to: "edit.undo", catalog: catalog()))
                XCTAssertNil(store.storedData, "typed invalid bits must not create an unreadable document")
                XCTAssertThrowsError(try CommandShortcutEntry(id: "bad.base", base: bad))
            }
        }
    }

    // MARK: - Reset validation

    func testResetCannotRestoreADefaultTakenByAnotherOverride() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            let commands = try KeyboardShortcutCatalog([
                ("command.a", shortcut("a", [.command])),
                ("command.b", shortcut("b", [.command]))
            ])
            try store.disable("command.a", catalog: commands)
            try store.assign(shortcut("a", [.command]), to: "command.b", catalog: commands)
            let before = store.storedData
            XCTAssertThrowsError(try store.reset("command.a", catalog: commands))
            XCTAssertEqual(store.storedData, before, "a conflicting default must not be persisted")
        }
    }


    func testResetAllValidatesBeforeRemoving() throws {
        try withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: "corrupt bytes")
            assertError({ try store.resetAll(catalog: try self.catalog()) }) { if case .malformed = $0 { return true }; return false }
            XCTAssertEqual(store.storedData, Data("corrupt bytes".utf8), "a failed reset must keep the stored bytes")

            seed(defaults, json: #"{"schemaVersion":99,"overrides":[]}"#)
            assertError({ try store.resetAll(catalog: try self.catalog()) }) { if case .unsupportedSchemaVersion = $0 { return true }; return false }
            XCTAssertNotNil(store.storedData, "a failed reset must keep the stored bytes")
            defaults.removeObject(forKey: KeyboardShortcutOverrideStore.overridesKey)

            try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: try catalog())
            try store.resetAll(catalog: try self.catalog())
            XCTAssertNil(store.storedData)
        }
    }

    func testFailedMutationOnCorruptStoreThrowsAndPreserves() throws {
        withDefaults { defaults in
            let store = KeyboardShortcutOverrideStore(defaults: defaults)
            seed(defaults, json: "corrupt bytes")
            assertError({ try store.assign(shortcut("u", [.command]), to: "edit.undo", catalog: try catalog()) }) {
                if case .malformed = $0 { return true }; return false
            }
            assertError({ try store.reset("edit.undo", catalog: try self.catalog()) }) { if case .malformed = $0 { return true }; return false }
            XCTAssertEqual(store.storedData, Data("corrupt bytes".utf8))
        }
    }
}
