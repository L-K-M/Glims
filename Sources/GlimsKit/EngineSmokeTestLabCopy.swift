import AppKit
import CGlimsEngine
import RigiUI

/// Only this focused smoke process installs the proxy. Every image and every
/// conversion still belongs to the real adapter; faults affect one returned ID.
private enum LabCopySmokeProxy {
    private static let lock = NSLock()
    private static var original: GlimsEngineAPI?
    private static var table: UnsafeMutablePointer<GlimsEngineAPI>?
    private static var result: Int32 = 0
    private static var results: [Int32] = []
    private static var calls = 0
    private static var attempts = 0
    private static var busyRemaining = 0
    private static var failAdoption = false
    private static var observer: (@MainActor (Int) -> Void)?

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    static func install(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        let api = try EngineLibrary.copyAPI(pointer)
        guard api.image_convert_lab_copy != nil else {
            throw NSError(domain: "LabCopySmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The real producer has no slot 197"])
        }
        return locked {
            precondition(table == nil, "One proxy installation per smoke process")
            original = api
            let owned = UnsafeMutablePointer<GlimsEngineAPI>.allocate(capacity: 1)
            owned.initialize(to: api)
            owned.pointee.image_convert_lab_copy = { engine, source, settings, output, error in
                let api = LabCopySmokeProxy.locked { LabCopySmokeProxy.original! }
                let status = api.image_convert_lab_copy!(engine, source, settings, output, error)
                LabCopySmokeProxy.locked {
                    LabCopySmokeProxy.calls += 1
                    if status == GLIMS_STATUS_OK, let id = output?.pointee, id > 0 {
                        LabCopySmokeProxy.result = id; LabCopySmokeProxy.results.append(id)
                    }
                }
                return status
            }
            owned.pointee.image_info = { engine, image, output in
                let blocked = LabCopySmokeProxy.locked { LabCopySmokeProxy.failAdoption && image == LabCopySmokeProxy.result && LabCopySmokeProxy.result > 0 }
                if blocked { return GLIMS_STATUS_FAILED }
                return LabCopySmokeProxy.locked { LabCopySmokeProxy.original! }.image_info(engine, image, output)
            }
            owned.pointee.image_close = { engine, image in
                let state: (GlimsEngineAPI, Bool, Int, (@MainActor (Int) -> Void)?) = LabCopySmokeProxy.locked {
                    guard image == LabCopySmokeProxy.result, LabCopySmokeProxy.result > 0 else { return (LabCopySmokeProxy.original!, false, 0, nil) }
                    LabCopySmokeProxy.attempts += 1
                    let busy = LabCopySmokeProxy.busyRemaining > 0
                    if busy { LabCopySmokeProxy.busyRemaining -= 1 } else { LabCopySmokeProxy.failAdoption = false }
                    return (LabCopySmokeProxy.original!, busy, LabCopySmokeProxy.attempts, LabCopySmokeProxy.observer)
                }
                let status = state.1 ? GLIMS_STATUS_BUSY : state.0.image_close(engine, image)
                if let callback = state.3 {
                    DispatchQueue.main.async { callback(state.2) }
                }
                return status
            }
            // The session copies the table, but the retained pointer also stays
            // valid through stop. This process-only allocation dies at exit.
            table = owned
            return UnsafePointer(owned)
        }
    }

    static func arm(busy: Int = 0, adoptionFailure: Bool = false,
                    onAttempt: (@MainActor (Int) -> Void)? = nil) {
        locked {
            result = 0; calls = 0; attempts = 0
            busyRemaining = busy; failAdoption = adoptionFailure; observer = onAttempt
        }
    }

    static var snapshot: (result: Int32, calls: Int, attempts: Int) {
        locked { (result, calls, attempts) }
    }
    static var allResults: [Int32] { locked { results } }
    static func stopFaults() { locked { busyRemaining = 0; failAdoption = false; observer = nil } }
}

@MainActor
extension EngineSmokeTest {
    static func installLabCopySmokeAPI(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        try LabCopySmokeProxy.install(pointer)
    }

