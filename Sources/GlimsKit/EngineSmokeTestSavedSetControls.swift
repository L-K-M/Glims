import AppKit
import RigiUI

/// `GLIMS_SMOKE_CASE=saved-set-controls` (wired by root, also in the full
/// suite): View ▸ Saved Sets… driven through the real menu item and the
/// real non-modal panel on the captured document, with independent native
/// slot-133/134 readback. Covers all three kinds' CRUD, the live-count
/// readback, Undo/Redo, the no-op replace, the stale-token and foreign-
/// document refusals, the explicit empty capture with no selection (never
/// a fake all-items list), layer and channel recall as exact lists, inline
/// name errors, the busy
/// gate, two-document capture with the other window front, pixel
/// preservation, panel and host-window close invalidation, and close drain
/// with exactly-one completion. Lookups go through accessibility labels.
@MainActor
extension EngineSmokeTest {
    static func exerciseSavedSetControls(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            found += root.subviews.flatMap { allViews($0, as: type) }
            return found
        }
        func button(_ panel: NSWindow?, _ label: String) -> NSButton? {
            allViews(panel?.contentView, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func editableField(_ panel: NSWindow?, _ label: String) -> NSTextField? {
            allViews(panel?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func popup(_ panel: NSWindow?, _ label: String) -> NSPopUpButton? {
            allViews(panel?.contentView, as: NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func table(_ panel: NSWindow?) -> NSTableView? {
            allViews(panel?.contentView, as: NSTableView.self)
                .first { $0.accessibilityLabel() == "Saved sets table" }
        }
        func send(_ item: NSMenuItem?, to controller: DocumentWindowController) {
            if let item, let action = item.action { NSApp.sendAction(action, to: controller, from: item) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func settlePanel(_ document: ImageDocument, _ panel: SavedSetPanelController) {
            settle(document)
            wait { panel.phase == .idle }
            spin()
        }
        func setKind(_ panel: SavedSetPanelController, _ popup: NSPopUpButton,
                     _ kind: EngineSession.ItemSetKind) {
            popup.selectItem(at: SavedSetControlsLogic.kinds.firstIndex { $0.0 == kind } ?? 0)
            panel.kindChanged(popup)
            spin(0.05)
        }
        func selectRow(_ panel: SavedSetPanelController, _ tableView: NSTableView, _ row: Int) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            panel.tableViewSelectionDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                           object: tableView))
        }
        func cell(_ panel: SavedSetPanelController, _ tableView: NSTableView,
                  _ row: Int, _ column: NSTableColumn) -> String? {
            panel.tableView(tableView, objectValueFor: column, row: row) as? String
        }
        func row(named name: String, in panel: SavedSetPanelController, _ tableView: NSTableView) -> Int? {
            for row in 0..<panel.numberOfRows(in: tableView) where cell(panel, tableView, row, panel.nameColumn) == name {
                return row
            }
            return nil
        }
        func layerSets(_ image: Int32) throws -> [EngineSession.ItemSet] {
            try session.itemSets(image).filter { $0.kind == .layer }
        }

        // Fixtures: document A with three layers, one saved channel and two
        // paths; document B plain. B's window stays front the whole time.
        let imageA = try session.newImage(width: 64, height: 64)
        let docA = try ImageDocument(session: session, image: imageA, name: "Sets A")
        documents.items.append(docA)
        let a = DocumentWindowController(document: docA)
        a.showWindow(nil)
        let imageB = try session.newImage(width: 32, height: 32)
        let docB = try ImageDocument(session: session, image: imageB, name: "Sets B")
        documents.items.append(docB)
        let b = DocumentWindowController(document: docB)
        b.showWindow(nil)
        b.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        let previousErrorA = docA.onError
        docA.onError = { message in previousErrorA?(message); errorsA.append(message) }
        defer {
            for controller in [a, b] {
                controller.savedSetPanel?.window?.orderOut(nil)
                controller.window?.orderOut(nil)
            }
            spin()
            documents.items.removeAll { $0 === docA || $0 === docB }
            for document in [docA, docB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            check((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                  "both saved-set images drain and close before engine shutdown")
        }

        guard let bg = docA.activeLayer else {
            check(false, "document A has a background layer")
            return
        }
        docA.layerCommand(.new)
        settle(docA)
        guard let l1 = docA.activeLayer, l1 != bg else {
            check(false, "layer l1 created")
            return
        }
        docA.layerCommand(.new)
        settle(docA)
        guard let l2 = docA.activeLayer, l2 != l1 else {
            check(false, "layer l2 created")
            return
        }
        try session.select(.all, image: imageA)
        let channel = try session.channelFromSelection(imageA, name: "Area")
        try session.select(.none, image: imageA)
        try session.channelCommand(.select, channel: 0, image: imageA)
        let shape = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 5, y: 5)), .init(CGPoint(x: 20, y: 20))])])
        guard let p1 = docA.addPath(shape), let p2 = docA.addPath(shape) else {
            check(false, "two paths created")
            return
        }
        docA.selectPath(p1)
        settle(docA)
        docA.selectLayer(bg)
        settle(docA)
        let pixelsBeforeManagement = try session.copyPixels(imageA, merged: true).pixels
        let undoBefore = docA.undoInfo.undoCount

        // Menu wiring: View ▸ Saved Sets… sits on the document's own
        // selector, no shortcut, and validates while no panel is open.
        let viewItem = MainMenu.make().items.first { $0.title == "View" }?.submenu?
            .items.first { $0.title == "Saved Sets…" }
        check(viewItem?.action == #selector(DocumentWindowController.showSavedSets(_:)),
              "View offers Saved Sets… on the document's selector")
        check(viewItem?.keyEquivalent == "", "Saved Sets… has no shortcut")
        check(a.validateMenuItem(viewItem!), "Saved Sets… validates with no panel open")

        // The panel opens on A's captured document while B is front.
        send(viewItem, to: a)
        spin(0.05)
        guard let panel = a.savedSetPanel, let panelWindow = panel.window,
              let tableView = table(panelWindow), let kindPopup = popup(panelWindow, "Saved set kind"),
              let nameField = editableField(panelWindow, "Saved set name") else {
            check(false, "the panel opens on A with its controls")
            return
        }
        check(panel.imageDocument === docA && b.savedSetPanel == nil,
              "the panel captures A, not the front window's B")
        check(!a.validateMenuItem(viewItem!), "the item disables while A's panel is open")
        settlePanel(docA, panel)
        check(panel.numberOfRows(in: tableView) == 0, "a fresh image lists no saved sets")
        check(button(panelWindow, "New from selection") != nil
                && button(panelWindow, "Replace with selection") != nil
                && button(panelWindow, "Rename saved set") != nil
                && button(panelWindow, "Delete saved set") != nil
                && button(panelWindow, "Recall saved set") != nil
                && button(panelWindow, "Close saved sets panel") != nil,
              "the panel shows all management buttons with accessibility labels")
        check(button(panelWindow, "Replace with selection")?.isEnabled == false
                && button(panelWindow, "Recall saved set")?.isEnabled == false,
              "row-bound buttons disable with no selection")

        // CREATE, layer kind, from the explicit current selection [l2, l1].
        docA.selectLayers([l2, l1])
        settle(docA)
        setKind(panel, kindPopup, .layer)
        nameField.stringValue = "Layers A"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        var sets = try layerSets(imageA)
        check(sets.count == 1 && sets[0].displayName == "Layers A" && sets[0].memberCount == 2,
              "CREATE lists one layer set with the live count 2 (\(sets.map { "\($0.displayName):\($0.memberCount)" }))")
        guard let tokenA = sets.first?.token, tokenA != 0 else {
            check(false, "CREATE minted a fresh nonzero token")
            return
        }
        check((try session.itemSetMembers(imageA, token: tokenA)) == [l2, l1],
              "the captured selection is stored exactly, in order")
        check(panel.numberOfRows(in: tableView) == 1
                && cell(panel, tableView, 0, panel.nameColumn) == "Layers A"
                && cell(panel, tableView, 0, panel.countColumn) == "2"
                && panel.selectedToken == tokenA,
              "the table shows the label and live count bound to the current token")
        check(docA.undoInfo.undoCount == undoBefore + 1, "CREATE is one undo step")

        // CREATE, channel kind, from the actual isSelected query.
        try session.channelCommand(.select, channel: channel, image: imageA)
        let expectedChannels = try session.channels(imageA).filter(\.isSelected).map(\.id)
        check(expectedChannels == [channel], "the fixture selected exactly the saved channel")
        setKind(panel, kindPopup, .channel)
        nameField.stringValue = "Chan A"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        let channelSets = try session.itemSets(imageA).filter { $0.kind == .channel }
        check(channelSets.count == 1 && channelSets[0].displayName == "Chan A",
              "CREATE lists the channel set")
        if let channelToken = channelSets.first?.token {
            check((try session.itemSetMembers(imageA, token: channelToken)) == expectedChannels,
                  "the channel capture is the actual isSelected ids, not all items")
        } else { check(false, "the channel set has a token") }

        // CREATE, path kind.
        docA.selectPath(p1)
        settle(docA)
        let expectedPaths = try session.paths(imageA).filter(\.isSelected).map(\.id)
        setKind(panel, kindPopup, .path)
        nameField.stringValue = "Path A"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        let pathSets = try session.itemSets(imageA).filter { $0.kind == .path }
        check(pathSets.count == 1 && pathSets[0].displayName == "Path A", "CREATE lists the path set")
        if let pathToken = pathSets.first?.token {
            check((try session.itemSetMembers(imageA, token: pathToken)) == expectedPaths,
                  "the path capture is the actual isSelected ids")
        } else { check(false, "the path set has a token") }
        check(p2 != p1, "two distinct paths exist")

        // REPLACE with the current selection [bg]: fresh token, the old one
        // expires for good (NOT_FOUND, never retargeted).
        setKind(panel, kindPopup, .layer)
        settlePanel(docA, panel)
        selectRow(panel, tableView, row(named: "Layers A", in: panel, tableView) ?? 0)
        docA.selectLayers([bg])
        settle(docA)
        let undoBeforeReplace = try session.undoInfo(imageA).undoCount
        button(panelWindow, "Replace with selection")?.performClick(nil)
        settlePanel(docA, panel)
        sets = try layerSets(imageA)
        guard let tokenAfterReplace = sets.first?.token else {
            check(false, "the replaced set is listed")
            return
        }
        check((try session.itemSetMembers(imageA, token: tokenAfterReplace)) == [bg]
                && sets[0].memberCount == 1,
              "REPLACE stores the new explicit members with a live count 1")
        check(tokenAfterReplace != tokenA && (try? session.itemSetMembers(imageA, token: tokenA)) == nil,
              "REPLACE expires the old token (stale read is NOT_FOUND, never retargeted)")
        check(panel.selectedToken == tokenAfterReplace
                && cell(panel, tableView, row(named: "Layers A", in: panel, tableView) ?? 0, panel.countColumn) == "1",
              "the table binds the fresh token and its live count")
        check(docA.undoInfo.undoCount == undoBeforeReplace + 1, "REPLACE is one undo step")

        // No-op REPLACE (identical members): OK, same token, no undo step.
        let undoBeforeNoop = docA.undoInfo.undoCount
        selectRow(panel, tableView, row(named: "Layers A", in: panel, tableView) ?? 0)
        button(panelWindow, "Replace with selection")?.performClick(nil)
        settlePanel(docA, panel)
        check((try layerSets(imageA).first?.token) == tokenAfterReplace
                && docA.undoInfo.undoCount == undoBeforeNoop,
              "an identical REPLACE is a no-op: same token, no undo step")

        // RENAME: the draft is never seeded from the row's (possibly
        // truncated) display label; the full new name is typed.
        nameField.stringValue = ""
        selectRow(panel, tableView, row(named: "Layers A", in: panel, tableView) ?? 0)
        check(nameField.stringValue == "", "selecting a row does not seed the rename draft from the label")
        nameField.stringValue = "Layers A2"
        let undoBeforeRename = try session.undoInfo(imageA).undoCount
        button(panelWindow, "Rename saved set")?.performClick(nil)
        settlePanel(docA, panel)
        sets = try layerSets(imageA)
        guard let tokenAfterRename = sets.first?.token else {
            check(false, "the renamed set is listed")
            return
        }
        let renamedMembers = try session.itemSetMembers(imageA, token: tokenAfterRename)
        check(sets.first?.displayName == "Layers A2"
                && renamedMembers == [bg]
                && tokenAfterRename != tokenAfterReplace
                && (try? session.itemSetMembers(imageA, token: tokenAfterReplace)) == nil,
              "RENAME applies the full new name, keeps members, expires the old token")
        check(docA.undoInfo.undoCount == undoBeforeRename + 1, "RENAME is one undo step")
        check(cell(panel, tableView, row(named: "Layers A2", in: panel, tableView) ?? 0, panel.nameColumn) == "Layers A2",
              "the table shows the new label")

        // Undo/Redo of the set edit: the list follows, with fresh tokens.
        docA.undo()
        settle(docA)
        wait { cell(panel, tableView, 0, panel.nameColumn) == "Layers A" }
        spin()
        check((try layerSets(imageA).first?.displayName) == "Layers A",
              "Undo restores the pre-rename set under a fresh token")
        docA.redo()
        settle(docA)
        wait { cell(panel, tableView, 0, panel.nameColumn) == "Layers A2" }
        spin()
        check((try layerSets(imageA).first?.displayName) == "Layers A2", "Redo reapplies the rename")
        guard let currentToken = try layerSets(imageA).first?.token else {
            check(false, "the redone set is listed")
            return
        }

        // Recall, layer kind: an exact selectLayers list.
        docA.selectLayers([l2, l1])
        settle(docA)
        setKind(panel, kindPopup, .layer)
        nameField.stringValue = "Recall"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        guard let recallRow = row(named: "Recall", in: panel, tableView) else {
            check(false, "the Recall set is listed")
            return
        }
        docA.selectLayers([bg])
        settle(docA)
        selectRow(panel, tableView, recallRow)
        check(button(panelWindow, "Recall saved set")?.isEnabled == true,
              "layer recall enables with an existing exact list")
        button(panelWindow, "Recall saved set")?.performClick(nil)
        settle(docA)
        check((try session.selectedLayers(imageA)) == [l2, l1],
              "layer recall selects exactly the stored member list")

        // A stale table must not turn an expired set into a cached list of
        // otherwise valid layer IDs. Suppress automatic view refresh only;
        // the real button and native operation remain unchanged.
        docA.selectLayers([bg])
        settle(docA)
        selectRow(panel, tableView, row(named: "Recall", in: panel, tableView) ?? recallRow)
        guard let staleRecallToken = panel.selectedToken else {
            check(false, "the stale-recall fixture has a selected token")
            return
        }
        let stateCallback = docA.onStateChange
        docA.onStateChange = nil
        defer { docA.onStateChange = stateCallback }
        _ = try session.editItemSet(imageA, .remove, kind: .layer, token: staleRecallToken)
        check(panel.selectedToken == staleRecallToken,
              "the table intentionally retains the now-expired recall token")
        if let recall = button(panelWindow, "Recall saved set"), let action = recall.action {
            NSApp.sendAction(action, to: recall.target, from: recall)
        }
        settlePanel(docA, panel)
        check((try session.selectedLayers(imageA)) == [bg],
              "recalling an expired token refuses without selecting cached layer IDs")
        check(panel.lastError != nil, "stale recall reports the refusal in the captured panel")
        docA.onStateChange = stateCallback
        panel.reload()
        settlePanel(docA, panel)
        docA.selectLayers([l2, l1])
        settle(docA)

        // Recall enabled for channel kind too: an exact slot-136/137
        // selection of the stored members, no take-first.
        setKind(panel, kindPopup, .channel)
        settlePanel(docA, panel)
        if let chanRow = row(named: "Chan A", in: panel, tableView) {
            selectRow(panel, tableView, chanRow)
            check(button(panelWindow, "Recall saved set")?.isEnabled == true,
                  "channel recall enables with an existing exact list")
            button(panelWindow, "Recall saved set")?.performClick(nil)
            settlePanel(docA, panel)
            check((try session.selectedItems(.channel, image: imageA)) == expectedChannels,
                  "channel recall selects exactly the stored member list")
            check(docA.selectedChannelIDs == expectedChannels && docA.activeChannel == expectedChannels.first,
                  "the cached channel selection mirrors the native read-back, single target active")
        } else { check(false, "the channel set is listed for the recall check") }
        try session.channelCommand(.select, channel: 0, image: imageA)
        settle(docA)

        // Management changes no pixels.
        check((try session.copyPixels(imageA, merged: true).pixels) == pixelsBeforeManagement,
              "saved-set management changes no image pixels")

        // LIVE counts: a set over [bg, l1] drops to 1 when l1 is deleted.
        docA.selectLayers([bg, l1])
        settle(docA)
        setKind(panel, kindPopup, .layer)
        nameField.stringValue = "Live"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        guard let liveRow = row(named: "Live", in: panel, tableView),
              let liveToken = try layerSets(imageA).first(where: { $0.displayName == "Live" })?.token else {
            check(false, "the Live set is listed with 2 members")
            return
        }
        check((try session.itemSetMembers(imageA, token: liveToken)) == [bg, l1]
                && cell(panel, tableView, liveRow, panel.countColumn) == "2",
              "the Live set lists both members")
        docA.selectLayer(l1)
        docA.layerCommand(.delete)
        settle(docA)
        wait { cell(panel, tableView, row(named: "Live", in: panel, tableView) ?? liveRow, panel.countColumn) == "1" }
        spin()
        let liveMembers = try session.itemSetMembers(imageA, token: liveToken)
        let liveCount = try session.itemSets(imageA).first { $0.token == liveToken }?.memberCount
        check(liveMembers == [bg] && liveCount == 1,
              "the count is LIVE: a deleted member drops out of the stored set")

        // No selection captured explicitly as EMPTY (never all items).
        try session.channelCommand(.select, channel: 0, image: imageA)
        setKind(panel, kindPopup, .channel)
        settlePanel(docA, panel)
        nameField.stringValue = "Empty C"
        button(panelWindow, "New from selection")?.performClick(nil)
        settlePanel(docA, panel)
        let emptySets = try session.itemSets(imageA).filter { $0.kind == .channel && $0.displayName == "Empty C" }
        check(emptySets.count == 1 && emptySets[0].memberCount == 0
                && (try? session.itemSetMembers(imageA, token: emptySets[0].token)) == [],
              "a no-selection capture creates an explicit EMPTY set, not all channels")

        // Inline name errors refuse before anything queues.
        setKind(panel, kindPopup, .layer)
        settlePanel(docA, panel)
        let setsBeforeErrors = try session.itemSets(imageA).count
        let workBeforeErrors = docA.pendingWork
        for bad in ["", "bad\u{01}name", String(repeating: "a", count: 256)] {
            nameField.stringValue = bad
            button(panelWindow, "New from selection")?.performClick(nil)
            spin(0.05)
            check(panel.lastError != nil && docA.pendingWork == workBeforeErrors,
                  "an invalid name '\(bad.prefix(8))' is refused inline with nothing queued")
        }
        check((try session.itemSets(imageA).count) == setsBeforeErrors, "the refused names created nothing")

        // Busy: the cached gate disables the buttons and refuses a press
        // before acceptance, queueing nothing.
        let hold = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Saved sets busy hold", work: {
            ready.signal()
            _ = hold.wait(timeout: .now() + 30)
        }, completion: {})
        wait { ready.wait(timeout: .now()) == .success }
        check(held, "the exclusive hold is running")
        spin(0.1)
        check(button(panelWindow, "New from selection")?.isEnabled == false,
              "the mutation buttons disable from cache while the engine is busy")
        let workBeforeBusy = docA.pendingWork
        nameField.stringValue = "Busy Set"
        button(panelWindow, "New from selection")?.performClick(nil)
        spin(0.05)
        check(docA.pendingWork == workBeforeBusy && panel.lastError != nil,
              "New while busy is refused before acceptance with nothing queued")
        hold.signal()
        wait { !EngineActivity.shared.isBusy }
        spin(0.1)
        check(button(panelWindow, "New from selection")?.isEnabled == true, "the buttons re-enable when idle")
        check((try? session.itemSets(imageA).contains { $0.displayName == "Busy Set" }) == false,
              "the busy-refused New created nothing")

        // Stale token (expired by the REPLACE above): NOT_FOUND, and the
        // current catalog is untouched.
        let tokensBeforeStale = try session.itemSets(imageA).map(\.token).sorted()
        var staleResult: Result<UInt64, Error>?
        docA.editSavedSet(ImageDocument.SavedSetEditRequest(
            operation: .rename, kind: .layer, token: tokenA, name: "Nope",
            members: [], captureSelection: false)) { staleResult = $0 }
        wait { staleResult != nil }
        if case .failure = staleResult {} else { check(false, "a stale token fails through the completion") }
        check(staleResult != nil, "the stale-token completion landed")
        check((try session.itemSets(imageA).map(\.token).sorted()) == tokensBeforeStale,
              "the stale-token refusal changed nothing")

        // Foreign document: A's current token applied to B is refused and B
        // keeps no sets — no retarget, no front-doc fallback.
        var foreignResult: Result<UInt64, Error>?
        docB.editSavedSet(ImageDocument.SavedSetEditRequest(
            operation: .rename, kind: .layer, token: currentToken, name: "Nope",
            members: [], captureSelection: false)) { foreignResult = $0 }
        wait { foreignResult != nil }
        if case .failure = foreignResult {} else { check(false, "a foreign-document token is refused NOT_FOUND") }
        check((try session.itemSets(imageB)).isEmpty, "document B's saved sets stay empty")

        // The panel's own window close invalidates it and clears the host.
        panelWindow.close()
        spin(0.1)
        check(panel.isInvalidated && a.savedSetPanel == nil,
              "closing the panel invalidates it and clears the window's reference")

        // Host window close on the clean document B invalidates its panel.
        send(viewItem, to: b)
        spin(0.05)
        guard let panelB = b.savedSetPanel else {
            check(false, "B's panel opens for the host-close check")
            return
        }
        check(panelB.imageDocument === docB, "B's panel captures B")
        var bClosed = false
        b.onClose = { _ in bClosed = true }
        b.window?.close()
        wait { bClosed }
        check(panelB.isInvalidated && b.savedSetPanel == nil,
              "the host window close invalidated its panel; no stale UI resurrects")
        check((try? session.info(imageB)) == nil, "B's image drained and closed")

        // Close drain with exactly-one completion on A: the accepted edit is
        // counted, the close waits for the whole job including its callback.
        docA.selectLayers([l2])
        settle(docA)
        var drainCompletions = 0
        let workBeforeDrain = docA.pendingWork
        docA.editSavedSet(ImageDocument.SavedSetEditRequest(
            operation: .create, kind: .layer, token: 0, name: "Drain Set",
            members: [], captureSelection: true)) { _ in drainCompletions += 1 }
        check(docA.pendingWork >= workBeforeDrain + 1, "the accepted edit is counted as pending work")
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        wait { closedA }
        check(drainCompletions == 1, "the completion ran exactly once through the close drain")
        check((try? session.info(imageA)) == nil, "A's image destroyed only after the drain")
        var lateResult: Result<UInt64, Error>?
        docA.editSavedSet(ImageDocument.SavedSetEditRequest(
            operation: .create, kind: .layer, token: 0, name: "Late Set",
            members: [], captureSelection: true)) { lateResult = $0 }
        check(lateResult != nil, "an edit requested after close fails through its callback without crashing")
    }
}
