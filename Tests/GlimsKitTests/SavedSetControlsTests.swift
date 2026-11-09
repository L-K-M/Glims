import AppKit
import XCTest
@testable import GlimsKit

/// Pure tests for View ▸ Saved Sets…: the full-name contract, the kind
/// chooser, the token-addressed row model (identity is never a label), the
/// cached write admission, explicit member-list and request validation, the
/// all-kinds recall admission and the panel's phase machine.
final class SavedSetControlsTests: XCTestCase {
    private typealias Logic = SavedSetControlsLogic
    private typealias Kind = EngineSession.ItemSetKind

    private func rejection<T>(_ result: Result<T, Logic.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.message }
        return nil
    }

    private func row(_ token: UInt64, _ kind: Kind, _ name: String,
                     count: Int = 0, members: [Int32] = []) -> Logic.Row {
        Logic.Row(set: EngineSession.ItemSet(token: token, kind: kind,
                                             displayName: name, memberCount: count),
                  members: members)
    }

    // MARK: Name

    func testValidNamesAreAccepted() {
        for name in ["a", "Layers A", "山 山", String(repeating: "a", count: 255)] {
            guard case .success = Logic.validateName(name) else {
                return XCTFail("'\(name.prefix(20))' must be accepted")
            }
        }
    }

    func testEmptyNulControlAndOversizedNamesAreRejected() {
        XCTAssertNotNil(rejection(Logic.validateName("")))
        XCTAssertNotNil(rejection(Logic.validateName("abc\0def")))
        for name in ["a\nb", "a\tb", "\u{01}", "\u{7F}", "\u{85}"] {
            XCTAssertNotNil(rejection(Logic.validateName(name)), "control name must be rejected")
        }
        // "é" is 2 UTF-8 bytes: 127 fit in 254, 128 (256 bytes) do not.
        guard case .success = Logic.validateName(String(repeating: "é", count: 127)) else {
            return XCTFail("254 bytes must pass")
        }
        XCTAssertNotNil(rejection(Logic.validateName(String(repeating: "é", count: 128))))
        XCTAssertNotNil(rejection(Logic.validateName(String(repeating: "a", count: 256))))
    }

    func testRenameDraftNeverSeedsTheTruncatedLabel() {
        // The display label may be truncated; it is never the full name.
        XCTAssertEqual(Logic.initialRenameDraft(displayName: "A very long set name…"), "")
        XCTAssertEqual(Logic.initialRenameDraft(displayName: ""), "")
    }

    // MARK: Kinds and rows

    func testKindChooserListsAllThreeKinds() {
        XCTAssertEqual(Logic.kinds.map(\.0), [.layer, .channel, .path])
        XCTAssertEqual(Logic.kinds.map(\.1), ["Layers", "Channels", "Paths"])
        XCTAssertEqual(Logic.kindTitle(.channel), "Channels")
    }

    func testRowsAreFilteredByKindInStoredOrder() {
        let rows = [row(7, .layer, "L1"), row(3, .channel, "C1"), row(9, .layer, "L2"),
                    row(4, .path, "P1")]
        XCTAssertEqual(Logic.rows(ofKind: .layer, in: rows).map(\.token), [7, 9])
        XCTAssertEqual(Logic.rows(ofKind: .channel, in: rows).map(\.token), [3])
        XCTAssertEqual(Logic.rows(ofKind: .path, in: rows).map(\.token), [4])
    }

    func testRowIdentityIsTheTokenNeverTheLabel() {
        // Two sets with the SAME display label stay distinct rows.
        let rows = [row(1, .layer, "Same"), row(2, .layer, "Same")]
        XCTAssertEqual(Logic.rows(ofKind: .layer, in: rows).count, 2)
        // Selection is preserved by token; a same-named recreated set (a
        // fresh token) does not inherit it.
        XCTAssertEqual(Logic.preservedSelection(1, in: rows), 1)
        XCTAssertNil(Logic.preservedSelection(99, in: rows))
        XCTAssertNil(Logic.preservedSelection(nil, in: rows))
        XCTAssertNil(Logic.preservedSelection(0, in: rows))
    }

    func testReadGenerationsDiscardStale() {
        XCTAssertTrue(Logic.readIsCurrent(generation: 3, current: 3))
        XCTAssertFalse(Logic.readIsCurrent(generation: 2, current: 3))
    }

    // MARK: Cached admission

    private func gate(closing: Bool = false, saving: Bool = false, clipboard: Bool = false,
                      plugin: Bool = false, busy: Bool = false, preview: Bool = false) -> String? {
        Logic.writeAdmission(isClosing: closing, isSavingForClose: saving,
                             isTransferringClipboard: clipboard, pluginRunning: plugin,
                             engineBusy: busy, previewOpen: preview)
    }

    func testWriteAdmissionReasons() {
        XCTAssertEqual(gate(closing: true), ImageDocument.DocumentError.closed.localizedDescription)
        XCTAssertEqual(gate(saving: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertEqual(gate(clipboard: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertTrue(gate(busy: true)?.contains("Wait for the current image operation") == true)
        XCTAssertTrue(gate(preview: true)?.contains("filter preview") == true)
        XCTAssertTrue(gate(plugin: true)?.contains("plug-in") == true)
        XCTAssertNil(gate(), "all clear admits")
    }

    // MARK: Members and requests

    func testMemberListValidation() {
        guard case .success(let empty) = Logic.validateMembers([]) else {
            return XCTFail("an explicit empty set is allowed")
        }
        XCTAssertEqual(empty, [])
        guard case .success(let ids) = Logic.validateMembers([5, 3, 9]) else {
            return XCTFail("positive unique ids pass")
        }
        XCTAssertEqual(ids, [5, 3, 9])
        XCTAssertNotNil(Logic.validateMembers([0, 3]), "id 0 never means the current selection")
        XCTAssertNotNil(Logic.validateMembers([-2]), "negative ids are refused")
        XCTAssertNotNil(Logic.validateMembers([3, 3]), "duplicates are refused")
    }

    func testRequestValidationMirrorsSlot135() {
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .create, kind: .layer, token: 5,
                                              name: "x", members: [], captureSelection: true)),
                        "CREATE takes token 0")
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .create, kind: .layer, token: 0,
                                              name: nil, members: [], captureSelection: true)),
                        "CREATE takes a name")
        if case .failure(let r) = Logic.validateRequest(operation: .create, kind: .layer, token: 0,
                                                        name: "", members: [], captureSelection: true) {
            XCTAssertFalse(r.message.isEmpty)
        } else { XCTFail("an empty CREATE name is refused") }
        guard case .success = Logic.validateRequest(operation: .create, kind: .channel, token: 0,
                                                    name: "ok", members: [4], captureSelection: false) else {
            return XCTFail("a valid CREATE passes")
        }
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .replace, kind: .layer, token: 0,
                                              name: nil, members: [1], captureSelection: false)),
                        "REPLACE takes a current token")
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .replace, kind: .layer, token: 3,
                                              name: "x", members: [1], captureSelection: false)),
                        "REPLACE takes no name")
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .replace, kind: .layer, token: 3,
                                              name: nil, members: [0], captureSelection: false)),
                        "explicit member 0 is refused")
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .rename, kind: .layer, token: 3,
                                              name: "x", members: [1], captureSelection: false)),
                        "RENAME takes no members")
        guard case .success = Logic.validateRequest(operation: .rename, kind: .path, token: 3,
                                                    name: "new", members: [], captureSelection: false) else {
            return XCTFail("a valid RENAME passes")
        }
        XCTAssertNotNil(rejection(Logic.validateRequest(operation: .remove, kind: .layer, token: 0,
                                              name: nil, members: [], captureSelection: false)),
                        "REMOVE takes a current token")
        guard case .success = Logic.validateRequest(operation: .remove, kind: .layer, token: 3,
                                                    name: nil, members: [], captureSelection: false) else {
            return XCTFail("a valid REMOVE passes")
        }
    }

    // MARK: Recall admission

    func testRecallNeedsAnExactExistingListOfAnyKind() {
        let entry = row(8, .layer, "L", count: 2, members: [3, 5])
        guard case .success(let members) = Logic.recallAdmission(kind: .layer, row: entry,
                                                                 existingIDs: [1, 3, 5]) else {
            return XCTFail("an all-existing layer list is recallable")
        }
        XCTAssertEqual(members, [3, 5], "the exact list, in order, goes to the batch selection")
        // Channels and paths recall the same way, against their own rows.
        guard case .success(let channels) = Logic.recallAdmission(kind: .channel,
                                                                   row: row(4, .channel, "C", members: [12, 9]),
                                                                   existingIDs: [9, 12]) else {
            return XCTFail("an all-existing channel list is recallable")
        }
        XCTAssertEqual(channels, [12, 9], "the channel order is kept, never sorted or take-first")
        guard case .success(let paths) = Logic.recallAdmission(kind: .path,
                                                                row: row(5, .path, "P", members: [7]),
                                                                existingIDs: [6, 7]) else {
            return XCTFail("an all-existing path list is recallable")
        }
        XCTAssertEqual(paths, [7])
    }

    func testRecallRefusesMissingEmptyAndNoRow() {
        let entry = row(8, .layer, "L", count: 2, members: [3, 5])
        guard case .failure(let missing) = Logic.recallAdmission(kind: .layer, row: entry,
                                                                 existingIDs: [1, 3]) else {
            return XCTFail("a member no longer in the image refuses")
        }
        XCTAssertTrue(missing.message.contains("no longer"))
        // A layer row cannot be recalled as channels: kinds never mix.
        guard case .failure = Logic.recallAdmission(kind: .channel,
                                                    row: row(4, .layer, "L", members: [3, 5]),
                                                    existingIDs: [1, 3, 5]) else {
            return XCTFail("a layer set must not recall as channels")
        }
        guard case .failure(let empty) = Logic.recallAdmission(kind: .layer,
                                                               row: row(9, .layer, "E", members: []),
                                                               existingIDs: [1]) else {
            return XCTFail("an empty set refuses")
        }
        XCTAssertTrue(empty.message.contains("empty"))
        guard case .failure(let none) = Logic.recallAdmission(kind: .layer, row: nil,
                                                              existingIDs: [1]) else {
            return XCTFail("no selection refuses")
        }
        XCTAssertTrue(none.message.contains("Select"))
    }

    func testExistingIDsArePerKind() {
        let layers = [EngineSession.Layer(id: 1, parent: 0, depth: 0, kind: .pixel, name: "l",
                                          mode: "", isVisible: true, hasMask: false, isSelected: false,
                                          opacity: 1, bounds: .zero, filterCount: 0)]
        let channels = [EngineSession.Channel(id: 7, name: "c", isVisible: true, isSelected: false,
                                              isQuickMask: false, opacity: 1, color: .red)]
        let paths = [EngineSession.PathInfo(id: 3, name: "p", isVisible: true, isSelected: false)]
        XCTAssertEqual(Logic.existingIDs(ofKind: .layer, layers: layers, channels: channels, paths: paths), [1])
        XCTAssertEqual(Logic.existingIDs(ofKind: .channel, layers: layers, channels: channels, paths: paths), [7])
        XCTAssertEqual(Logic.existingIDs(ofKind: .path, layers: layers, channels: channels, paths: paths), [3])
    }

    // MARK: Phase machine

    func testPhaseTransitions() {
        typealias Phase = Logic.Phase
        XCTAssertEqual(Logic.beginMutation(.idle), .mutating)
        XCTAssertEqual(Logic.beginMutation(.mutating), .mutating,
                       "a reentrant mutation cannot start a second edit")
        XCTAssertEqual(Logic.mutationCompletion(.mutating), .idle)
        XCTAssertEqual(Logic.mutationCompletion(.idle), .idle, "a stale completion is ignored")
    }

    // MARK: Menu structure

    @MainActor
    func testViewMenuListsSavedSetsWithoutShortcut() {
        let menu = MainMenu.make()
        let view = menu.items.first { $0.title == "View" }?.submenu
        let item = view?.items.first { $0.title == "Saved Sets…" }
        XCTAssertEqual(item?.action, #selector(DocumentWindowController.showSavedSets(_:)))
        XCTAssertEqual(item?.keyEquivalent, "")
    }
}
