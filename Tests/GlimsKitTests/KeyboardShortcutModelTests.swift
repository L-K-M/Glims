import Foundation
import XCTest
@testable import GlimsKit

/// Pure checks for the keyboard shortcut model: key normalization and
/// rejection, the own modifier set, override rules, macOS reservations,
/// conflicts against the effective catalog. No engine, no AppKit, no UI.
final class KeyboardShortcutModelTests: XCTestCase {

    // MARK: - Helpers

    private func key(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> ShortcutKey {
        guard let key = ShortcutKey(input: input) else {
            XCTFail("expected a valid key for \(input.debugDescription)", file: file, line: line)
            return ShortcutKey(persisted: "x")!
        }
        return key
    }

    private func shortcut(_ keyInput: String, _ modifiers: ShortcutModifiers,
                          file: StaticString = #filePath, line: UInt = #line) -> KeyboardShortcut {
        guard let shortcut = KeyboardShortcut(keyInput: keyInput, modifiers: modifiers) else {
            XCTFail("expected a valid shortcut for \(keyInput.debugDescription)", file: file, line: line)
            return KeyboardShortcut(key: ShortcutKey(persisted: "x")!, modifiers: [])
        }
        return shortcut
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

    // MARK: - Key normalization

    func testKeyNormalizesLettersToLowerCase() {
        XCTAssertEqual(key("A").value, "a")
        XCTAssertEqual(key("Z").value, "z")
        XCTAssertEqual(key("a").value, "a")
        XCTAssertEqual(key("É").value, "é")
        XCTAssertEqual(key("Γ").value, "γ")
    }

    func testKeyKeepsPunctuationAndSymbols() {
        XCTAssertEqual(key("!").value, "!")
        XCTAssertEqual(key("`").value, "`")
        XCTAssertEqual(key(" ").value, " ")
        XCTAssertEqual(key("€").value, "€")
        XCTAssertEqual(key("5").value, "5")
        XCTAssertEqual(key("§").value, "§")
    }

    func testKeyMapsAppKitFunctionKeyUnicodesToOwnStrings() {
        XCTAssertEqual(key("\u{F700}").value, "upArrow")
        XCTAssertEqual(key("\u{F701}").value, "downArrow")
        XCTAssertEqual(key("\u{F702}").value, "leftArrow")
        XCTAssertEqual(key("\u{F703}").value, "rightArrow")
        XCTAssertEqual(key("\u{F704}").value, "f1")
        XCTAssertEqual(key("\u{F70A}").value, "f7")
        XCTAssertEqual(key("\u{F726}").value, "f35")
        XCTAssertEqual(key("\u{F728}").value, "delete")
        XCTAssertEqual(key("\u{F729}").value, "home")
        XCTAssertEqual(key("\u{F72B}").value, "end")
        XCTAssertEqual(key("\u{F72C}").value, "pageUp")
        XCTAssertEqual(key("\u{F72D}").value, "pageDown")
        XCTAssertEqual(key("\u{F746}").value, "help")
    }

    func testKeyPersistedFormRoundTrips() throws {
        let function = shortcut("\u{F70C}", [.command]) // f9
        XCTAssertEqual(function.key.value, "f9")
        let data = try JSONEncoder().encode(function)
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(decoded, function)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutKey.self, from: JSONEncoder().encode(ShortcutKey(persisted: "f5")!)).value, "f5")
    }

    // MARK: - Key rejection

    func testKeyRejectsInvalidInput() {
        let invalid = ["", "ab", "abc", "a b",
                       "\u{00}", "\u{08}", "\u{09}", "\u{0A}", "\u{0D}", "\u{7F}", // NUL, control, DEL
                       "\u{200B}", "\u{200D}", "\u{FEFF}",                            // format characters
                       "\u{2028}", "\u{2029}",                                       // line/paragraph separator
                       "\u{E000}",                                                   // private use, not a function key
                       "\u{F747}",                                                   // function range, unmapped
                       "\u{10FFFF}"]                                                 // unassigned
        for raw in invalid {
            XCTAssertNil(ShortcutKey(input: raw), "expected rejection of \(raw.debugDescription)")
            XCTAssertNil(ShortcutKey(persisted: raw), "expected persisted rejection of \(raw.debugDescription)")
        }
    }

