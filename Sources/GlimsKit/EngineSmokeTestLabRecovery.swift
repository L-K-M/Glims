import AppKit
import CGlimsEngine
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseLabRecovery(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-recovery: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LabRecoverySmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(20)
            while !ready() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            EngineSmokeTestHost.pumpEvents()
            try require(ready(), message)
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "LabRecoverySmoke", code: 2)
            }
            return data
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        let app = AppController(), oldTool = ToolState.shared.current
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        var nativeOnly: [Int32] = [], adopted: [ImageDocument] = []
        defer {
            do { try wait({ app.inFlightRecoveries.isEmpty && !EngineActivity.shared.isBusy }, "Recovery admission drains for cleanup") }
            catch { expect(false, "recovery cleanup admission: \(error)") }
            app.recoveryPanel?.onRecover = nil
            app.recoveryPanel?.close()
            let cleanupDocuments = adopted + app.documents.map(\.imageDocument)
            for controller in app.documents {
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            do { try wait({ app.documents.isEmpty && cleanupDocuments.allSatisfy { $0.pendingWork == 0 && gone($0.image) } },
                          "Owned recovery windows and images close") }
            catch { expect(false, "recovery cleanup close: \(error)") }
            documents.items.removeAll { document in adopted.contains { $0 === document } }
            for id in nativeOnly {
                do { try session.closeImage(id) } catch { expect(false, "loose recovery image cleanup: \(error)") }
            }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let wasVisible = priorPalettes[ObjectIdentifier(window)] {
                    if wasVisible { window.orderFront(nil) } else { window.orderOut(nil) }
                } else { window.close() }
            }
            ToolState.shared.select(oldTool)
        }

        let source = try session.newLabImage(width: 32, height: 24, component: .u16)
        nativeOnly.append(source)
        let originalURL = work.appendingPathComponent("lab-recovery-original.xcf")
        try session.save(source, to: originalURL.path)
        let originalBytes = try Data(contentsOf: originalURL), originalPixels = try pixels(source)
        let sourceAxes = try session.labAxes(source)
        try session.fillLab(source, axis: sourceAxes.axes[0], value: 40, opacity: 1)
        expect(try pixels(source) != originalPixels, "snapshot contains newer Lab pixels than the original saved file")
        do {
            let duplicate = try session.duplicateImage(source)
            nativeOnly.append(duplicate)
            expect(false, "Lab native duplication must remain unsupported")
        } catch let error as EngineSession.EngineError {
            expect(error.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue), "Lab duplicate refusal makes direct recovery adoption necessary")
        }

        let base = work.appendingPathComponent("lab-recovery-store-\(UUID().uuidString)", isDirectory: true)
        let prior = RecoveryStore(base: base, ownerPID: Int32.max - 4321, processIsAlive: { _ in false })
        try prior.prepare()
        let firstID = UUID(), retainedID = UUID()
        for (id, name) in [(firstID, "Lab recovery source"), (retainedID, "Lab left for later")] {
            let temp = prior.temporaryCopyURL(for: id)
            try session.saveCopy(source, to: temp.path)
            _ = try prior.commitCopy(at: temp, for: id, metadata: .init(name: name,
                nativeURL: originalURL, importedSourceURL: nil, revision: 1))
        }
        let store = RecoveryStore(base: base, processIsAlive: { $0 == ProcessInfo.processInfo.processIdentifier })
        try store.prepare(); app.recoveryStore = store
        let found = store.discoverRecoverableDocuments()
        guard let candidate = found.first(where: { $0.documentID == firstID }),
              let retained = found.first(where: { $0.documentID == retainedID }) else {
            throw NSError(domain: "LabRecoverySmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Prior Lab records missing"])
        }
        let copyBytes = try Data(contentsOf: candidate.copyURL), retainedBytes = try Data(contentsOf: retained.copyURL)
        let control = try session.openImage(path: candidate.copyURL.path)
        nativeOnly.append(control)
        let expectedPixels = try pixels(control), expectedAxes = try session.labAxes(control)
        // XCF does not persist the source's Undo stack. Compare recovery with
        // an independent ordinary open of the exact same recovery snapshot.
        let expectedUndo = try session.undoInfo(control)
        try session.closeImage(control); nativeOnly.removeAll { $0 == control }
        try session.closeImage(source); nativeOnly.removeAll { $0 == source }

        app.recoverDocuments(nil)
        guard let panel = app.recoveryPanel, let panelWindow = panel.window else {
            throw NSError(domain: "LabRecoverySmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Actual recovery panel missing"])
        }
        // The hosted smoke owns the engine instead of launching a second one.
        // Only supply that engine; production discovery/recover/adoption runs unchanged.
        panel.onRecover = { [weak app] records in app?.recover(records, using: session) }
        expect(panelWindow.isVisible && !panelWindow.canBecomeMain && panel.records.count == 2,
               "actual recovery panel lists both stale-owner Lab records")
        guard let row = panel.records.firstIndex(where: { $0.documentID == firstID }) else {
            throw NSError(domain: "LabRecoverySmoke", code: 5)
        }
        panel.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try wait({ panel.recoverButton.isEnabled && panel.selectedRecords == [candidate] }, "Real recovery row is selected")
        panel.recoverButton.performClick(nil)
        expect(app.inFlightRecoveries.count == 1 && panel.busy && !panel.recoverButton.isEnabled,
               "actual Recover action counts admission and blocks duplicate clicks")
        panel.recoverButton.performClick(nil)
        try wait({ app.inFlightRecoveries.isEmpty && !panel.busy && !EngineActivity.shared.isBusy }, "Lab recovery finishes")
        try require(app.documents.count == 1 && app.lastRecoveryFailure == nil, "Lab recovery adopts exactly one window without a duplicate call")
        let controller = app.documents[0], document = controller.imageDocument
        adopted.append(document); documents.items.append(document)
        try wait({ document.pendingWork == 0 }, "Recovered document initial reads drain")
        expect(document.name == "Lab recovery source recovered" && document.colorInfo.mode == .lab
               && document.colorInfo.component == .u16 && document.activeDrawable == nil,
               "recovery adopts a real typed Lab document through the direct native ownership path")
        guard let axes = document.labAxes else { throw NSError(domain: "LabRecoverySmoke", code: 6) }
        expect(axes.axes.map(\.uuid) == expectedAxes.axes.map(\.uuid) && axes.axes.map(\.role) == expectedAxes.axes.map(\.role)
               && axes.axes.map(\.name) == expectedAxes.axes.map(\.name) && axes.axes.map(\.isSelected) == expectedAxes.axes.map(\.isSelected),
               "recovery preserves typed axis identity, roles, names and saved selection")
        expect(try pixels(document.image) == expectedPixels && document.undoInfo == expectedUndo,
               "recovery preserves exact snapshot display and fresh-open history without an edit")
        expect(document.hasUnsavedChanges && document.fileState.nativeURL == nil && document.fileState.importedSourceURL == nil
               && document.fileState.saveRoute == .askForFile && document.fileState.revertSource == nil,
               "recovered Lab is unsaved and never adopts the original or recovery path as its Save target")
        let openCopyBytes = try Data(contentsOf: candidate.copyURL)
        expect(store.discoverRecoverableDocuments().contains(candidate) && openCopyBytes == copyBytes,
               "the only recovery copy remains intact while the recovered window is open")
        panel.recoverButton.performClick(nil)
        try wait({ app.inFlightRecoveries.isEmpty }, "Repeated recovery settles")
        expect(app.documents.count == 1 && app.documents.first === controller,
               "Recover on an already-open record raises the same window instead of duplicating it")

        var closed: Bool?
        controller.requestClose { closed = $0 }
        try wait({ controller.window?.attachedSheet != nil || controller.closeStarted }, "Unsaved recovery requests save confirmation")
        try require(!controller.closeStarted, "Unsaved recovered Lab must not close without confirmation")
        guard let sheet = controller.window?.attachedSheet, let root = sheet.contentView,
              let cancel = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) else {
            throw NSError(domain: "LabRecoverySmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "Actual save confirmation Cancel missing"])
        }
        cancel.performClick(nil)
        try wait({ closed != nil && controller.window?.attachedSheet == nil }, "Cancel answers recovery Close")
        expect(closed == false && !document.isClosing && store.discoverRecoverableDocuments().contains(candidate),
               "Cancel Close retains the unsaved recovered document and prior record")
        let newURL = work.appendingPathComponent("lab-recovery-resaved.xcf")
        var saved = false, saveError: Error?
        document.save(to: newURL) { saveError = $0; saved = true }
        try wait({ saved && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Recovered Lab native Save drains")
        if let saveError { throw saveError }
        document.noteSaved(to: newURL); try document.reload()
        expect(!document.hasUnsavedChanges && document.fileState.nativeURL == newURL && document.fileState.saveRoute == .write(newURL),
               "new native Save clears recovered-unsaved state across reload")
        expect(store.discoverRecoverableDocuments().contains(candidate), "Save alone does not retire the recovery record before Close")
        let savedImage = try session.openImage(path: newURL.path)
        nativeOnly.append(savedImage)
        let savedPixels = try pixels(savedImage), savedAxes = try session.labAxes(savedImage)
        expect(savedPixels == expectedPixels && savedAxes.axes.map(\.uuid) == expectedAxes.axes.map(\.uuid),
               "new saved XCF retains the recovered Lab pixels and durable axes")
        let finalOriginalBytes = try Data(contentsOf: originalURL), finalCopyBytes = try Data(contentsOf: candidate.copyURL)
        expect(finalOriginalBytes == originalBytes && finalCopyBytes == copyBytes,
               "recovery and new Save leave both original and recovery file bytes untouched")
        var finalClose: Bool?
        controller.requestClose { finalClose = $0 }
        try wait({ finalClose != nil && app.documents.isEmpty && gone(document.image) }, "Saved recovered window closes and releases its image")
        expect(finalClose == true && !store.discoverRecoverableDocuments().contains(candidate)
               && !FileManager.default.fileExists(atPath: candidate.copyURL.path), "successful Close retires only the used prior record")
        let finalRetainedBytes = try Data(contentsOf: retained.copyURL)
        expect(store.discoverRecoverableDocuments().contains(retained) && finalRetainedBytes == retainedBytes,
               "unselected recovery record and its snapshot remain available")
        expect(!NSDocumentController.shared.recentDocumentURLs.contains { $0.path.hasPrefix(base.path) },
               "private recovery snapshots never become recent documents")
    }
}