    /// Real slot 197, AppController ownership, AppKit Close/Save sheets, and
    /// deterministic BUSY at destruction. No second engine is started.
    static func exerciseLabCopy(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-copy: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LabCopySmoke", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String, seconds: TimeInterval = 8) throws {
            let end = Date().addingTimeInterval(seconds)
            while !ready() && Date() < end { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            try require(ready(), message)
        }
        func gone(_ image: Int32) -> Bool {
            guard image > 0 else { return false }
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let data = rendered.dataProvider?.data as Data? else { throw NSError(domain: "LabCopySmoke", code: 3) }
            return data
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func cancelButton(_ controller: DocumentWindowController) -> NSButton? {
            buttons(controller.window?.attachedSheet?.contentView).first { $0.title == "Cancel" }
        }

        var owners: [AppController] = [], controllers: [DocumentWindowController] = []
        var ownedDocuments: [ImageDocument] = [], sourceIDs: [Int32] = []
        var menuBarriers: [DispatchSemaphore] = []
        var ownedConfirmations: [NSWindow] = []
        let previousMenu = NSApp.mainMenu
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        let oldTool = ToolState.shared.current
        func create(_ name: String, owner: AppController? = nil, dirty: Bool = false) throws -> ImageDocument {
            let id = try session.newImage(width: 8, height: 8)
            sourceIDs.append(id)
            try session.fill(image: id, at: .zero, mode: .selection, color: .init(calibratedWhite: 0.4, alpha: 1))
            let url = work.appendingPathComponent("lab-copy-\(UUID().uuidString).xcf")
            try session.save(id, to: url.path)
            if dirty { try session.fill(image: id, at: .zero, mode: .selection, color: .black) }
            let document = try ImageDocument(session: session, image: id, name: name, openedFrom: url)
            ownedDocuments.append(document); documents.items.append(document)
            if let owner {
                owner.open(document)
                guard let controller = owner.documents.first(where: { $0.imageDocument === document }) else {
                    throw NSError(domain: "LabCopySmoke", code: 4)
                }
                controllers.append(controller)
            }
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "New source settles")
            return document
        }
        func controller(_ document: ImageDocument, owner: AppController) throws -> DocumentWindowController {
            guard let found = owner.documents.first(where: { $0.imageDocument === document }) else {
                throw NSError(domain: "LabCopySmoke", code: 5)
            }
            return found
        }
        func retainAdopted(_ owner: AppController) {
            for item in owner.documents where !controllers.contains(where: { $0 === item }) {
                controllers.append(item); ownedDocuments.append(item.imageDocument)
                documents.items.append(item.imageDocument)
            }
        }
        func cleanupLeakedResult(_ label: String) throws {
            let state = LabCopySmokeProxy.snapshot
            try require(state.result > 0, "\(label): conversion must create a real result before testing cleanup")
            // A failed production retry must be recorded, then explicitly cleaned
            // by the fixture. Never turn that rescue into a passing assertion.
            let end = Date().addingTimeInterval(1.5)
            while !gone(state.result) && Date() < end { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            expect(gone(state.result) && LabCopySmokeProxy.snapshot.attempts == 3,
                   "\(label): result survives two BUSY refusals and is destroyed on the third attempt")
            if !gone(state.result) {
                LabCopySmokeProxy.stopFaults()
                var closed = false
                EngineActivity.shared.closeImage(state.result, session: session) { _ in closed = true }
                try wait({ closed && gone(state.result) }, "Fixture rescues the independently reported leaked result")
            }
        }
        defer {
            menuBarriers.forEach { $0.signal() }
            LabCopySmokeProxy.stopFaults()
            for owner in owners { retainAdopted(owner) }
            for item in controllers {
                if let button = cancelButton(item) { button.performClick(nil) }
                if let window = item.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
                }
            }
            for sheet in ownedConfirmations {
                if let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .cancel) }
                sheet.orderOut(nil)
            }
            EngineSmokeTestHost.pumpEvents()
            controllers.filter { !$0.closeStarted }.forEach { $0.closeDiscardingChanges() }
            for document in ownedDocuments where !controllers.contains(where: { $0.imageDocument === document }) {
                document.closeImageWhenDrained()
            }
            do { try wait({ ownedDocuments.allSatisfy { $0.pendingWork == 0 && gone($0.image) }
                              && !EngineActivity.shared.isBusy }, "Owned document teardown") }
            catch { expect(false, "owned document cleanup: \(error)") }
            for id in Set(sourceIDs + LabCopySmokeProxy.allResults) where !gone(id) {
                do { try session.closeImage(id) } catch { expect(false, "remaining native image cleanup: \(error)") }
            }
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let visible = priorPalettes[ObjectIdentifier(window)] {
                    if visible { window.orderFront(nil) } else { window.orderOut(nil) }
                } else { window.close() }
            }
            ToolState.shared.select(oldTool)
            NSApp.mainMenu = previousMenu
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "fixture leaves no owned sheets")
            expect(Set(sourceIDs + LabCopySmokeProxy.allResults).allSatisfy(gone), "fixture releases every owned native image")
        }

        try require(NSApp.isRunning && session.supportsLabConvertedCopy, "A hosted real slot-197 producer is required")
        NSApp.activate(ignoringOtherApps: true)

        // Positive control: normal ownership transfer, unchanged saved source.
        let successfulOwner = AppController(); owners.append(successfulOwner)
        let source = try create("Successful copy", owner: successfulOwner)
        let beforePixels = try pixels(source.image), beforeUndo = try session.undoInfo(source.image)
        let beforeFile = source.fileState
        LabCopySmokeProxy.arm()
        successfulOwner.convertedLabCopy(source, destination: .lab)
        try wait({ successfulOwner.documents.count == 2 && source.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Successful adoption")
        retainAdopted(successfulOwner)
        let copy = successfulOwner.documents.last!.imageDocument
        expect(copy.image != source.image && copy.colorInfo.mode == .lab && copy.colorInfo.component == .float,
               "real conversion adopts one independent FLOAT Lab document")
        expect(copy.hasUnsavedChanges && copy.fileState.nativeURL == nil && copy.fileState.importedSourceURL == nil,
               "adopted result requires a new Save destination")
        expect(try pixels(source.image) == beforePixels && session.undoInfo(source.image) == beforeUndo,
               "conversion preserves source pixels and native history")
        expect(source.fileState == beforeFile && !source.hasUnsavedChanges,
               "conversion preserves the clean source file identity")
        expect(LabCopySmokeProxy.snapshot.calls == 1 && LabCopySmokeProxy.snapshot.attempts == 0,
               "successful ownership transfers without premature destruction")
        expect(source.recorder.records.isEmpty && copy.recorder.records.isEmpty, "copy does not invent Recorder edits")

        // Accepted source Close must discard the future result and drain it.
        let closeOwner = AppController(); owners.append(closeOwner)
        let closing = try create("Close during copy", owner: closeOwner)
        let closingController = try controller(closing, owner: closeOwner)
        let closeState = closing.onStateChange
        var requestedClose = false
        closing.onStateChange = {
            closeState?()
            guard !requestedClose, EngineActivity.shared.isBusy else { return }
            requestedClose = true; closingController.closeDiscardingChanges()
        }
        LabCopySmokeProxy.arm(busy: 2)
        closeOwner.convertedLabCopy(closing, destination: .lab)
        try wait({ LabCopySmokeProxy.snapshot.attempts > 0 }, "Discard after source Close reaches image_close")
        closing.onStateChange = closeState
        expect(requestedClose && closing.isClosing, "source Close occurs during accepted work")
        try cleanupLeakedResult("source Close")
        try wait({ closeOwner.documents.isEmpty && gone(closing.image) }, "Source Close drains")
        expect(closeOwner.documents.isEmpty, "a closing source never opens a replacement window")

        // Both app close sequences must retain the file transaction until native
        // cleanup finishes. A dirty sentinel makes accidental Quit impossible.
        for quitting in [false, true] {
            let owner = AppController(); owners.append(owner)
            let document = try create(quitting ? "Quit source" : "Failed adoption source", owner: owner)
            let sentinel = try create("Unsaved close sentinel", owner: owner, dirty: true)
            let sentinelController = try controller(sentinel, owner: owner)
            let originalState = document.onStateChange, originalError = document.onError
            var requested = false, errors: [String] = [], reply: NSApplication.TerminateReply?
            var firstAttemptKeptSheetClosed: Bool?, firstAttemptKeptSourceOpen: Bool?
            document.onError = { errors.append($0) }
            document.onStateChange = {
                originalState?()
                guard !requested, EngineActivity.shared.isBusy else { return }
                requested = true
                if quitting { reply = owner.applicationShouldTerminate(NSApp) }
                else { owner.closeAllDocuments(nil) }
            }
            LabCopySmokeProxy.arm(busy: 2, adoptionFailure: !quitting) { attempt in
                if attempt == 1 {
                    firstAttemptKeptSheetClosed = sentinelController.window?.attachedSheet == nil
                    firstAttemptKeptSourceOpen = !document.isClosing && !sentinel.isClosing
                }
            }
            owner.convertedLabCopy(document, destination: .lab)
            try wait({ firstAttemptKeptSheetClosed != nil }, "First BUSY cleanup checkpoint")
            expect(requested && (!quitting || reply == .terminateLater), "\(quitting ? "Quit" : "Close All") is accepted while copy is counted")
            expect(firstAttemptKeptSheetClosed == true && firstAttemptKeptSourceOpen == true,
                   "\(quitting ? "Quit" : "Close All") cannot advance while discarded result cleanup is BUSY")
            try cleanupLeakedResult(quitting ? "Quit" : "failed adoption")
            try wait({ cancelButton(sentinelController) != nil }, "Real dirty sentinel Save confirmation")
            expect(gone(LabCopySmokeProxy.snapshot.result), "Save confirmation follows complete result destruction")
            cancelButton(sentinelController)?.performClick(nil)
            try wait({ sentinelController.window?.attachedSheet == nil && !EngineActivity.shared.isBusy }, "Cancel close sequence")
            document.onStateChange = originalState; document.onError = originalError
            expect(owner.documents.count == 2 && !document.isClosing && !sentinel.isClosing,
                   "Cancel keeps both original documents without adopting the discarded copy")
            expect(quitting ? errors.isEmpty : errors.count == 1, "adoption failure is reported once; intentional Quit discard is quiet")
            expect(NSApp.isRunning, "Cancel leaves the real AppKit host running")
        }

        // A disappearing app owner cannot leave its successful native result
        // unowned. This source deliberately has no window owned by that app.
        let orphanSource = try create("Owner released")
        var temporaryOwner: AppController? = AppController()
        weak var weakOwner = temporaryOwner
        let orphanState = orphanSource.onStateChange
        var released = false
        orphanSource.onStateChange = {
            orphanState?()
            guard !released, EngineActivity.shared.isBusy else { return }
            released = true
            DispatchQueue.main.async { temporaryOwner = nil }
        }
        LabCopySmokeProxy.arm(busy: 2)
        temporaryOwner?.convertedLabCopy(orphanSource, destination: .lab)
        try wait({ weakOwner == nil && LabCopySmokeProxy.snapshot.attempts > 0 }, "Unowned result cleanup begins")
        orphanSource.onStateChange = orphanState
        expect(released && weakOwner == nil, "the original AppController is actually deallocated")
        try cleanupLeakedResult("owner deallocation")
        expect(!gone(orphanSource.image) && !orphanSource.isClosing, "orphan-result cleanup never closes its source")

        // User-command observers may close synchronously before admission. The
        // callback must still settle once, with no producer call or count leak.
        let rejected = try create("Reentrant close refusal")
        let previousCommand = rejected.onUserCommand
        rejected.onUserCommand = { previousCommand?(); rejected.beginClosing() }
        LabCopySmokeProxy.arm()
        var rejectionCount = 0, rejectionFailed = false
        rejected.convertedLabCopy(.lab) {
            rejectionCount += 1
            if case .failure = $0 { rejectionFailed = true }
        }
        expect(rejectionCount == 1 && rejectionFailed && rejected.pendingWork == 0,
               "reentrant pre-admission Close settles failure once without a pending-work leak")
        expect(LabCopySmokeProxy.snapshot.calls == 0, "pre-admission Close never reaches native conversion")
        rejected.onUserCommand = previousCommand

        // The result callback runs before the first exclusive lease is released.
        // A nested attempt must refuse once rather than disappear or double-run.
        let reentrant = try create("Reentrant completion")
        LabCopySmokeProxy.arm()
        var outerCount = 0, innerCount = 0, innerFailed = false, returned: Int32 = 0
        reentrant.convertedLabCopy(.lab) { result in
            outerCount += 1
            if case .success(let image) = result { returned = image }
            reentrant.convertedLabCopy(.lab) {
                innerCount += 1
                if case .failure = $0 { innerFailed = true }
            }
        }
        try wait({ outerCount == 1 && innerCount == 1 && reentrant.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Reentrant completion drains")
        expect(returned > 0 && innerFailed && LabCopySmokeProxy.snapshot.calls == 1,
               "nested completion attempt refuses exactly once while the original result remains owned")
        var resultClosed = false
        EngineActivity.shared.closeImage(returned, session: session) { _ in resultClosed = true }
        try wait({ resultClosed && gone(returned) }, "Service caller closes its successful result")
        expect(outerCount == 1 && innerCount == 1 && reentrant.pendingWork == 0, "both completion paths settle their counts exactly once")

        // Exercise the installed product menu through AppKit's responder chain.
        // The prior service-only witnesses above keep their original assertions.
        NSApp.mainMenu = MainMenu.make()
        guard let item = NSApp.mainMenu?.item(withTitle: "Image")?.submenu?.items.first(where: {
            $0.action == #selector(DocumentWindowController.createConvertedLabCopy(_:))
        }), let action = item.action else { throw NSError(domain: "LabCopySmoke", code: 6) }
        func confirmMenu(_ target: DocumentWindowController, title: String) throws -> (NSWindow, NSButton, NSButton) {
            guard let window = target.window else { throw NSError(domain: "LabCopySmoke", code: 7) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); window.makeMain(); window.makeFirstResponder(nil)
            try wait({ NSApp.isActive && NSApp.mainWindow === window && target.imageDocument.pendingWork == 0
                       && !EngineActivity.shared.isBusy }, "Real menu source becomes main and idle")
            try require((NSApp.target(forAction: action, to: nil, from: item) as? DocumentWindowController) === target,
                        "Image menu responder-chain target must be the intended source controller")
            expect(target.validateMenuItem(item) && item.title == title,
                   "actual Image item is enabled and says \(title)")
            try require(NSApp.sendAction(action, to: nil, from: item), "Actual Image menu action must dispatch")
            try wait({ target.window?.attachedSheet != nil }, "Converted-copy confirmation appears")
            guard let sheet = target.window?.attachedSheet,
                  let create = buttons(sheet.contentView).first(where: { $0.title == "Create Copy" }),
                  let cancel = buttons(sheet.contentView).first(where: { $0.title == "Cancel" }) else {
                throw NSError(domain: "LabCopySmoke", code: 8)
            }
            ownedConfirmations.append(sheet)
            expect(sheet.isVisible && create.isEnabled && cancel.isEnabled,
                   "actual confirmation exposes enabled Create Copy and Cancel buttons")
            return (sheet, create, cancel)
        }

        let menuOwner = AppController(); owners.append(menuOwner)
        let menuSource = try create("Image menu source", owner: menuOwner)
        let menuController = try controller(menuSource, owner: menuOwner)
        let menuPixels = try pixels(menuSource.image), menuUndo = try session.undoInfo(menuSource.image)
        let menuFileState = menuSource.fileState
        let menuFile = try Data(contentsOf: menuFileState.nativeURL!)
        LabCopySmokeProxy.arm()
        let cancelled = try confirmMenu(menuController, title: "Create Lab Copy…")
        cancelled.2.performClick(nil)
        try wait({ menuController.window?.attachedSheet == nil && !EngineActivity.shared.isBusy }, "Cancel confirmation")
        expect(LabCopySmokeProxy.snapshot.calls == 0 && LabCopySmokeProxy.snapshot.result == 0 && menuOwner.documents.count == 1,
               "confirmation Cancel creates no native image or document")
        expect(try pixels(menuSource.image) == menuPixels && session.undoInfo(menuSource.image) == menuUndo
               && menuSource.fileState == menuFileState,
               "confirmation Cancel preserves source pixels, Undo and file identity")

        let confirmed = try confirmMenu(menuController, title: "Create Lab Copy…")
        confirmed.1.performClick(nil)
        try wait({ menuOwner.documents.count == 2 && menuOwner.documents.allSatisfy { $0.imageDocument.pendingWork == 0 }
                   && !EngineActivity.shared.isBusy }, "Actual Create Copy adoption")
        retainAdopted(menuOwner)
        let labController = menuOwner.documents.last!, lab = labController.imageDocument
        let physicalAxes = try session.labAxes(lab.image)
        expect(lab.image != menuSource.image && lab.image == LabCopySmokeProxy.snapshot.result
               && lab.colorInfo.mode == .lab && lab.colorInfo.component == .float
               && physicalAxes.axes.map(\.role) == [.lightness, .a, .b],
               "actual Create makes a distinct physical FLOAT Lab document with three typed axes")
        let labPixels = try pixels(lab.image), labUndo = try session.undoInfo(lab.image)
        expect(lab.info.width == 8 && lab.info.height == 8 && labPixels.count == menuPixels.count
               && labPixels != Data(repeating: 0, count: labPixels.count),
               "created Lab copy renders its real full canvas")
        expect(try pixels(menuSource.image) == menuPixels && session.undoInfo(menuSource.image) == menuUndo
               && menuSource.fileState == menuFileState && Data(contentsOf: menuFileState.nativeURL!) == menuFile,
               "Create leaves the source's pixels, history and saved bytes unchanged")
        expect(lab.hasUnsavedChanges && lab.fileState.saveRoute == .askForFile
               && lab.fileState.nativeURL == nil && lab.fileState.importedSourceURL == nil
               && lab.fileState.revertSource == nil && labController.window?.representedURL == nil,
               "created Lab copy has no inherited Save, Revert or represented-file destination")

        // A real Close asks to save the newly created copy. Cancel proves that
        // requirement without automating an external NSSavePanel.
        var labClose: Bool?
        labController.requestClose { labClose = $0 }
        try wait({ cancelButton(labController) != nil }, "Created copy requires a Save decision")
        let saveButtons = buttons(labController.window?.attachedSheet?.contentView).map(\.title)
        expect(saveButtons.contains("Save") && saveButtons.contains("Don't Save") && !labController.closeStarted,
               "actual Close offers Save and Don't Save for the untouched converted copy")
        cancelButton(labController)?.performClick(nil)
        try wait({ labClose != nil && labController.window?.attachedSheet == nil }, "Cancel converted-copy Close")
        expect(try labClose == false && !gone(lab.image) && lab.hasUnsavedChanges
               && pixels(lab.image) == labPixels && session.undoInfo(lab.image) == labUndo,
               "Cancel Close keeps the unsaved copy and its exact pixels/history")

        // The same real menu reflects the other direction from the new Lab
        // document. FLOAT RGB must be linear; no sample-value oracle is copied.
        LabCopySmokeProxy.arm()
        let rgbConfirmation = try confirmMenu(labController, title: "Create Linear RGB Copy…")
        rgbConfirmation.1.performClick(nil)
        try wait({ menuOwner.documents.count == 3 && menuOwner.documents.allSatisfy { $0.imageDocument.pendingWork == 0 }
                   && !EngineActivity.shared.isBusy }, "Actual linear RGB copy adoption")
        retainAdopted(menuOwner)
        let rgb = menuOwner.documents.last!.imageDocument
        expect(rgb.image != lab.image && rgb.image != menuSource.image && rgb.colorInfo.mode == .rgb
               && rgb.colorInfo.component == .float && rgb.colorInfo.trc == .linear,
               "Lab menu creates an independent FLOAT linear RGB copy")
        expect(try pixels(lab.image) == labPixels && session.undoInfo(lab.image) == labUndo && lab.hasUnsavedChanges,
               "reverse conversion preserves the unsaved physical Lab source")
        expect(rgb.hasUnsavedChanges && rgb.fileState.saveRoute == .askForFile && rgb.fileState.nativeURL == nil,
               "linear RGB copy also requires its own Save destination")

        // Confirmation is only intent. Activity accepted while it is open must
        // be checked again when the user presses the real Create button.
        LabCopySmokeProxy.arm()
        let busyConfirmation = try confirmMenu(menuController, title: "Create Lab Copy…")
        let release = DispatchSemaphore(value: 0); menuBarriers.append(release)
        var busyDone = false, busyErrors: [String] = []
        let priorError = menuSource.onError
        menuSource.onError = { busyErrors.append($0) }
        defer { menuSource.onError = priorError }
        try require(EngineActivity.shared.perform(label: "Confirmation admission fixture", work: {
            release.wait()
        }, completion: { busyDone = true }), "The confirmation-open activity must be admitted")
        busyConfirmation.1.performClick(nil)
        try wait({ menuController.window?.attachedSheet == nil }, "Stale confirmation resolves during activity")
        expect(LabCopySmokeProxy.snapshot.calls == 0 && menuOwner.documents.count == 3,
               "Create rechecks busy admission and allocates no copy")
        expect(busyErrors.count == 1 && busyErrors[0].contains("Confirmation admission fixture"),
               "refused confirmation reports the unavailable operation")
        release.signal()
        try wait({ busyDone && !EngineActivity.shared.isBusy && menuSource.pendingWork == 0 }, "Confirmation barrier drains")
        expect(try pixels(menuSource.image) == menuPixels && session.undoInfo(menuSource.image) == menuUndo
               && menuSource.fileState == menuFileState,
               "stale admission preserves the original source exactly")
        menuSource.onError = priorError

        // Keep the real button target alive to deliver a late positive action
        // after its source window closed. The completion must not adopt anything.
        let staleSource = try create("Closed confirmation source", owner: menuOwner)
        let staleController = try controller(staleSource, owner: menuOwner)
        LabCopySmokeProxy.arm()
        let staleConfirmation = try confirmMenu(staleController, title: "Create Lab Copy…")
        guard let lateAction = staleConfirmation.1.action, let lateTarget = staleConfirmation.1.target else {
            throw NSError(domain: "LabCopySmoke", code: 9)
        }
        staleController.closeDiscardingChanges()
        try require(staleSource.isClosing && staleController.closeStarted, "Actual source window Close begins before late action")
        _ = NSApp.sendAction(lateAction, to: lateTarget, from: staleConfirmation.1)
        try wait({ gone(staleSource.image) && !menuOwner.documents.contains(where: { $0 === staleController })
                   && !EngineActivity.shared.isBusy }, "Closed confirmation source drains")
        EngineSmokeTestHost.pumpEvents()
        expect(LabCopySmokeProxy.snapshot.calls == 0 && LabCopySmokeProxy.snapshot.result == 0
               && menuOwner.documents.count == 3, "late Create after source Close creates no native orphan or window")
        expect(!staleConfirmation.0.isVisible, "source Close and late confirmation leave no visible sheet")
        staleConfirmation.0.orderOut(nil)
    }
}
