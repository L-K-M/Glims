import AppKit

/// `GLIMS_SMOKE_CASE=path-menus` (wired by root, also in the full
/// suite): Edit ▸ New Path / Delete Path driven through the real
/// `NSApp.mainMenu` items and `NSApp.sendAction` to the owning
/// `DocumentWindowController`. The items must sit beside Stroke Path /
/// Fill Path on the document's `newPath:` / `deletePath:` selectors —
/// looked up by name, never `#selector`, so this file compiles before
/// the production methods exist — be collected by
/// `MenuShortcutBridge` as `newPath:#0` / `deletePath:#0`, validate
/// from cached state only, and create or delete through the captured
/// document, never the front window's. Native path lists, selection,
/// undo counts and Undo/Redo prove the edits; a floating selection
/// must not gate path commands.
@MainActor
extension EngineSmokeTest {
    static func exercisePathMenus(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.03)
        }
        func send(_ item: NSMenuItem, to controller: DocumentWindowController) {
            if let action = item.action { NSApp.sendAction(action, to: controller, from: item) }
        }

        // Two documents; B's window stays front while every action is
        // sent explicitly to A's controller.
        let imageA = try session.newImage(width: 64, height: 64)
        let imageB = try session.newImage(width: 64, height: 64)
        let docA = try ImageDocument(session: session, image: imageA, name: "Path Menu A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Path Menu B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        b.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        let previousErrorA = docA.onError
        docA.onError = { errorsA.append($0) }
        defer {
            docA.onError = previousErrorA
            for controller in [a, b] {
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
            }
            for document in [docA, docB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            for controller in [a, b] { controller.window?.close() }
            documents.items.removeAll { $0 === docA || $0 === docB }
            check((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                  "both path-menu images drain and close before engine shutdown")
        }
        settle(docA)
        settle(docB)

        // MARK: Menu presence, routing and the shortcut catalog
        guard let menu = NSApp.mainMenu,
              let edit = menu.item(withTitle: "Edit")?.submenu else {
            return check(false, "the application Edit menu exists")
        }
        let newItem = edit.items.first { $0.title == "New Path" }
        let deleteItem = edit.items.first { $0.title == "Delete Path" }
        check(newItem != nil && deleteItem != nil,
              "Edit lists New Path and Delete Path beside Stroke Path/Fill Path")
        guard let newItem, let deleteItem else { return }
        let newSelector = NSSelectorFromString("newPath:")
        let deleteSelector = NSSelectorFromString("deletePath:")
        check(newItem.action == newSelector && deleteItem.action == deleteSelector
                && newItem.target == nil && deleteItem.target == nil,
              "the items sit on newPath:/deletePath: and route through the responder chain")
        let titles = edit.items.map(\.title)
        if let strokeIndex = titles.firstIndex(of: "Stroke Path"),
           let newIndex = titles.firstIndex(of: "New Path"),
           let deleteIndex = titles.firstIndex(of: "Delete Path") {
            check(newIndex < strokeIndex && deleteIndex < strokeIndex,
                  "the path lifecycle items precede Stroke Path in Edit")
        } else {
            check(false, "Stroke Path anchors the path command group in Edit")
        }
        let collection = MenuShortcutBridge.collect(from: menu)
        check(collection.byID["newPath:#0"]?.contains(where: { $0.item === newItem }) == true
                && collection.byID["deletePath:#0"]?.contains(where: { $0.item === deleteItem }) == true
                && collection.errors.isEmpty && collection.catalog != nil,
              "the shortcut catalog collects newPath:#0 and deletePath:#0 automatically")

        // Independently obtain the default name through the existing palette,
        // including the native locale, then return B to its empty-path state.
        let palette = PathsPaletteController()
        palette.retarget(to: docB)
        palette.run(.new)
        settle(docB)
        guard let defaultName = (try session.paths(imageB)).first?.name else {
            return check(false, "the existing palette creates the default reference path")
        }
        palette.run(.delete)
        settle(docB)
        let undoBBefore = docB.undoInfo.undoCount

        // MARK: Empty selection gates Delete Path only
        check(!a.validateMenuItem(deleteItem) && a.validateMenuItem(newItem),
              "with no path selected Delete Path disables while New Path stays enabled")

        // A named fixture proves the menu's default name is the
        // engine's, never copied from an existing path; deselecting it
        // leaves paths present with an empty path selection.
        let fixtureShape = VectorPath(subpaths: [.init(anchors: [
            .init(CGPoint(x: 6, y: 6)), .init(CGPoint(x: 30, y: 30))])])
        guard let kept = docA.addPath(fixtureShape) else {
            return check(false, "the fixture path is created")
        }
        docA.renamePath(kept, to: "Kept Path")
        settle(docA)
        try session.selectItems([], kind: .path, image: imageA)
        try docA.reload()
        settle(docA)
        check(docA.paths.count == 1 && docA.paths.first?.name == "Kept Path"
                && docA.selectedPathIDs.isEmpty && docA.activePath == nil
                && !a.validateMenuItem(deleteItem),
              "an empty path selection keeps Delete Path disabled")
        let undoBeforeEmptySelect = docA.undoInfo.undoCount
        send(deleteItem, to: a)
        settle(docA)
        check(docA.paths.count == 1 && docA.undoInfo.undoCount == undoBeforeEmptySelect,
              "Delete Path with an empty selection edits nothing")

        // MARK: New Path through the real menu action
        let undoBeforeNew = docA.undoInfo.undoCount
        send(newItem, to: a)
        settle(docA)
        guard let madeID = docA.activePath, madeID != kept,
              let made = docA.paths.first(where: { $0.id == madeID }) else {
            return check(false, "New Path creates and selects a path")
        }
        let nativeNewPaths = try session.paths(imageA)
        let nativeNewSelection = try session.selectedItems(.path, image: imageA)
        let nativeNewUndo = try session.undoInfo(imageA)
        check(docA.paths.count == 2 && docA.selectedPathIDs == [madeID]
                && docA.undoInfo.undoCount == undoBeforeNew + 1
                && nativeNewPaths == docA.paths && nativeNewSelection == [madeID]
                && nativeNewUndo.undoCount == undoBeforeNew + 1
                && made.name == defaultName
                && (try? session.path(madeID, image: imageA)) == VectorPath(),
              "New Path adds one selected path — engine default name, empty shape, one undo step")
        check(docB.paths.isEmpty && docB.undoInfo.undoCount == undoBBefore && docB.pendingWork == 0,
              "front document B is unchanged by A's New Path")
        docA.undo()
        settle(docA)
        check(docA.paths.map(\.id) == [kept]
                && (try? session.paths(imageA))?.map(\.id) == [kept],
              "undo takes back the menu-created path")
        docA.redo()
        settle(docA)
        check(docA.paths.count == 2 && docA.paths.contains { $0.id == madeID },
              "redo restores the menu-created path")

        // MARK: Delete Path through the real menu action
        docA.selectPath(madeID)
        settle(docA)
        check(docA.activePath == madeID && docA.selectedPathIDs == [madeID]
                && a.validateMenuItem(deleteItem),
              "a single selected path enables Delete Path")
        let undoBeforeDelete = docA.undoInfo.undoCount
        send(deleteItem, to: a)
        settle(docA)
        let nativeDeletedPaths = try session.paths(imageA)
        let nativeDeleteUndo = try session.undoInfo(imageA)
        check(docA.paths.map(\.id) == [kept] && docA.activePath != madeID
                && docA.undoInfo.undoCount == undoBeforeDelete + 1
                && nativeDeletedPaths.map(\.id) == [kept]
                && nativeDeleteUndo.undoCount == undoBeforeDelete + 1,
              "Delete Path removes the active path as one undo step")
        docA.undo()
        settle(docA)
        check(docA.paths.contains { $0.id == madeID }, "undo restores the deleted path")
        docA.redo()
        settle(docA)
        check(docA.paths.map(\.id) == [kept], "redo deletes it again")

        // MARK: Two-path selection disables Delete Path only
        send(newItem, to: a)
        settle(docA)
        guard let secondID = docA.activePath, secondID != kept else {
            return check(false, "a second menu-created path exists")
        }
        try session.selectItems([kept, secondID], kind: .path, image: imageA)
        try docA.reload()
        settle(docA)
        check(docA.selectedPathIDs.count == 2 && docA.activePath == nil
                && docA.hasMultipleSelectedPaths
                && !a.validateMenuItem(deleteItem) && a.validateMenuItem(newItem),
              "two selected paths: no active path, Delete disabled, New enabled")
        let undoBeforeMulti = docA.undoInfo.undoCount
        send(deleteItem, to: a)
        settle(docA)
        check(docA.paths.count == 2 && docA.undoInfo.undoCount == undoBeforeMulti
                && Set(docA.selectedPathIDs) == Set([kept, secondID]),
              "Delete Path under a two-path selection edits nothing")
        docA.selectPath(kept)
        settle(docA)
        check(docA.activePath == kept && docA.selectedPathIDs == [kept]
                && a.validateMenuItem(deleteItem),
              "a single pick resolves the selection and re-enables Delete Path")

        // MARK: Busy gate reads cached state only
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Path menu busy hold", work: {
            ready.signal()
            _ = releaseHold.wait(timeout: .now() + 30)
        }, completion: {})
        var holdStarted = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !holdStarted && Date() < holdDeadline {
            holdStarted = ready.wait(timeout: .now()) == .success
            if !holdStarted { spin(0.01) }
        }
        check(held && holdStarted && !a.validateMenuItem(newItem) && !a.validateMenuItem(deleteItem),
              "while the engine is busy both path items disable from cached state")
        releaseHold.signal()
        wait { !EngineActivity.shared.isBusy }
        spin(0.05)

        // MARK: A floating selection does not gate path commands
        try session.select(.all, image: imageA)
        try docA.reload()
        docA.refreshSelection()
        settle(docA)
        let readiness = docA.floatReadiness(.copy)
        guard let drawable = readiness.drawable else {
            return check(false, "the float fixture is ready (\(readiness.reason ?? "refused"))")
        }
        var floated: Result<Void, Error>?
        docA.floatSelectedPixels(mode: .copy, target: drawable) { floated = $0 }
        wait { floated != nil }
        settle(docA)
        check(docA.floatingState.isActive
                && a.validateMenuItem(newItem) && a.validateMenuItem(deleteItem),
              "a floating selection leaves both path items enabled")
        let pathsBeforeFloat = docA.paths.count
        send(newItem, to: a)
        settle(docA)
        check(docA.paths.count == pathsBeforeFloat + 1 && docA.floatingState.isActive,
              "New Path still creates under a floating selection")
        send(deleteItem, to: a)
        settle(docA)
        check(docA.paths.count == pathsBeforeFloat && docA.floatingState.isActive,
              "Delete Path still deletes under a floating selection")
        var anchored: Result<Void, Error>?
        docA.resolveFloatingSelection(.anchor) { anchored = $0 }
        wait { anchored != nil }
        settle(docA)
        check(!docA.floatingState.isActive, "the floating selection anchors afterwards")

        // MARK: Actions route to the captured controller's document only
        let aPathsBefore = docA.paths.count
        send(newItem, to: b)
        settle(docB)
        check(docB.paths.count == 1 && docB.activePath != nil,
              "New Path sent to B's controller creates in B")
        send(deleteItem, to: b)
        settle(docB)
        check(docB.paths.isEmpty && docA.paths.count == aPathsBefore && errorsA.isEmpty,
              "Delete Path sent to B's controller removes only B's path")

        var stopped = false
        a.canvas.stopRendering { stopped = true }
        wait { stopped }
        var closed = false
        docA.closeImageWhenDrained { closed = true }
        check(!a.validateMenuItem(newItem) && !a.validateMenuItem(deleteItem),
              "both path menu commands disable as their captured document closes")
        wait { closed }
        check(closed && (try? session.info(imageA)) == nil,
              "the path-menu document completes its close drain")
    }
}
