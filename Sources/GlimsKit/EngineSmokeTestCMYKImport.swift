import AppKit
import CGlimsEngine
import RigiUI

/// Only this focused smoke process installs the proxy. Every image and every
/// import still belongs to the real adapter; faults affect one returned ID.
private enum CMYKImportSmokeProxy {
    private static let lock = NSLock()
    private static var original: GlimsEngineAPI?
    private static var table: UnsafeMutablePointer<GlimsEngineAPI>?
    private static var result: Int32 = 0
    private static var results: [Int32] = []
    private static var calls = 0
    private static var opens = 0
    private static var cancelImport = false
    private static var attempts = 0
    private static var busyRemaining = 0
    private static var failAdoption = false
    private static var observer: (@MainActor (Int) -> Void)?

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    static func install(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        let api = try EngineLibrary.copyAPI(pointer)
        guard api.image_import_native_cmyk_psd != nil else {
            throw NSError(domain: "CMYKImportSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The real producer has no slot 198"])
        }
        return locked {
            precondition(table == nil, "One proxy installation per smoke process")
            original = api
            let owned = UnsafeMutablePointer<GlimsEngineAPI>.allocate(capacity: 1)
            owned.initialize(to: api)
            owned.pointee.image_import_native_cmyk_psd = { engine, path, output, error in
                let state = CMYKImportSmokeProxy.locked { (CMYKImportSmokeProxy.original!, CMYKImportSmokeProxy.cancelImport) }
                let status: GlimsStatus
                if state.1 { output?.pointee = 0; error?.pointee = nil; status = GLIMS_STATUS_CANCELLED }
                else { status = state.0.image_import_native_cmyk_psd!(engine, path, output, error) }
                CMYKImportSmokeProxy.locked {
                    CMYKImportSmokeProxy.calls += 1
                    if status == GLIMS_STATUS_OK, let id = output?.pointee, id > 0 {
                        CMYKImportSmokeProxy.result = id; CMYKImportSmokeProxy.results.append(id)
                    }
                }
                return status
            }
            owned.pointee.image_open = { engine, path, output, error in
                let api = CMYKImportSmokeProxy.locked {
                    CMYKImportSmokeProxy.opens += 1
                    return CMYKImportSmokeProxy.original!
                }
                return api.image_open(engine, path, output, error)
            }
            owned.pointee.image_info = { engine, image, output in
                let blocked = CMYKImportSmokeProxy.locked { CMYKImportSmokeProxy.failAdoption && image == CMYKImportSmokeProxy.result && CMYKImportSmokeProxy.result > 0 }
                if blocked { return GLIMS_STATUS_FAILED }
                return CMYKImportSmokeProxy.locked { CMYKImportSmokeProxy.original! }.image_info(engine, image, output)
            }
            owned.pointee.image_close = { engine, image in
                let state: (GlimsEngineAPI, Bool, Int, (@MainActor (Int) -> Void)?) = CMYKImportSmokeProxy.locked {
                    guard image == CMYKImportSmokeProxy.result, CMYKImportSmokeProxy.result > 0 else { return (CMYKImportSmokeProxy.original!, false, 0, nil) }
                    CMYKImportSmokeProxy.attempts += 1
                    let busy = CMYKImportSmokeProxy.busyRemaining > 0
                    if busy { CMYKImportSmokeProxy.busyRemaining -= 1 } else { CMYKImportSmokeProxy.failAdoption = false }
                    return (CMYKImportSmokeProxy.original!, busy, CMYKImportSmokeProxy.attempts, CMYKImportSmokeProxy.observer)
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

    static func arm(busy: Int = 0, adoptionFailure: Bool = false, cancelled: Bool = false,
                    onAttempt: (@MainActor (Int) -> Void)? = nil) {
        locked {
            result = 0; calls = 0; opens = 0; attempts = 0; cancelImport = cancelled
            busyRemaining = busy; failAdoption = adoptionFailure; observer = onAttempt
        }
    }

    static var snapshot: (result: Int32, calls: Int, attempts: Int) {
        locked { (result, calls, attempts) }
    }
    static var openCalls: Int { locked { opens } }
    static var allResults: [Int32] { locked { results } }
    static func stopFaults() { locked { busyRemaining = 0; failAdoption = false; cancelImport = false; observer = nil } }
}

@MainActor
extension EngineSmokeTest {
    static func installCMYKImportSmokeAPI(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        try CMYKImportSmokeProxy.install(pointer)
    }

    static func exerciseCMYKImport(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "cmyk-import: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "CMYKImportSmoke", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String, seconds: TimeInterval = 15) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            try require(ready(), message)
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func cancel(_ controller: DocumentWindowController) -> NSButton? {
            buttons(controller.window?.attachedSheet?.contentView).first { $0.title == "Cancel" }
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 16, height: 12))
            guard let data = rendered.dataProvider?.data as Data? else { throw NSError(domain: "CMYKImportSmoke", code: 3) }
            return data
        }
        func serialized(_ image: Int32) throws -> Data {
            let url = work.appendingPathComponent("ink-snapshot-\(UUID().uuidString).psd")
            try session.export(image, to: url.path)
            return try Data(contentsOf: url)
        }
        var owners: [AppController] = [], controllers: [DocumentWindowController] = []
        var adopted: [ImageDocument] = [], loose: [Int32] = []
        let oldMenu = NSApp.mainMenu, oldTool = ToolState.shared.current
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        func retain(_ owner: AppController) {
            for controller in owner.documents where !controllers.contains(where: { $0 === controller }) {
                controllers.append(controller); adopted.append(controller.imageDocument)
                documents.items.append(controller.imageDocument)
            }
        }
        defer {
            CMYKImportSmokeProxy.stopFaults()
            owners.forEach(retain)
            for controller in controllers {
                cancel(controller)?.performClick(nil)
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
                }
            }
            controllers.filter { !$0.closeStarted }.forEach { $0.closeDiscardingChanges() }
            do { try wait({ adopted.allSatisfy { $0.pendingWork == 0 && gone($0.image) }
                             && !EngineActivity.shared.isBusy }, "All owned document work and closes drain") }
            catch { expect(false, "document cleanup: \(error)") }
            for id in Set(loose + CMYKImportSmokeProxy.allResults) where !gone(id) {
                do { try session.closeImage(id) } catch { expect(false, "remaining native cleanup: \(error)") }
            }
            documents.items.removeAll { item in adopted.contains { $0 === item } }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let visible = priorPalettes[ObjectIdentifier(window)] {
                    if visible { window.orderFront(nil) } else { window.orderOut(nil) }
                } else { window.close() }
            }
            NSApp.mainMenu = oldMenu; ToolState.shared.select(oldTool)
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "all owned sheets are dismissed")
            expect(Set(loose + adopted.map(\.image) + CMYKImportSmokeProxy.allResults).allSatisfy(gone),
                   "all owned native images are closed")
        }
        try require(NSApp.isRunning && session.supportsNativeCMYKPSDImport, "Hosted real slot198 producer required")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = MainMenu.make()
        guard let menuItem = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first(where: {
            $0.action == #selector(AppController.openNativeCMYKPSD(_:))
        }), let menuAction = menuItem.action,
              let icc = NSColorSpace.genericCMYK.iccProfileData else { throw NSError(domain: "CMYKImportSmoke", code: 4) }
        expect(menuItem.title == "Open CMYK PSD…", "actual File menu exposes the explicit preserving import selector")
        expect(!AppController().validateMenuItem(menuItem), "preserving File item is disabled without a running engine")

        func imported(_ url: URL, owner: AppController) throws -> DocumentWindowController {
            var result: Result<DocumentWindowController, Error>?
            owner.importNativeCMYKPSD(from: url) { result = $0 }
            try wait({ result != nil && !EngineActivity.shared.isBusy }, "Preserving import callback settles")
            let controller = try result!.get()
            retain(owner)
            return controller
        }
        func revert(_ controller: DocumentWindowController, owner: AppController) throws -> DocumentWindowController {
            guard let window = controller.window else { throw NSError(domain: "CMYKImportSmoke", code: 5) }
            window.makeKeyAndOrderFront(nil); window.makeMain()
            controller.revertDocument(nil)
            try wait({ window.attachedSheet != nil }, "Actual Revert confirmation appears")
            guard let button = buttons(window.attachedSheet?.contentView).first(where: { $0.title == "Revert" }) else {
                throw NSError(domain: "CMYKImportSmoke", code: 6)
            }
            button.performClick(nil)
            try wait({ !owner.documents.contains(where: { $0 === controller }) && gone(controller.imageDocument.image)
                       && !EngineActivity.shared.isBusy }, "Actual Revert replaces and closes its old document")
            retain(owner)
            guard let next = owner.documents.last else { throw NSError(domain: "CMYKImportSmoke", code: 7) }
            return next
        }
        var exampleURL: URL?
        for component in [EngineSession.ColorComponent.u8, .u16] {
            let source = try session.newCmykImage(width: 16, height: 12, component: component, profileICC: icc)
            loose.append(source)
            let originalChannels = try session.channels(source)
            for (index, channel) in originalChannels.enumerated() {
                try session.channelCommand(.select, channel: channel.id, image: source)
                try session.editInk(source, channel: channel.id,
                                    settings: .init(operation: .fill, intensity: Double(index + 1) / 5, opacity: 1))
            }
            let url = work.appendingPathComponent("preserved-\(component.rawValue).psd")
            try session.export(source, to: url.path)
            if exampleURL == nil { exampleURL = url }
            let original = try Data(contentsOf: url), originalPixels = try pixels(source)
            expect(original.range(of: icc) != nil && original.count > icc.count,
                   "\(component): source fixture contains exact embedded profile and real ink samples")
            let owner = AppController(session: session); owners.append(owner)
            expect(owner.validateMenuItem(menuItem), "\(component): actual File item is enabled for the live producer")

            // A real ordinary PSD import at this path is an RGB appearance document.
            let appearanceID = try session.openImage(path: url.path); loose.append(appearanceID)
            let appearance = try ImageDocument(session: session, image: appearanceID, name: "Appearance", openedFrom: url)
            owner.open(appearance); retain(owner)
            try wait({ appearance.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Appearance import settles")
            let appearancePixels = try pixels(appearanceID)
            expect(appearance.colorInfo.mode == .rgb && appearance.fileState.importStrategy == .appearance,
                   "\(component): same-path ordinary Open is an RGB appearance import")
            CMYKImportSmokeProxy.arm()
            var controller = try imported(url, owner: owner)
            var document = controller.imageDocument
            expect(owner.documents.count == 2 && document !== appearance && document.image != appearanceID,
                   "\(component): preserving import does not reuse the same-path appearance document")
            expect(document.colorInfo.mode == .cmyk && document.colorInfo.component == component && document.channels.count == 4,
                   "\(component): imported document exposes four native CMYK inks at source depth")
            expect(document.fileState.importStrategy == .nativeCMYKPSD && document.fileState.nativeURL == nil
                   && document.fileState.importedSourceURL == url && document.hasUnsavedChanges
                   && document.fileState.saveRoute == .askForFile && document.fileState.revertSource == .nativeCMYKPSD(url),
                   "\(component): preserving import is unsaved with its typed foreign identity")
            expect(try serialized(document.image) == original && pixels(document.image) == originalPixels,
                   "\(component): exported native samples/profile and displayed composite match the source exactly")
            expect(document.undoInfo.undoCount == 0 && document.undoInfo.redoCount == 0,
                   "\(component): imported native image begins with empty history")
            let repeatController = try imported(url, owner: owner)
            expect(repeatController === controller && owner.documents.count == 2 && CMYKImportSmokeProxy.snapshot.calls == 1,
                   "\(component): second preserving import focuses the existing document without another native import")
            expect(NSApp.keyWindow === controller.window, "\(component): repeated preserving import brings its window forward")

            guard let channel = document.channels.first?.id else {
                throw NSError(domain: "CMYKImportSmoke", code: 10)
            }
            document.selectChannel(channel)
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Ink target selection settles")
            var edit: Result<Void, Error>?
            expect(document.editInk(.init(operation: .fill, intensity: 0.95, opacity: 1), channel: channel) { edit = $0 },
                   "\(component): supported scalar Fill is accepted on imported CMYK")
            try wait({ edit != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Imported ink edit settles")
            try edit!.get()
            expect(try serialized(document.image) != original && document.undoInfo.undoCount == 1,
                   "\(component): imported ink edit changes actual samples with one Undo")
            CMYKImportSmokeProxy.arm()
            controller = try revert(controller, owner: owner); document = controller.imageDocument
            expect(CMYKImportSmokeProxy.snapshot.calls == 1 && CMYKImportSmokeProxy.openCalls == 0
                   && document.colorInfo.mode == .cmyk && document.fileState.importStrategy == .nativeCMYKPSD,
                   "\(component): actual Revert uses preserving import and remains native CMYK")
            expect(try serialized(document.image) == original && pixels(document.image) == originalPixels
                   && document.undoInfo.undoCount == 0, "\(component): Revert restores exact source samples/profile/history")
            expect(try pixels(appearanceID) == appearancePixels && Data(contentsOf: url) == original,
                   "\(component): preserving edits and Revert leave appearance document and source file unchanged")

            let saved = work.appendingPathComponent("preserved-\(component.rawValue).xcf")
            var savedDone = false, saveError: Error?
            document.save(to: saved) { error in
                saveError = error
                if error == nil { document.noteSaved(to: saved) }
                savedDone = true
            }
            try wait({ savedDone && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Native Save settles")
            try require(saveError == nil, "Native Save failed: \(String(describing: saveError))")
            expect(!document.hasUnsavedChanges && document.fileState.importStrategy == nil
                   && document.fileState.revertSource == .native(saved), "\(component): native Save replaces preserving import identity")
            CMYKImportSmokeProxy.arm()
            controller = try revert(controller, owner: owner); document = controller.imageDocument
            expect(CMYKImportSmokeProxy.snapshot.calls == 0 && CMYKImportSmokeProxy.openCalls == 1
                   && document.colorInfo.mode == .cmyk && document.fileState.nativeURL == saved && !document.hasUnsavedChanges,
                   "\(component): saved XCF Revert switches to ordinary native Open while retaining CMYK")
            expect(try serialized(document.image) == original, "\(component): XCF Save/Revert retains exact native inks/profile")
        }
        guard let exampleURL else { throw NSError(domain: "CMYKImportSmoke", code: 8) }
        let failureOwner = AppController(session: session); owners.append(failureOwner)
        let malformed = work.appendingPathComponent("malformed-import.psd")
        try Data("This is not a PSD".utf8).write(to: malformed)
        for cancelled in [false, true] {
            CMYKImportSmokeProxy.arm(cancelled: cancelled)
            var outcome: Result<DocumentWindowController, Error>?
            failureOwner.importNativeCMYKPSD(from: cancelled ? exampleURL : malformed) { outcome = $0 }
            try wait({ outcome != nil && !EngineActivity.shared.isBusy }, "Failed/cancelled import settles")
            if case .failure(let error) = outcome! {
                expect(!cancelled || (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_CANCELLED.rawValue),
                       "cancelled import preserves the native cancellation status")
            } else { expect(false, "invalid/cancelled import must fail") }
            expect(failureOwner.documents.isEmpty && CMYKImportSmokeProxy.snapshot.result == 0,
                   "\(cancelled ? "cancelled" : "invalid") import creates no image window")
            expect(CMYKImportSmokeProxy.openCalls == 0, "failed preserving import never falls back to ordinary Open")
        }
        CMYKImportSmokeProxy.arm()
        _ = try imported(exampleURL, owner: failureOwner)
        expect(failureOwner.documents.count == 1, "a cancelled request releases its same-path reservation for retry")

        let disguised = work.appendingPathComponent("CMYK content named.xcf")
        try FileManager.default.copyItem(at: exampleURL, to: disguised)
        let disguisedController = try imported(disguised, owner: failureOwner)
        expect(disguisedController.imageDocument.fileState.nativeURL == nil
               && disguisedController.imageDocument.fileState.importStrategy == .nativeCMYKPSD
               && disguisedController.imageDocument.fileState.revertSource == .nativeCMYKPSD(disguised)
               && disguisedController.imageDocument.hasUnsavedChanges,
               "preserving import treats PSD content with an XCF suffix as foreign and unsaved")

        // Dispatch the installed File item into the real controller and cancel
        // the actual modal NSOpenPanel; the timer also bounds a missing panel.
        CMYKImportSmokeProxy.arm()
        let countBeforePanel = failureOwner.documents.count
        var cancelledPanel = false, panelTimedOut = false
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            if let panel = NSApp.modalWindow as? NSOpenPanel {
                cancelledPanel = true; panel.cancel(nil); timer.invalidate()
            } else if Date() >= deadline {
                panelTimedOut = true; NSApp.abortModal(); timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let dispatched = NSApp.sendAction(menuAction, to: failureOwner, from: menuItem)
        timer.invalidate()
        expect(dispatched && cancelledPanel && !panelTimedOut, "actual File action presents an Open panel that Cancel dismisses")
        expect(NSApp.modalWindow == nil && failureOwner.documents.count == countBeforePanel
               && CMYKImportSmokeProxy.snapshot.calls == 0 && !EngineActivity.shared.isBusy,
               "Open-panel Cancel changes no documents and submits no native work")

        // A dirty sentinel prevents accidental termination and makes the pending
        // file-operation lifetime visible through the real Save confirmation.
        for quitting in [false, true] {
            let owner = AppController(session: session); owners.append(owner)
            let sentinelID = try session.newImage(width: 16, height: 12); loose.append(sentinelID)
            let sentinel = try ImageDocument(session: session, image: sentinelID, name: "Unsaved import sentinel")
            sentinel.noteUnsavedConvertedCopy()
            owner.open(sentinel); retain(owner)
            guard let controller = owner.documents.first else { throw NSError(domain: "CMYKImportSmoke", code: 9) }
            try wait({ sentinel.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Sentinel settles")
            let oldObserver = sentinel.onStateChange
            var requested = false, reply: NSApplication.TerminateReply?
            var callbackCount = 0, outcome: Result<DocumentWindowController, Error>?
            var firstBusyHeld: Bool?
            sentinel.onStateChange = {
                oldObserver?()
                guard !requested, EngineActivity.shared.isBusy else { return }
                requested = true
                if quitting { reply = owner.applicationShouldTerminate(NSApp) }
                else { owner.closeAllDocuments(nil) }
            }
            CMYKImportSmokeProxy.arm(busy: 2, adoptionFailure: !quitting) { attempt in
                if attempt == 1 {
                    firstBusyHeld = callbackCount == 0 && controller.window?.attachedSheet == nil && !sentinel.isClosing
                }
            }
            owner.importNativeCMYKPSD(from: exampleURL) { callbackCount += 1; outcome = $0 }
            try wait({ firstBusyHeld != nil }, "Discarded imported result reaches first BUSY cleanup")
            sentinel.onStateChange = oldObserver
            expect(requested && (!quitting || reply == .terminateLater),
                   "\(quitting ? "Quit" : "Close All") observes an accepted import transaction")
            expect(firstBusyHeld == true, "\(quitting ? "Quit" : "adoption failure") holds completion and Save prompt during BUSY cleanup")
            try wait({ outcome != nil && cancel(controller) != nil && !EngineActivity.shared.isBusy },
                     "Result cleanup completes before dirty-sentinel Save confirmation")
            let result = CMYKImportSmokeProxy.snapshot
            expect(result.result > 0 && gone(result.result) && result.attempts == 3,
                   "\(quitting ? "Quit" : "adoption failure") retries two BUSY closes and destroys the native result")
            if case .failure = outcome! { expect(callbackCount == 1, "discarded import completes exactly once with failure") }
            else { expect(false, "discarded import must not publish a document") }
            expect(owner.documents.count == 1 && owner.documents.first === controller,
                   "discarded result creates no document window")
            cancel(controller)?.performClick(nil)
            try wait({ controller.window?.attachedSheet == nil }, "Cancel dirty-sentinel close")
            expect(!sentinel.isClosing && NSApp.isRunning && owner.validateMenuItem(menuItem),
                   "Cancel keeps the sentinel and restores the active import command")
        }
    }
}
