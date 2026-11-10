import AppKit
import RigiUI

@MainActor
private final class CloseAllSmokeHost: NSObject, NSApplicationDelegate {
    private(set) var result: Int32 = 1
    private(set) var completed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(#selector(runChecks(_:)), with: nil, afterDelay: 0)
    }

    @objc private func runChecks(_ unused: Any?) {
        defer {
            completed = true
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
        guard NSApp.isRunning else {
            print("FAIL Close All AppKit event loop did not start")
            return
        }
        print("Close All host finishedLaunching=true running=true")
        result = EngineSmokeTest.run()
    }
}

@MainActor
extension EngineSmokeTest {
    static func runHostedCloseAll() -> Int32 {
        let app = NSApplication.shared
        guard !app.isRunning, app.delegate == nil,
              !NSRunningApplication.current.isFinishedLaunching else {
            print("FAIL Close All requires its own unlaunched AppKit host")
            return 1
        }
        let previousPolicy = app.activationPolicy()
        guard app.setActivationPolicy(.regular) else { return 1 }
        let host = CloseAllSmokeHost()
        app.delegate = host
        defer {
            app.delegate = nil
            _ = app.setActivationPolicy(previousPolicy)
        }
        app.run()
        guard host.completed else { return 1 }
        return host.result
    }

    /// Only temporary files and owned documents are used. No save target
    /// panel is needed: both dirty documents have genuine saved XCF targets.
    static func exerciseCloseAll(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        let owner = AppController()
        var owned: [DocumentWindowController] = []
        var images: [Int32] = []
        var gates: [DispatchSemaphore] = []
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows
            .filter { $0 is ClassicPaletteWindow }.map { (ObjectIdentifier($0), $0.isVisible) })

