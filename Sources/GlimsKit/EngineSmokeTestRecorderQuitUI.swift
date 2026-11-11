import AppKit
import RigiUI

/// AppKit can keep terminate() inside its own nested run loop until the
/// delegate replies. Sheet interaction must already be scheduled in modes
/// served by that loop, rather than follow terminate() on the call stack.
@MainActor
private final class RecorderQuitDriver: NSObject {
    private let window: NSWindow
    private let advance: () throws -> Bool
    private let release: () -> Void
    private var timer: Timer?
    private var deadline = Date.distantPast
    private(set) var finished = false
    private(set) var failure: Error?

    init(window: NSWindow, release: @escaping () -> Void, advance: @escaping () throws -> Bool) {
        self.window = window
        self.release = release
        self.advance = advance
    }

    func start() {
        deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        for mode in [RunLoop.Mode.default, .modalPanel, .eventTracking] {
            RunLoop.main.add(timer, forMode: mode)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick(_ sender: Timer) {
        do {
            guard Date() < deadline else {
                throw NSError(domain: "RecorderQuitUI", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "The owning Quit sheet driver timed out"])
            }
            // Each callback performs at most one button click. It never pumps
            // events or waits for a queued task from inside AppKit's loop.
            if try advance() {
                finished = true
                stop()
            }
        } catch {
            failure = error
            stop()
            release()
            if let sheet = window.attachedSheet {
                if let panel = sheet as? NSSavePanel { panel.cancel(nil) }
                else { window.endSheet(sheet, returnCode: .cancel) }
            }
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }
}

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
        var activeDriver: RecorderQuitDriver?

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
            activeDriver?.stop()
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
        func readyButton(_ title: String, alongside: [String]) -> NSButton? {
            guard let sheet = window.attachedSheet, sheet.isVisible, let view = sheet.contentView,
                  let control = button(title, in: view), control.isEnabled,
                  alongside.allSatisfy({ button($0, in: view) != nil }) else { return nil }
            return control
        }
        func requestQuit(using driver: RecorderQuitDriver) throws {
            activeDriver = driver
            quitPending = true
            driver.start()
            NSApp.terminate(nil)
            // Also support AppKit returning before the asynchronous reply.
            // This wait is outside the timer callback and nested Quit loop.
            if !driver.finished && driver.failure == nil {
                _ = wait { driver.finished || driver.failure != nil }
            }
            driver.stop()
            if let failure = driver.failure { throw failure }
            try require(driver.finished, "The owning Quit driver did not finish")
            activeDriver = nil
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
            activeDriver?.stop()
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
        try requestQuit(using: RecorderQuitDriver(window: window, release: { release.signal() }) {
            guard let control = readyButton("Cancel", alongside: ["Save…", "Discard Changes"]) else { return false }
            control.performClick(nil)
            return true
        })
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

        var secondPhase = 0
        try requestQuit(using: RecorderQuitDriver(window: window, release: { release.signal() }) {
            if secondPhase == 0 {
                guard let control = readyButton("Discard Changes", alongside: ["Save…", "Cancel"]) else { return false }
                secondPhase = 1
                control.performClick(nil)
                return false
            }
            guard let control = readyButton("Cancel", alongside: ["Save", "Don't Save"]) else { return false }
            control.performClick(nil)
            return true
        })
        try require(wait { usable() }, "Image Cancel did not cancel AppKit's second pending Quit")
        quitPending = false
        expect(try proxy.replies.count == 2 && proxy.replies.allSatisfy { $0 == .terminateLater }
            && preserved(current, changedA, rows: 2), "image Cancel after Recorder Discard preserves the same recording and restores Quit usability")
        try require(!failed, "A cancelled-Quit acceptance check failed")

        let entered = DispatchSemaphore(value: 0)
        var finalPhase = 0
        var renderHeld = false
        try requestQuit(using: RecorderQuitDriver(window: window, release: { release.signal() }) {
            switch finalPhase {
            case 0:
                guard let control = readyButton("Discard Changes", alongside: ["Save…", "Cancel"]) else { return false }
                finalPhase = 1
                control.performClick(nil)
            case 1:
                guard readyButton("Don't Save", alongside: ["Save", "Cancel"]) != nil else { return false }
                expect(proxy.replies.count == 3 && proxy.replies.allSatisfy { $0 == .terminateLater }
                    && adoc.recorderContentCheckpoint() == current && adoc.recorder.isRecording,
                       "the next actual Quit asks for Recorder consent again")
                a.canvas.enqueueRenderBarrier { entered.signal(); _ = release.wait(timeout: .now() + 20) }
                finalPhase = 2
            case 2:
                if !renderHeld { renderHeld = entered.wait(timeout: .now()) == .success }
                guard renderHeld, let control = readyButton("Don't Save", alongside: ["Save", "Cancel"]) else { return false }
                finalPhase = 3
                control.performClick(nil)
            default:
                guard a.closeStarted && adoc.isClosing else { return false }
                expect(!gone(adoc.image) && !b.closeStarted && owner.documents.count == 2 && closeOrder.isEmpty
                    && proxy.willTerminateCalls == 0, "final Quit holds A alive and waits before advancing to clean B")
                expect(try state(bdoc) == nativeB && Data(contentsOf: aURL) == savedA && Data(contentsOf: bURL) == savedB,
                       "B and both saved sources are unchanged immediately before the final native drain")
                finalCloseReady = !failed
                release.signal()
                return true
            }
            return false
        })
        // Success exits inside AppKit after reply(toApplicationShouldTerminate:).
        // A return or a timeout is a failure, even if windows happened to close.
        _ = wait { proxy.willTerminateCalls > 0 }
        throw NSError(domain: "RecorderQuitUI", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Actual application termination did not exit the process"])
    }
}
