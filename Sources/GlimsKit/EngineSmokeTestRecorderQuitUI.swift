import AppKit
import RigiUI

@MainActor
private final class RecorderQuitDelegate: NSObject, NSApplicationDelegate {
    let owner: AppController
    private(set) var replies: [NSApplication.TerminateReply] = []
    private(set) var willTerminateCalls = 0
    var finalize: ((Notification) -> Void)?

    init(owner: AppController) { self.owner = owner }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = owner.applicationShouldTerminate(sender)
        replies.append(reply)
        return reply
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The launched smoke host supplies its engine session externally.
        // The explicit Quit request owns termination throughout this fixture.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminateCalls += 1
        finalize?(notification)
    }
}

@MainActor
extension EngineSmokeTest {
    /// The successful path exits through AppKit. Its final assertions and
    /// external-session cleanup therefore run in applicationWillTerminate.
    static func exerciseRecorderQuitUI(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        struct State: Equatable {
            let info: EngineSession.ImageInfo
            let pixels: Data
            let history: EngineSession.History
        }

        let owner = AppController()
        let proxy = RecorderQuitDelegate(owner: owner)
        let closeAll = NSMenuItem(title: "Close All", action: #selector(AppController.closeAllDocuments(_:)), keyEquivalent: "")
        let previousDelegate = NSApp.delegate
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        let directory = work.appendingPathComponent("recorder-quit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var owned: [DocumentWindowController] = []
        var loose: [Int32] = []
        let release = DispatchSemaphore(value: 0)
        var checks = 0
        var failed = false
        var finalCloseReady = false
        var quitPending = false
        var closeOrder: [Int32] = []
        var cleanBAtClose = false

        func expect(_ value: Bool, _ message: String) {
            checks += 1
            failed = failed || !value
            check(value, "Recorder Quit: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RecorderQuitUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let control = view as? NSButton, control.title == title { return control }
            for child in view.subviews { if let control = button(title, in: child) { return control } }
            return nil
        }
        func state(_ document: ImageDocument) throws -> State {
            try State(info: session.info(document.image), pixels: session.copyPixels(document.image, merged: true).pixels,
                      history: session.history(document.image))
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func restorePalettes() {
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let wasVisible = priorPalettes[ObjectIdentifier(window)] {
                    if !wasVisible { window.orderOut(nil) }
                } else { window.close() }
            }
        }
        defer {
            // A failed fixture returns through EngineSmokeTest.run, which
            // owns the ordinary session-stop defer. Actual Quit never returns.
            release.signal()
            for controller in owned {
                if let window = controller.window, let sheet = window.attachedSheet {
                    if let panel = sheet as? NSSavePanel { panel.cancel(nil) }
                    else { window.endSheet(sheet, returnCode: .cancel) }
                    _ = wait { window.attachedSheet == nil }
                }
            }
            if quitPending && !owner.validateMenuItem(closeAll) { NSApp.reply(toApplicationShouldTerminate: false) }
            proxy.finalize = nil
            NSApp.delegate = previousDelegate
            owned.forEach { $0.closeDiscardingChanges() }
            expect(wait { owned.allSatisfy { $0.imageDocument.pendingWork == 0 && gone($0.imageDocument.image) } },
                   "failure cleanup drains owned native images")
            expect(owned.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "failure cleanup closes owned sheets and windows")
            for image in loose { try? session.closeImage(image) }
            documents.items.removeAll { candidate in owned.contains { $0.imageDocument === candidate } }
            try? FileManager.default.removeItem(at: directory)
            restorePalettes()
            print("     recorder-quit-ui failed before normal process termination, checks: \(checks)")
        }

        func makeDocument(_ name: String, salt: Int) throws -> DocumentWindowController {
            var bytes: [UInt8] = []
            for y in 0..<17 {
                for x in 0..<23 {
                    bytes.append(contentsOf: [UInt8((9 * x + salt) % 256), UInt8(13 * y), UInt8(x + 11 * y), 255])
                }
            }
            let file = directory.appendingPathComponent(name + ".xcf")
            let image = try session.newImage(pixels: ClipboardImage(width: 23, height: 17, pixels: Data(bytes), origin: .zero))
            loose.append(image)
            try session.save(image, to: file.path)
            let document = try ImageDocument(session: session, image: image, name: name, openedFrom: file)
            documents.items.append(document)
            owner.open(document)
            guard let controller = owner.documents.first(where: { $0.imageDocument === document }) else {
                throw NSError(domain: "RecorderQuitUI", code: 2)
            }
            owned.append(controller)
            loose.removeAll { $0 == image }
            return controller
        }

        // Quit closes the actual AppController's newest document first.
        let b = try makeDocument("Clean B", salt: 31)
        let a = try makeDocument("Active A", salt: 0)
        let adoc = a.imageDocument, bdoc = b.imageDocument
        guard let window = a.window, let aURL = adoc.fileState.nativeURL, let bURL = bdoc.fileState.nativeURL else {
            throw NSError(domain: "RecorderQuitUI", code: 3)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        try require(wait { window.isKeyWindow && owned.allSatisfy { $0.imageDocument.pendingWork == 0 }
            && !EngineActivity.shared.isBusy }, "The real owned documents did not become ready")
        let savedA = try Data(contentsOf: aURL), savedB = try Data(contentsOf: bURL)
        let nativeB = try state(bdoc)
        let bCheckpoint = bdoc.recorderContentCheckpoint()
        let bMetadata = bdoc.recorderFileMetadata
        try adoc.startRecording()
        adoc.transformImage(.rotate90)
        try require(wait { adoc.pendingWork == 0 && adoc.recorder.pendingCount == 0 }, "A's recorded edit did not settle")
        try adoc.renameRecording("Keep A through cancelled Quit")
        let metadata = adoc.recorderFileMetadata
        expect(adoc.hasUnsavedChanges && adoc.hasUnsavedRecordingChanges && adoc.recorder.isRecording
            && adoc.recorder.records.count == 1 && !bdoc.hasUnsavedChanges && !bdoc.hasUnsavedRecordingChanges,
               "the actual owner has a dirty image and active named recording ahead of clean B")

        let priorAClose = a.onClose
        a.onClose = { controller in
            closeOrder.append(controller.imageDocument.image)
            priorAClose?(controller)
        }
        let priorBClose = b.onClose
        b.onClose = { controller in
            closeOrder.append(controller.imageDocument.image)
            cleanBAtClose = !bdoc.hasUnsavedChanges && !bdoc.hasUnsavedRecordingChanges
                && bdoc.info == nativeB.info && bdoc.recorderContentCheckpoint() == bCheckpoint
                && bdoc.recorderFileMetadata == bMetadata
            priorBClose?(controller)
        }
        func click(_ title: String, alongside: [String]) throws {
            try require(wait {
                guard let view = window.attachedSheet?.contentView else { return false }
                return window.attachedSheet?.isVisible == true && button(title, in: view)?.isEnabled == true
                    && alongside.allSatisfy { button($0, in: view) != nil }
            }, "Expected the owning \(title) sheet with \(alongside)")
            guard let view = window.attachedSheet?.contentView, let control = button(title, in: view) else {
                throw NSError(domain: "RecorderQuitUI", code: 4)
            }
            control.performClick(nil)
        }
        func usable() -> Bool {
            owner.validateMenuItem(closeAll) && window.attachedSheet == nil && a.canPresentRecorderFileSheet
                && proxy.willTerminateCalls == 0 && NSApp.isRunning
        }
        func preserved(_ checkpoint: ImageDocument.RecorderInstallCheckpoint, _ native: State, rows: Int) throws -> Bool {
            try owner.documents.count == 2 && owner.documents.contains { $0 === a } && owner.documents.contains { $0 === b }
                && !adoc.isClosing && !a.closeStarted && window.isVisible && adoc.recorder.isRecording
                && adoc.hasUnsavedRecordingChanges && adoc.recorderContentCheckpoint() == checkpoint
                && adoc.recorderFileMetadata == metadata && adoc.recorder.records.count == rows
                && state(adoc) == native && state(bdoc) == nativeB && bdoc.recorderContentCheckpoint() == bCheckpoint
                && Data(contentsOf: aURL) == savedA && Data(contentsOf: bURL) == savedB
        }

        proxy.finalize = { [weak proxy] notification in
            expect(finalCloseReady && proxy?.willTerminateCalls == 1 && proxy?.replies.count == 3,
                   "AppKit reaches actual willTerminate only after the final accepted Quit")
            expect(owner.documents.isEmpty && closeOrder == [adoc.image, bdoc.image]
                && owned.allSatisfy { $0.imageDocument.pendingWork == 0 && gone($0.imageDocument.image) },
                   "actual Quit drains and destroys A then clean B exactly once")
            expect(cleanBAtClose && bdoc.recorderContentCheckpoint() == bCheckpoint
                && bdoc.recorderFileMetadata == bMetadata, "clean B closes with its original image and recording state")
            expect((try? Data(contentsOf: aURL)) == savedA && (try? Data(contentsOf: bURL)) == savedB,
                   "actual Quit writes neither private saved XCF")
            expect(owned.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "actual Quit leaves no owned window or sheet")
            owner.applicationWillTerminate(notification)
            session.stop()
            documents.items.removeAll { candidate in owned.contains { $0.imageDocument === candidate } }
            try? FileManager.default.removeItem(at: directory)
            expect(!FileManager.default.fileExists(atPath: directory.path), "termination removes only the private fixture directory")
            restorePalettes()
            NSApp.delegate = previousDelegate
            print("     recorder-quit-ui checks: \(checks)")
            print(failed ? "FAILED (Recorder Quit actual termination)" : "PASSED (Recorder Quit actual termination)")
            fflush(stdout)
        }
        NSApp.delegate = proxy
        let initial = adoc.recorderContentCheckpoint()
        let nativeA = try state(adoc)
        quitPending = true
        NSApp.terminate(nil)
        try click("Cancel", alongside: ["Save…", "Discard Changes"])
        try require(wait { usable() }, "Recorder Cancel did not cancel AppKit's pending Quit")
        quitPending = false
        expect(try proxy.replies.count == 1 && proxy.replies.allSatisfy { $0 == .terminateLater }
            && preserved(initial, nativeA, rows: 1), "Recorder Cancel preserves active A, both native images and AppKit usability")

        adoc.transformImage(.flipHorizontal)
        try require(wait { adoc.pendingWork == 0 && adoc.recorder.pendingCount == 0 }, "A did not accept input after cancelled Quit")
        let current = adoc.recorderContentCheckpoint(), changedA = try state(adoc)
        expect(current != initial && changedA.pixels != nativeA.pixels && adoc.recorder.records.map(\.ordinal) == [0, 1]
            && adoc.recorderFileMetadata == metadata && adoc.recorder.isRecording,
               "cancelled Quit leaves the same active recording able to accept a native edit")

        quitPending = true
        NSApp.terminate(nil)
        try click("Discard Changes", alongside: ["Save…", "Cancel"])
        try click("Cancel", alongside: ["Save", "Don't Save"])
        try require(wait { usable() }, "Image Cancel did not cancel AppKit's second pending Quit")
        quitPending = false
        expect(try proxy.replies.count == 2 && proxy.replies.allSatisfy { $0 == .terminateLater }
            && preserved(current, changedA, rows: 2), "image Cancel after Recorder Discard preserves the same recording and restores Quit usability")
        try require(!failed, "A cancelled-Quit acceptance check failed")

        quitPending = true
        NSApp.terminate(nil)
        try click("Discard Changes", alongside: ["Save…", "Cancel"])
        expect(proxy.replies.count == 3 && proxy.replies.allSatisfy { $0 == .terminateLater }
            && adoc.recorderContentCheckpoint() == current && adoc.recorder.isRecording,
               "the next actual Quit asks for Recorder consent again")
        let entered = DispatchSemaphore(value: 0)
        a.canvas.enqueueRenderBarrier { entered.signal(); _ = release.wait(timeout: .now() + 20) }
        var renderHeld = false
        try require(wait {
            if !renderHeld { renderHeld = entered.wait(timeout: .now()) == .success }
            return renderHeld
        }, "A's real renderer hold did not start")
        try click("Don't Save", alongside: ["Save", "Cancel"])
        try require(wait { a.closeStarted && adoc.isClosing }, "Final Don't Save did not start A's close")
        expect(!gone(adoc.image) && !b.closeStarted && owner.documents.count == 2 && closeOrder.isEmpty
            && proxy.willTerminateCalls == 0, "final Quit holds A alive and waits before advancing to clean B")
        expect(try state(bdoc) == nativeB && Data(contentsOf: aURL) == savedA && Data(contentsOf: bURL) == savedB,
               "B and both saved sources are unchanged immediately before the final native drain")
        finalCloseReady = !failed
        release.signal()
        // Success exits inside AppKit after reply(toApplicationShouldTerminate:).
        // A return or a timeout is a failure, even if windows happened to close.
        _ = wait { proxy.willTerminateCalls > 0 }
        throw NSError(domain: "RecorderQuitUI", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Actual application termination did not exit the process"])
    }
}