        func pump() {
            let end = Date().addingTimeInterval(0.01)
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
                if Date() >= end { break }
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: end)
        }
        func waitFor(_ title: String, _ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if predicate() { return true }
                pump()
            }
            check(false, "Timed out: \(title)")
            return false
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func promptButton(_ title: String, on controller: DocumentWindowController) -> NSButton? {
            buttons(controller.window?.attachedSheet?.contentView).first { $0.title == title }
        }
        func settle() -> Bool {
            waitFor("Close All accepted work drains", {
                owned.allSatisfy { $0.imageDocument.pendingWork == 0 } && !EngineActivity.shared.isBusy
            })
        }
        func create(_ name: String, at url: URL, color: NSColor? = nil) throws -> DocumentWindowController {
            let image = try session.newImage(width: 24, height: 16)
            images.append(image)
            try session.save(image, to: url.path)
            if let color { try session.fill(image: image, at: .zero, mode: .selection, color: color) }
            let document = try ImageDocument(session: session, image: image, name: name, openedFrom: url)
            documents.items.append(document)
            owner.open(document)
            guard let controller = owner.documents.first(where: { $0.imageDocument === document }) else {
                throw NSError(domain: "CloseAllSmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The app did not own its opened document."])
            }
            owned.append(controller)
            return controller
        }
        defer {
            gates.forEach { $0.signal() }
            for controller in owned {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .abort)
                }
            }
            pump()
            owned.forEach { $0.closeDiscardingChanges() }
            let closed = waitFor("Close All fixture native teardown", { images.allSatisfy(gone) })
            check(closed && owner.documents.isEmpty, "Close All teardown drains all owned native images")
            check(owned.allSatisfy { $0.window?.attachedSheet == nil }, "Close All teardown leaves no owned sheets")
            documents.items.removeAll { candidate in owned.contains { $0.imageDocument === candidate } }
            for image in images where !gone(image) { try? session.closeImage(image) }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let wasVisible = priorPalettes[ObjectIdentifier(window)] {
                    if !wasVisible { window.orderOut(nil) }
                } else {
                    window.close()
                }
            }
        }

        let folder = work.appendingPathComponent("close-all-files", isDirectory: true)
        let failureFolder = folder.appendingPathComponent("removed-before-save", isDirectory: true)
        try FileManager.default.createDirectory(at: failureFolder, withIntermediateDirectories: true)
        let cleanURL = folder.appendingPathComponent("clean.xcf")
        let failureURL = failureFolder.appendingPathComponent("failure.xcf")
        let savedURL = folder.appendingPathComponent("saved.xcf")
        // Captured reverse-open order is saved, failure, clean.
        let clean = try create("Clean", at: cleanURL)
        let failure = try create("Failed Save", at: failureURL, color: .green)
        let saved = try create("Saved", at: savedURL, color: .red)
        guard settle() else { return }
        let savedImage = saved.imageDocument.image
        let failureImage = failure.imageDocument.image
        let cleanImage = clean.imageDocument.image
        let savedPixels = try session.copyPixels(savedImage, merged: true).pixels
        let failurePixels = try session.copyPixels(failureImage, merged: true).pixels
        let savedHistory = try session.undoInfo(savedImage)
        let failureHistory = try session.undoInfo(failureImage)
        let savedFileBefore = try Data(contentsOf: savedURL)
        let failureFileBefore = try Data(contentsOf: failureURL)
        let cleanFileBefore = try Data(contentsOf: cleanURL)
        check(owner.documents.count == 3 && !clean.imageDocument.hasUnsavedChanges
              && saved.imageDocument.hasUnsavedChanges && failure.imageDocument.hasUnsavedChanges
              && savedPixels != failurePixels,
              "Close All fixture owns one clean and two independently changed saved documents")
        guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first(where: {
            $0.action == #selector(AppController.closeAllDocuments(_:))
        }) else { return check(false, "the actual File menu contains Close All") }
        check(item.title == "Close All" && owner.validateMenuItem(item), "the actual Close All item admits the owned set")
        _ = NSApp.sendAction(item.action!, to: owner, from: item)
        guard waitFor("first captured document prompts", { promptButton("Cancel", on: saved) != nil }) else { return }
        check(failure.window?.attachedSheet == nil && clean.window?.attachedSheet == nil,
              "Close All asks only the newest captured document before advancing")
        check(!owner.validateMenuItem(item), "Close All disables reentry while one request owns the sheet")
        _ = NSApp.sendAction(item.action!, to: owner, from: item)
        check(owner.documents.count == 3 && promptButton("Cancel", on: saved) != nil,
              "a repeated direct Close All action cannot replace the pending request")
        promptButton("Cancel", on: saved)?.performClick(nil)
        guard waitFor("cancel ends the captured sequence", {
            saved.window?.attachedSheet == nil && owner.validateMenuItem(item)
        }) else { return }
        check(owner.documents.count == 3 && images.allSatisfy { !gone($0) }, "Cancel preserves every captured native image")
        check(try session.copyPixels(savedImage, merged: true).pixels == savedPixels
              && session.copyPixels(failureImage, merged: true).pixels == failurePixels,
              "Cancel preserves both dirty documents' independent native pixels")
        check(try session.undoInfo(savedImage) == savedHistory && session.undoInfo(failureImage) == failureHistory,
              "Cancel adds no native history to either dirty image")
        check(try Data(contentsOf: savedURL) == savedFileBefore && Data(contentsOf: failureURL) == failureFileBefore,
              "Cancel writes neither saved file")
        check(NSApp.isRunning, "Cancel Close All keeps the application running")

        _ = NSApp.sendAction(item.action!, to: owner, from: item)
        guard waitFor("retry prompts the original first document", { promptButton("Save", on: saved) != nil }) else { return }
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        gates.append(release)
        saved.canvas.enqueueRenderBarrier { ready.signal(); release.wait() }
        guard waitFor("saved document render barrier starts", { ready.wait(timeout: .now()) == .success }) else { return }
        // This is the normal adoption API, as an already accepted New/Open
        // completion would use. It deliberately arrives after capture.
        let later = try create("Later", at: folder.appendingPathComponent("later.xcf"))
        let laterImage = later.imageDocument.image
        check(owner.documents.count == 4, "a new document can be adopted while Close All owns its captured set")
        promptButton("Save", on: saved)?.performClick(nil)
        guard waitFor("Save reaches held renderer teardown", { saved.closeStarted && saved.imageDocument.isClosing }) else { return }
        check(!gone(savedImage) && failure.window?.attachedSheet == nil,
              "Close All retains the native image and cannot advance before its renderer drains")
        check(!owner.validateMenuItem(item) && owner.documents.contains { $0 === later },
              "Close All stays active without capturing the newer document")
        release.signal()
        guard waitFor("next captured document prompts after complete close", {
            gone(savedImage) && promptButton("Save", on: failure) != nil
        }) else { return }
        check(!owner.documents.contains { $0 === saved } && owner.documents.contains { $0 === later },
              "the saved original closes once and the new document remains owned")
        let reopened = try session.openImage(path: savedURL.path)
        defer { try? session.closeImage(reopened) }
        check(try session.copyPixels(reopened, merged: true).pixels == savedPixels,
              "Save wrote the changed pixels before native destruction")
        check(try Data(contentsOf: cleanURL) == cleanFileBefore, "Close All has not written the untouched clean file")

        // A legitimate external failure: the document was opened from a
        // real XCF, but its private parent directory disappears before Save.
        let statusBeforeFailure = failure.statusBar.message
        try FileManager.default.removeItem(at: failureFolder)
        promptButton("Save", on: failure)?.performClick(nil)
        guard waitFor("failed Save stops the sequence", {
            failure.window?.attachedSheet == nil && !failure.imageDocument.isSavingForClose
                && owner.validateMenuItem(item)
        }) else { return }
        check(!gone(failureImage) && !gone(cleanImage) && !gone(laterImage),
              "a failed Save preserves the current and all remaining native images")
        check(try failure.imageDocument.hasUnsavedChanges
              && failure.imageDocument.fileState.nativeURL == failureURL
              && session.copyPixels(failureImage, merged: true).pixels == failurePixels,
              "failed Save preserves the exact dirty image instead of claiming a close")
        check(try session.undoInfo(failureImage) == failureHistory, "failed Save preserves the dirty image's history")
        check(!failure.statusBar.message.isEmpty && failure.statusBar.message != statusBeforeFailure
              && !FileManager.default.fileExists(atPath: failureURL.path),
              "failed Save reports its refusal without inventing a saved file")
        check(NSApp.isRunning && clean.window?.attachedSheet == nil, "failed Save keeps the app and later captured documents usable")

        _ = NSApp.sendAction(item.action!, to: owner, from: item)
        guard waitFor("final sequence closes clean later document and prompts dirty original", {
            gone(laterImage) && promptButton("Don't Save", on: failure) != nil
        }) else { return }
        promptButton("Don't Save", on: failure)?.performClick(nil)
        guard waitFor("all current documents finish closing", {
            owner.documents.isEmpty && images.allSatisfy(gone)
        }) else { return }
        check(!owner.validateMenuItem(item), "Close All disables when no documents remain")
        check(NSApp.isRunning, "successful Close All leaves the launched application running")
        check(try Data(contentsOf: cleanURL) == cleanFileBefore, "clean Close and Don't Save preserve the clean XCF")
    }
}