    func testKeyPersistedRejectsUnknownTagsAndMultiChar() {
        XCTAssertNil(ShortcutKey(persisted: "f36"))
        XCTAssertNil(ShortcutKey(persisted: "up"))
        XCTAssertNil(ShortcutKey(persisted: "aa"))
        XCTAssertEqual(ShortcutKey(persisted: "a")?.value, "a")
        XCTAssertEqual(ShortcutKey(persisted: "A")?.value, "a")
    }

    // MARK: - Modifiers

    func testModifiersRoundTripAndEncodeAsOwnRawValue() throws {
        let all: [ShortcutModifiers] = [[], [.command], [.shift], [.option], [.control],
                                         [.command, .shift], [.command, .option, .control],
                                         [.command, .shift, .option, .control]]
        for modifiers in all {
            let data = try JSONEncoder().encode(modifiers)
            XCTAssertEqual(try JSONDecoder().decode(ShortcutModifiers.self, from: data), modifiers)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? Int)
            XCTAssertEqual(object, modifiers.rawValue)
        }
        XCTAssertEqual(ShortcutModifiers.command.rawValue | ShortcutModifiers.shift.rawValue
                       | ShortcutModifiers.option.rawValue | ShortcutModifiers.control.rawValue, 0b1111)
    }

    func testModifiersRejectUnknownBits() {
        XCTAssertNoThrow(try JSONDecoder().decode(ShortcutModifiers.self, from: Data("15".utf8)))
        assertError({ try JSONDecoder().decode(ShortcutModifiers.self, from: Data("16".utf8)) }) {
            if case .unknownModifierBits(16) = $0 { return true }; return false
        }
        assertError({ try JSONDecoder().decode(ShortcutModifiers.self, from: Data("-1".utf8)) }) {
            if case .unknownModifierBits = $0 { return true }; return false
        }
        // A non-integer stored value is a type error.
        XCTAssertThrowsError(try JSONDecoder().decode(ShortcutModifiers.self, from: Data(#""cmd""#.utf8)))
    }

    // MARK: - Shortcut Codable strictness

    func testShortcutRejectsUnknownFieldsAndWrongTypes() {
        let valid = #"{"key":"a","modifiers":1}"#
        XCTAssertNoThrow(try JSONDecoder().decode(KeyboardShortcut.self, from: Data(valid.utf8)))
        assertError({ try JSONDecoder().decode(KeyboardShortcut.self, from: Data(#"{"key":"a","modifiers":1,"future":true}"#.utf8)) }) {
            if case .malformed = $0 { return true }; return false
        }
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardShortcut.self, from: Data(#"{"key":"a","modifiers":"cmd"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardShortcut.self, from: Data(#"{"modifiers":1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardShortcut.self, from: Data(#"{"key":"ab","modifiers":1}"#.utf8)))
    }

    // MARK: - Catalog validation

    func testCatalogRejectsBadEntries() {
        assertError({ try KeyboardShortcutCatalog([("a", nil), ("a", nil)]) }) {
            if case .duplicateCommandID("a") = $0 { return true }; return false
        }
        assertError({ try KeyboardShortcutCatalog([("", nil)]) }) {
            if case .emptyCommandID = $0 { return true }; return false
        }
        assertError({ try KeyboardShortcutCatalog([("a\nb", nil)]) }) {
            if case .invalidCommandID = $0 { return true }; return false
        }
        let base = shortcut("z", [.command])
        assertError({ try KeyboardShortcutCatalog([("a", base), ("b", base)]) }) {
            if case .duplicateBaseShortcut(_, let first, let second) = $0 { return first == "a" && second == "b" }
            return false
        }
    }

    // MARK: - Override rules

    func testOverrideRequiresCommandOrControl() throws {
        let catalog = try KeyboardShortcutCatalog([("tool.paintbrush", nil), ("edit.undo", shortcut("z", [.command]))])
        assertError({ try catalog.effectiveShortcuts(overrides: ["tool.paintbrush": .assign(shortcut("b", []))]) }) {
            if case .missingCommandOrControl(_, let command) = $0 { return command == "tool.paintbrush" }
            return false
        }
        assertError({ try catalog.effectiveShortcuts(overrides: ["tool.paintbrush": .assign(shortcut("b", [.shift]))]) }) {
            if case .missingCommandOrControl = $0 { return true }; return false
        }
        // Control alone is enough; plain bases stay allowed.
        let effective = try catalog.effectiveShortcuts(overrides: ["tool.paintbrush": .assign(shortcut("b", [.control]))])
        XCTAssertEqual(effective.shortcut(forCommand: "tool.paintbrush"), shortcut("b", [.control]))
        XCTAssertEqual(effective.shortcut(forCommand: "edit.undo"), shortcut("z", [.command]))
    }

    func testBaseShortcutsMayBePlainToolKeys() throws {
        let catalog = try KeyboardShortcutCatalog([("tool.paintbrush", shortcut("b", [])), ("tool.eraser", nil)])
        let effective = try catalog.effectiveShortcuts(overrides: [:])
        XCTAssertEqual(effective.shortcut(forCommand: "tool.paintbrush"), shortcut("b", []))
        XCTAssertNil(effective.shortcut(forCommand: "tool.eraser"))
    }

    // MARK: - Conflicts

    func testConflictAgainstEffectiveCatalogNamesBothCommands() throws {
        let undo = shortcut("z", [.command])
        let catalog = try KeyboardShortcutCatalog([("edit.undo", undo), ("edit.redo", shortcut("z", [.command, .shift]))])
        assertError({ try catalog.effectiveShortcuts(overrides: ["edit.redo": .assign(undo)]) }) { error in
            guard case .conflict(let shortcut, let command, let other) = error else { return false }
            return shortcut == undo && command == "edit.redo" && other == "edit.undo"
                && error.description.contains("\"edit.undo\"") && error.description.contains("\"edit.redo\"")
        }
        // An override also conflicts with another command's override, not only bases.
        assertError({ try catalog.effectiveShortcuts(overrides: ["edit.undo": .assign(shortcut("y", [.command])),
                                                                   "edit.redo": .assign(shortcut("y", [.command]))]) }) {
            if case .conflict(_, _, let other) = $0 { return other == "edit.undo" || other == "edit.redo" }
            return false
        }
        // The conflict never silently unbinds the other command: without the
        // failing override the catalog resolves.
        let effective = try catalog.effectiveShortcuts(overrides: ["edit.undo": .assign(shortcut("y", [.command]))])
        XCTAssertEqual(effective.shortcut(forCommand: "edit.undo"), shortcut("y", [.command]))
        XCTAssertEqual(effective.shortcut(forCommand: "edit.redo"), shortcut("z", [.command, .shift]))
    }

    func testDisabledCommandFreesItsShortcut() throws {
        let undo = shortcut("z", [.command])
        let catalog = try KeyboardShortcutCatalog([("edit.undo", undo), ("edit.redo", shortcut("y", [.command]))])
        let disabled = try catalog.effectiveShortcuts(overrides: ["edit.undo": .disable])
        XCTAssertNil(disabled.shortcut(forCommand: "edit.undo"))
        XCTAssertNil(disabled.command(forShortcut: undo))
        // Now the freed shortcut can be taken — explicitly, not silently.
        let taken = try catalog.effectiveShortcuts(overrides: ["edit.undo": .disable, "edit.redo": .assign(undo)])
        XCTAssertEqual(taken.shortcut(forCommand: "edit.redo"), undo)
        // But two live commands on one shortcut still conflict.
        assertError({ try catalog.effectiveShortcuts(overrides: ["edit.redo": .assign(undo)]) }) {
            if case .conflict(_, "edit.redo", "edit.undo") = $0 { return true }; return false
        }
    }

    // MARK: - macOS reservations

    func testReservedCombinationsAreDocumentedAndFixed() {
        XCTAssertEqual(KeyboardShortcut.reserved.count, 14)
        let expected: [(String, ShortcutModifiers)] = [
            ("h", [.command]), ("h", [.command, .option]),
            ("m", [.command]), ("m", [.command, .option]),
            ("q", [.command]), ("q", [.command, .shift]), ("q", [.command, .control]),
            (" ", [.command]), (" ", [.command, .option]),
            ("`", [.command]), ("`", [.command, .shift]),
            ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]),
        ]
        for (input, modifiers) in expected {
            XCTAssertTrue(KeyboardShortcut.reserved.contains(shortcut(input, modifiers)),
                          "missing reservation \(input) \(modifiers)")
        }
    }

    func testReservedCombinationsCannotBeClaimedByOtherCommands() throws {
        let catalog = try KeyboardShortcutCatalog([("edit.copy", shortcut("c", [.command])),
                                                   ("edit.paste", shortcut("v", [.command]))])
        for reserved in KeyboardShortcut.reserved {
            assertError({ try catalog.effectiveShortcuts(overrides: ["edit.copy": .assign(reserved)]) }) {
                if case .reserved(let shortcut, let command) = $0 {
                    return shortcut == reserved && command == "edit.copy"
                }
                return false
            }
        }
    }

    func testReservationOwnerKeepsItsFactoryBase() throws {
        let hide = shortcut("h", [.command])
        let catalog = try KeyboardShortcutCatalog([("app.hide", hide), ("edit.copy", shortcut("c", [.command]))])
        // The owner's own default is preserved in the effective catalog.
        let effective = try catalog.effectiveShortcuts(overrides: [:])
        XCTAssertEqual(effective.shortcut(forCommand: "app.hide"), hide)
        // Even re-assigning the reserved combination to the owner is allowed.
        let reassigned = try catalog.effectiveShortcuts(overrides: ["app.hide": .assign(hide)])
        XCTAssertEqual(reassigned.shortcut(forCommand: "app.hide"), hide)
        // Another command still cannot claim it, and the conflict error names it.
        assertError({ try catalog.effectiveShortcuts(overrides: ["edit.copy": .assign(hide)]) }) {
            if case .reserved(_, "edit.copy") = $0 { return true }; return false
        }
    }

    // MARK: - Orphans (catalog evolution)

    func testOrphanOverridesAreInactiveUntilKnownAgain() throws {
        let catalogV1 = try KeyboardShortcutCatalog([("edit.undo", shortcut("z", [.command]))])
        let overrides: [String: CommandShortcutOverride] = [
            "edit.undo": .assign(shortcut("u", [.command])),
            "legacy.command": .assign(shortcut("j", [.command])), // orphan: unknown to v1
        ]
        // Inactive: ignored, no conflict, retained by the store.
        let effectiveV1 = try catalogV1.effectiveShortcuts(overrides: overrides)
        XCTAssertEqual(effectiveV1.shortcut(forCommand: "edit.undo"), shortcut("u", [.command]))
        XCTAssertNil(effectiveV1.command(forShortcut: shortcut("j", [.command])))

        // Known again: revalidated BEFORE apply — the stored override now
        // conflicts with another command's base and the resolution fails.
        let catalogV2 = try KeyboardShortcutCatalog([("edit.undo", shortcut("z", [.command])),
                                                      ("edit.redo", shortcut("j", [.command])),
                                                      ("legacy.command", nil)])
        assertError({ try catalogV2.effectiveShortcuts(overrides: overrides) }) {
            if case .conflict(let combo, let command, let other) = $0 {
                return combo == shortcut("j", [.command]) && command == "legacy.command" && other == "edit.redo"
            }
            return false
        }
        // With the conflict resolved, the returning override applies.
        let resolved = try catalogV2.effectiveShortcuts(overrides: ["legacy.command": .assign(shortcut("j", [.command])),
                                                                     "edit.redo": .disable])
        XCTAssertEqual(resolved.shortcut(forCommand: "legacy.command"), shortcut("j", [.command]))
        XCTAssertNil(resolved.shortcut(forCommand: "edit.redo"))
    }
}
