import AppKit
import XCTest
import RigiUI
@testable import GlimsKit

/// The Layers palette's row interactions without an engine: the visibility
/// checkbox and the inline name edit. A row keeps the document and layer it
/// was made for, so a rename cannot land on another document or on a layer
/// that went away while the name was being typed.
@MainActor
final class LayerRowEditingTests: XCTestCase {

    private func makeLayer(id: Int32 = 1, name: String = "Background",
                           kind: EngineSession.LayerKind = .pixel, depth: Int = 0,
                           isVisible: Bool = true, hasMask: Bool = false,
                           filterCount: Int = 0) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: 0, depth: depth, kind: kind, name: name, mode: "normal",
                            isVisible: isVisible, hasMask: hasMask, isSelected: false, opacity: 1,
                            bounds: .zero, filterCount: filterCount)
    }

    func testDisplayedLayerIdsSurviveReorderAndRejectRemovalOrRetarget() {
        let owner = NSObject()
        let first = makeLayer(id: 1), second = makeLayer(id: 2)
        let shown = LayerListSnapshot(document: owner, layers: [first, second])
        let firstItem = shown.tree.nodesByID[1], secondItem = shown.tree.nodesByID[2]
        XCTAssertEqual(shown.layer(for: firstItem, for: owner, currentLayers: [second, first])?.id, 1)
        XCTAssertNil(shown.layer(for: secondItem, for: owner, currentLayers: [first]))
        XCTAssertNil(shown.layer(for: firstItem, for: NSObject(), currentLayers: [first, second]))
        XCTAssertNil(shown.layer(for: nil, for: owner, currentLayers: [first, second]))
        XCTAssertNil(shown.layer(for: NSObject(), for: owner, currentLayers: [first, second]))
    }

    func testDisplayedLabIdentityStaysWithTheSnapshotAcrossAReusedLayerID() {
        let owner = NSObject(), first = UUID(), replacement = UUID()
        var identities: [Int32: UUID] = [7: first]
        let snapshot = LayerListSnapshot(document: owner, layers: [makeLayer(id: 7)],
                                         labIdentities: identities)
        identities[7] = replacement
        XCTAssertEqual(snapshot.labIdentity(for: 7), first)
        XCTAssertNotEqual(snapshot.labIdentity(for: 7), identities[7])
        XCTAssertNil(snapshot.labIdentity(for: 8))
        let context = LayerRowView.Context(document: owner, layerID: 7, labIdentity: snapshot.labIdentity(for: 7))
        XCTAssertEqual(context.labIdentity, first)
    }

    /// Records what a row tried to change and whether the document accepted.
    private final class Commit {
        var changes: [EngineSession.LayerChange] = []
        var contexts: [LayerRowView.Context] = []
        var accepted = true

        func call(_ context: LayerRowView.Context, _ change: EngineSession.LayerChange) -> Bool {
            contexts.append(context)
            changes.append(change)
            return accepted
        }
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, as: type) { return match }
        }
        return nil
    }

    private func visibilityChange(_ visible: Bool) -> EngineSession.LayerChange {
        var change = EngineSession.LayerChange()
        change.isVisible = visible
        return change
    }

    private func nameChange(_ name: String) -> EngineSession.LayerChange {
        var change = EngineSession.LayerChange()
        change.name = name
        return change
    }

    func testPaletteTableUsesTheRowHeightAndDoubleClick() {
        let controller = LayersPaletteController()
        _ = controller.view
        let outline = descendant(of: controller.view, as: NSOutlineView.self)

        XCTAssertEqual(outline?.rowHeight, LayerRowView.rowHeight)
        XCTAssertGreaterThanOrEqual(outline?.rowHeight ?? 0, 22)
        XCTAssertTrue(outline?.target === controller)
        XCTAssertNotNil(outline?.doubleAction)
    }

    func testTitleStillDescribesTheWholeRow() {
        XCTAssertEqual(LayersPaletteController.title(for: makeLayer()), "● Background")
        XCTAssertEqual(LayersPaletteController.detailsSuffix(for: makeLayer()), "")
        XCTAssertEqual(LayersPaletteController.title(for: makeLayer(name: "Set", kind: .group, depth: 1,
                                                                   isVisible: false, hasMask: true,
                                                                   filterCount: 2)),
                       "    ○ Set  (group, mask, 2 filters)")
        XCTAssertEqual(LayersPaletteController.detailsSuffix(for: makeLayer(kind: .text, hasMask: true,
                                                                            filterCount: 1)),
                       "  (text, mask, 1 filter)")
    }

    func testVisibilityCheckboxCommitsWhenAccepted() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(isVisible: false),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        row.checkbox.performClick(nil)

        XCTAssertEqual(commit.changes, [visibilityChange(true)])
        XCTAssertEqual(row.checkbox.state, .on)
    }

    func testRefusedVisibilityRevertsTheCheckbox() {
        let commit = Commit()
        commit.accepted = false
        let row = LayerRowView(layer: makeLayer(isVisible: false),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        row.checkbox.performClick(nil)

        XCTAssertEqual(commit.changes, [visibilityChange(true)])
        XCTAssertEqual(row.checkbox.state, .off)
    }

    func testNameCommitsOnEndEditingOnly() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        row.nameField.stringValue = "Renamed"
        XCTAssertTrue(commit.changes.isEmpty)

        row.finishNameEditing()
        XCTAssertEqual(commit.changes, [nameChange("Renamed")])
        XCTAssertEqual(row.nameField.stringValue, "Renamed")
    }

    func testEmptyAndUnchangedNamesDoNotCommit() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        row.nameField.stringValue = "   "
        row.finishNameEditing()
        XCTAssertTrue(commit.changes.isEmpty)
        XCTAssertEqual(row.nameField.stringValue, "Background")

        row.nameField.stringValue = "Background"
        row.finishNameEditing()
        XCTAssertTrue(commit.changes.isEmpty)
    }

    func testRenameTrimsWhitespaceAndTellsThePaletteWhenItEnds() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)
        var editEnded = 0
        row.onEditEnded = { editEnded += 1 }

        row.nameField.stringValue = "  Renamed  "
        XCTAssertEqual(editEnded, 0)
        row.finishNameEditing()

        XCTAssertEqual(commit.changes, [nameChange("Renamed")])
        XCTAssertEqual(editEnded, 1)
    }

    func testRefusedRenameRevertsTheField() {
        let commit = Commit()
        commit.accepted = false
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        row.nameField.stringValue = "Renamed"
        row.finishNameEditing()

        XCTAssertEqual(commit.changes, [nameChange("Renamed")])
        XCTAssertEqual(row.nameField.stringValue, "Background")
    }

    func testRenameTargetsTheRowItStartedOn() {
        let token = NSObject()
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(id: 7),
                               context: LayerRowView.Context(document: token, layerID: 7),
                               commit: commit.call)

        row.nameField.stringValue = "Renamed"
        row.finishNameEditing()

        XCTAssertTrue(commit.contexts.first?.document === token)
        XCTAssertEqual(commit.contexts.first?.layerID, 7)
    }

    func testChangeIsRefusedWhenTheDocumentOrLayerIsGone() {
        let token = NSObject()
        let context = LayerRowView.Context(document: token, layerID: 7)

        XCTAssertTrue(LayerRowView.canChange(context, document: token, layers: [makeLayer(id: 7)]))
        XCTAssertFalse(LayerRowView.canChange(context, document: NSObject(), layers: [makeLayer(id: 7)]))
        XCTAssertFalse(LayerRowView.canChange(context, document: token, layers: [makeLayer(id: 8)]))
        XCTAssertFalse(LayerRowView.canChange(context, document: nil, layers: [makeLayer(id: 7)]))
    }

    func testGroupRowsAllowVisibilityAndNameEditing() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(name: "Set", kind: .group),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)

        XCTAssertTrue(row.nameField.isEditable)
        XCTAssertTrue(row.checkbox.isEnabled)

        row.checkbox.performClick(nil)
        row.nameField.stringValue = "New Set"
        row.finishNameEditing()

        XCTAssertEqual(commit.changes, [visibilityChange(false), nameChange("New Set")])
    }

    func testRowIsAccessibleAndTallEnough() {
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: { _, _ in true })

        XCTAssertEqual(row.checkbox.accessibilityLabel(), "Hide Background")
        XCTAssertEqual(row.nameField.accessibilityLabel(), "Layer name")
        XCTAssertGreaterThanOrEqual(row.fittingSize.height, 22)
    }

    func testRenameDetectionFollowsTheFieldEditor() {
        _ = NSApplication.shared
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer")))
        outline.rowHeight = LayerRowView.rowHeight
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: { _, _ in true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = outline
        outline.addSubview(row)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertFalse(LayerRowView.isRenaming(in: outline))
        row.startEditingName()
        XCTAssertTrue(LayerRowView.isRenaming(in: outline))
        window.makeFirstResponder(nil)
        XCTAssertFalse(LayerRowView.isRenaming(in: outline))
    }

    func testDoubleClickStartsAndEndsANameEdit() {
        let commit = Commit()
        let row = LayerRowView(layer: makeLayer(),
                               context: LayerRowView.Context(document: NSObject(), layerID: 1),
                               commit: commit.call)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = row
        window.contentView?.layoutSubtreeIfNeeded()

        row.startEditingName()
        XCTAssertNotNil(row.nameField.currentEditor())
        XCTAssertTrue(commit.changes.isEmpty)

        row.nameField.currentEditor()?.string = "Renamed"
        window.makeFirstResponder(nil)

        XCTAssertEqual(commit.changes, [nameChange("Renamed")])
        XCTAssertEqual(row.nameField.stringValue, "Renamed")
    }

    func testInlineRenameTakesKeyboardFocusFromDocument() {
        _ = NSApplication.shared
        let documentWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        documentWindow.isReleasedWhenClosed = false
        let panel = ClassicPaletteWindow(contentSize: NSSize(width: 240, height: 100))
        let row = LayerRowView(layer: makeLayer(),
                               context: .init(document: NSObject(), layerID: 1),
                               commit: { _, _ in true })
        panel.contentView = row
        panel.orderFront(nil)
        documentWindow.makeKeyAndOrderFront(nil)
        defer { panel.close(); documentWindow.close() }
        row.startEditingName()
        XCTAssertTrue(panel.isKeyWindow, "typing a layer name must reach the palette rather than canvas shortcuts")
        XCTAssertNotNil(row.nameField.currentEditor())
    }

    func testLockBadgeAppearsOnlyWithEffectiveLocks() {
        let unlocked = LayerRowView(layer: makeLayer(),
                                    context: LayerRowView.Context(document: NSObject(), layerID: 1),
                                    locks: LayerTree.LockSources(),
                                    commit: { _, _ in true })
        XCTAssertNil(unlocked.lockView)

        var sources = LayerTree.LockSources()
        sources.local = [.pixels]
        sources.effective = [.pixels]
        let locked = LayerRowView(layer: makeLayer(),
                                  context: LayerRowView.Context(document: NSObject(), layerID: 1),
                                  locks: sources,
                                  commit: { _, _ in true })
        XCTAssertNotNil(locked.lockView)
        XCTAssertEqual(locked.lockView?.contentTintColor, .labelColor)
    }

    func testLockBadgeExplainsLocalInheritedAndDescendantLocks() {
        var sources = LayerTree.LockSources()
        sources.local = [.pixels]
        sources.inherited = [.position]
        sources.descendant = [.alpha]
        sources.effective = [.pixels, .position, .alpha]
        let accessibility = LayerRowView.lockAccessibility(sources, name: "Set")
        XCTAssertEqual(accessibility.label, "Locked: pixels, position, transparency")
        XCTAssertEqual(accessibility.help, "Set: locked pixels; position locked by a parent group; "
            + "a layer inside has locked transparency")
        XCTAssertEqual(LayerRowView.lockNames([.position, .alpha]), "position, transparency")
    }
}
