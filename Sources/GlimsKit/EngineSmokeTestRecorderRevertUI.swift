import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderRevertUI(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        struct State: Equatable {
            let info: EngineSession.ImageInfo
            let pixels: Data
            let history: EngineSession.History
        }
        let app = AppController()
        let directory = work.appendingPathComponent("recorder-revert", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Original.xcf")
        var owned: [DocumentWindowController] = []
        var loose: [Int32] = []
        var checks = 0
        var completed = false
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Recorder Revert: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "RecorderRevertUI", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let value = view as? NSButton, value.title == title { return value }
            for child in view.subviews { if let value = button(title, in: child) { return value } }
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
        defer {
            for controller in app.documents where !owned.contains(where: { $0 === controller }) { owned.append(controller) }
            for controller in owned {
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                    _ = wait { window.attachedSheet == nil }
                }
                controller.closeDiscardingChanges()
            }
            expect(wait { owned.allSatisfy { $0.imageDocument.pendingWork == 0 && gone($0.imageDocument.image) } },
                   "accepted work drains and every owned native image closes")
            expect(owned.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "every owned window and sheet closes")
            for image in loose { try? session.closeImage(image) }
            documents.items.removeAll { document in owned.contains { $0.imageDocument === document } }
            try? FileManager.default.removeItem(at: directory)
            expect(!FileManager.default.fileExists(atPath: directory.path), "private saved source is removed")
            expect(completed, "all three actual Revert decisions finished")
            print("     recorder-revert-ui checks: \(checks)")
        }
        func host(_ image: Int32, _ name: String, source: URL? = nil) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: image, name: name, openedFrom: source)
            documents.items.append(document)
            app.open(document)
            guard let controller = app.documents.first(where: { $0.imageDocument === document }) else {
                throw NSError(domain: "RecorderRevertUI", code: 2)
            }
            owned.append(controller)
            loose.removeAll { $0 == image }
            return controller
        }
        var bytes: [UInt8] = []
        for y in 0..<17 { for x in 0..<23 { bytes.append(contentsOf: [UInt8(9 * x), UInt8(13 * y), UInt8(x + 11 * y), 255]) } }
        let seed = try session.newImage(pixels: ClipboardImage(width: 23, height: 17, pixels: Data(bytes), origin: .zero))
        loose.append(seed)
        let originalPixels = try session.copyPixels(seed, merged: true).pixels
        try session.save(seed, to: source.path)
        try session.closeImage(seed)
        loose.removeAll { $0 == seed }
        let savedBytes = try Data(contentsOf: source)
        let image = try session.openImage(path: source.path)
        loose.append(image)
        let a = try host(image, "Original.xcf", source: source)
        let otherImage = try session.newImage(width: 19, height: 13)
        loose.append(otherImage)
        let b = try host(otherImage, "Unchanged B")
        guard let window = a.window else { throw NSError(domain: "RecorderRevertUI", code: 3) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        let document = a.imageDocument
        try require(wait { window.isKeyWindow && document.pendingWork == 0 && b.imageDocument.pendingWork == 0
            && !EngineActivity.shared.isBusy }, "The real owning documents did not become ready")
        let bState = try state(b.imageDocument)
        let bRecording = b.imageDocument.recorderContentCheckpoint()
        try document.startRecording()
        document.transformImage(.rotate90)
        try require(wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 }, "The recorded edit did not settle")
        try document.renameRecording("Keep this recording")
        let checkpoint = document.recorderContentCheckpoint()
        let metadata = document.recorderFileMetadata
        let changed = try state(document)
        expect(changed.info.width == 17 && changed.info.height == 23 && document.hasUnsavedChanges
            && document.hasUnsavedRecordingChanges && document.recorder.records.count == 1,
               "the saved image has both a real edit and a dirty named recording")
        func click(_ title: String, alongside: [String]) throws {
            try require(wait {
                guard let view = window.attachedSheet?.contentView else { return false }
                return window.attachedSheet?.isVisible == true && button(title, in: view)?.isEnabled == true
                    && alongside.allSatisfy { button($0, in: view) != nil }
            }, "Expected the owned \(title) sheet with \(alongside)")
            guard let view = window.attachedSheet?.contentView, let control = button(title, in: view) else {
                throw NSError(domain: "RecorderRevertUI", code: 4)
            }
            control.performClick(nil)
        }
        func preserved() throws -> Bool {
            try app.documents.count == 2 && app.documents.contains { $0 === a }
                && !document.isClosing && !a.closeStarted && !a.revertIsPending && window.isVisible
                && document.recorderContentCheckpoint() == checkpoint && document.recorderFileMetadata == metadata
                && document.recorder.isRecording && document.hasUnsavedRecordingChanges && state(document) == changed
                && Data(contentsOf: source) == savedBytes && state(b.imageDocument) == bState
                && b.imageDocument.recorderContentCheckpoint() == bRecording
        }
        a.revertDocument(nil)
        try click("Cancel", alongside: ["Revert"])
        try require(wait { window.attachedSheet == nil && a.canPresentRecorderFileSheet }, "Image Cancel did not finish")
        expect(try preserved(), "image Cancel preserves A, its active recording, the saved file and B")
        a.revertDocument(nil)
        try click("Revert", alongside: ["Cancel"])
        try click("Cancel", alongside: ["Save…", "Discard Changes"])
        try require(wait { window.attachedSheet == nil && a.canPresentRecorderFileSheet }, "Recorder Cancel did not finish")
        expect(try preserved(), "Recorder Cancel after image consent preserves the same recording and both images")
        a.revertDocument(nil)
        try click("Revert", alongside: ["Cancel"])
        try click("Discard Changes", alongside: ["Save…", "Cancel"])
        try require(wait { !app.documents.contains { $0 === a } && app.documents.count == 2 && gone(image) },
                    "The accepted Revert did not adopt and close exactly once")
        guard let replacement = app.documents.first(where: { $0 !== b }) else { throw NSError(domain: "RecorderRevertUI", code: 5) }
        owned.append(replacement)
        documents.items.append(replacement.imageDocument)
        let restored = replacement.imageDocument
        try require(wait { restored.pendingWork == 0 }, "The replacement did not settle")
        expect(try restored !== document && restored.image != image && restored.fileState.nativeURL == source
            && !restored.hasUnsavedChanges && restored.undoInfo.undoCount == 0
            && session.copyPixels(restored.image, merged: true).pixels == originalPixels,
               "accepted Discard opens the saved pixels in one clean replacement with fresh history")
        expect(restored.recorder.records.isEmpty && !restored.recorder.isRecording && !restored.hasUnsavedRecordingChanges
            && restored.recorderFileMetadata.recordingID != metadata.recordingID && a.closeStarted && !window.isVisible,
               "the replaced recording is absent from the new document and its old window closes")
        expect(try Data(contentsOf: source) == savedBytes && state(b.imageDocument) == bState
            && b.imageDocument.recorderContentCheckpoint() == bRecording,
               "accepted Revert never writes its source or changes B")
        completed = true
    }
}
