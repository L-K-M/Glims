import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderConsentUI(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        struct NativeState: Equatable {
            let info: EngineSession.ImageInfo
            let pixels: Data
            let history: EngineSession.History
        }

        let directory = work.appendingPathComponent("recorder-consent-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var controller: DocumentWindowController?
        var looseImage: Int32?
        let release = DispatchSemaphore(value: 0)
        var checks = 0
        var complete = false

        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Recorder consent: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecorderConsentUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for subview in view.subviews {
                if let match = button(title, in: subview) { return match }
            }
            return nil
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            release.signal()
            if let controller {
                let document = controller.imageDocument
                if let window = controller.window {
                    _ = wait {
                        if let sheet = window.attachedSheet {
                            if let panel = sheet as? NSSavePanel { panel.cancel(nil) }
                            else { window.endSheet(sheet, returnCode: .cancel) }
                            return false
                        }
                        return document.pendingWork == 0
                    }
                    window.close()
                    expect(wait { window.attachedSheet == nil && !window.isVisible }, "owned window and sheets close")
                }
                expect(wait { document.pendingWork == 0 && gone(document.image) }, "accepted work drains and the owned image closes")
                documents.items.removeAll { $0 === document }
            }
            if let looseImage { try? session.closeImage(looseImage) }
            try? FileManager.default.removeItem(at: directory)
            expect((looseImage.map(gone) ?? true) && !FileManager.default.fileExists(atPath: directory.path), "temporary image and directory are removed")
            expect(complete, "all close and replacement decisions completed")
            print("     recorder-consent-ui checks: \(checks)")
        }

        var pixels: [UInt8] = []
        for y in 0..<17 {
            for x in 0..<23 {
                pixels.append(contentsOf: [UInt8(x * 9), UInt8(y * 13), UInt8(x + y * 11), 255])
            }
        }
        let image = try session.newImage(pixels: ClipboardImage(width: 23, height: 17, pixels: Data(pixels), origin: .zero))
        looseImage = image
        let document = try ImageDocument(session: session, image: image, name: "Recorder consent image")
        let owner = DocumentWindowController(document: document)
        controller = owner
        documents.items.append(document)
        looseImage = nil
        owner.showWindow(nil)
        guard let window = owner.window else {
            throw NSError(domain: "RecorderConsentUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "The document window is absent"])
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        try require(wait { window.isKeyWindow && owner.canPresentRecorderFileSheet && document.pendingWork == 0 },
                    "The document window did not become ready")

        func native() throws -> NativeState {
            try NativeState(info: session.info(image), pixels: session.copyPixels(image, merged: true).pixels,
                            history: session.history(image))
        }
        func drained() -> Bool {
            document.pendingWork == 0 && document.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy
        }
        func sheetButton(_ title: String) -> NSButton? {
            guard let view = window.attachedSheet?.contentView else { return nil }
            return button(title, in: view)
        }
        func click(_ title: String, otherButtons: [String]) throws {
            try require(wait {
                window.attachedSheet?.isVisible == true && sheetButton(title)?.isEnabled == true
                    && otherButtons.allSatisfy { sheetButton($0) != nil }
            }, "Expected a sheet with \(([title] + otherButtons).joined(separator: ", "))")
            guard let control = sheetButton(title) else {
                throw NSError(domain: "RecorderConsentUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "The \(title) button disappeared"])
            }
            control.performClick(nil)
        }
        func matchesTransforms(_ transforms: [EngineSession.Transform]) -> Bool {
            guard document.recorder.records.count == transforms.count else { return false }
            return document.recorder.records.enumerated().allSatisfy { index, row in
                guard row.ordinal == index, case .success(.transformImage(let transform)) = row.resolution else { return false }
                return transform == transforms[index]
            }
        }

        try document.startRecording()
        let metadata = document.recorderFileMetadata
        let entered = DispatchSemaphore(value: 0)
        document.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
        try require(entered.wait(timeout: .now() + 3) == .success, "The input hold did not start")
        document.transformImage(.rotate90)
        let pending = document.recorderContentCheckpoint()
        var firstClose: [Bool] = []
        owner.requestClose { firstClose.append($0) }
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        expect(document.pendingWork > 0 && document.recorder.pendingCount == 1 && document.recorder.records.isEmpty
            && document.recorder.isRecording && document.hasUnsavedRecordingChanges && !owner.closeStarted
            && firstClose.isEmpty && window.attachedSheet == nil,
               "a real close waits for the accepted recording command without opening an early sheet")
        release.signal()
        try require(wait { drained() && sheetButton("Discard Changes") != nil }, "Close consent did not appear after drain")
        let settled = document.recorderContentCheckpoint()
        let afterRotate = try native()
        expect(settled != pending && matchesTransforms([.rotate90]) && document.recorder.isRecording
            && document.recorderFileMetadata == metadata && afterRotate.info.width == 17 && afterRotate.info.height == 23,
               "the waiting close sees the settled native command in the original active recording")
        try click("Cancel", otherButtons: ["Save…", "Discard Changes"])
        try require(wait { !firstClose.isEmpty && owner.canPresentRecorderFileSheet }, "Recorder Cancel did not finish the close request")
        expect(try firstClose == [false] && !owner.closeStarted && !document.isClosing && window.isVisible
            && document.recorderContentCheckpoint() == settled && document.recorderFileMetadata == metadata
            && document.recorder.isRecording && document.hasUnsavedRecordingChanges && matchesTransforms([.rotate90])
            && native() == afterRotate, "Recorder Cancel preserves the original active recording, native image and window")

        document.transformImage(.flipHorizontal)
        try require(wait { drained() }, "A later command did not drain")
        let current = document.recorderContentCheckpoint()
        let nativeBeforeDecisions = try native()
        let expected: [EngineSession.Transform] = [.rotate90, .flipHorizontal]
        expect(current != settled && matchesTransforms(expected) && document.recorderFileMetadata == metadata
            && document.recorder.isRecording && nativeBeforeDecisions.pixels != afterRotate.pixels,
               "the same active epoch records the next real native edit at ordinal one")

        func preserved(recording: Bool) throws -> Bool {
            try !owner.closeStarted && !document.isClosing && window.isVisible && window.attachedSheet == nil
                && document.recorder.isRecording == recording && document.hasUnsavedRecordingChanges
                && document.recorderContentCheckpoint() == current && document.recorderFileMetadata == metadata
                && matchesTransforms(expected) && native() == nativeBeforeDecisions
        }

        var saveClose: [Bool] = []
        owner.requestClose { saveClose.append($0) }
        try click("Save…", otherButtons: ["Discard Changes", "Cancel"])
        try require(wait { window.attachedSheet?.isVisible == true && window.attachedSheet is NSSavePanel },
                    "Recorder Save did not open its actual NSSavePanel")
        guard let panel = window.attachedSheet as? NSSavePanel else {
            throw NSError(domain: "RecorderConsentUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "The native Save panel disappeared"])
        }
        let cancelledURL = directory.appendingPathComponent("Cancelled.glimsrecording")
        panel.directoryURL = directory
        panel.nameFieldStringValue = cancelledURL.lastPathComponent
        expect(panel.title == "Save Recording" && saveClose.isEmpty && document.recorder.isRecording
            && document.recorderContentCheckpoint() == current && document.hasUnsavedRecordingChanges,
               "choosing Recorder Save opens its native panel while the recording remains active and dirty")
        panel.cancel(nil)
        try require(wait { !saveClose.isEmpty && owner.canPresentRecorderFileSheet }, "Save panel Cancel did not finish the close request")
        expect(try saveClose == [false] && preserved(recording: true)
            && !FileManager.default.fileExists(atPath: cancelledURL.path),
               "cancelling NSSavePanel leaves the active dirty recording intact and writes no file")

        var discardClose: [Bool] = []
        owner.requestClose { discardClose.append($0) }
        try click("Discard Changes", otherButtons: ["Save…", "Cancel"])
        try require(wait { sheetButton("Don't Save") != nil }, "Recorder Discard did not reach the separate image prompt")
        expect(discardClose.isEmpty && document.recorderContentCheckpoint() == current && document.hasUnsavedRecordingChanges
            && document.recorder.isRecording && matchesTransforms(expected), "Recorder Discard authorizes close without clearing the recording")
        try click("Cancel", otherButtons: ["Save", "Don't Save"])
        try require(wait { !discardClose.isEmpty && owner.canPresentRecorderFileSheet }, "Image Cancel did not finish the close request")
        expect(try discardClose == [false] && preserved(recording: true), "cancelling image close after Recorder Discard preserves the recording")

        var retriedClose: [Bool] = []
        owner.requestClose { retriedClose.append($0) }
        try click("Cancel", otherButtons: ["Save…", "Discard Changes"])
        try require(wait { !retriedClose.isEmpty && owner.canPresentRecorderFileSheet }, "Recorder consent did not finish on the next close attempt")
        expect(try retriedClose == [false] && preserved(recording: true), "a new close asks for Recorder consent again after image Cancel")

        try document.stopRecording()
        for action in [RecorderPaletteAction.record, .clear] {
            try owner.presentRecorderFileAction(action)
            try click("Cancel", otherButtons: ["Save…", "Discard Changes"])
            try require(wait { owner.canPresentRecorderFileSheet }, "\(action.title) replacement consent did not finish")
            expect(try preserved(recording: false), "cancelling \(action.title) keeps the same stopped dirty recording")
        }
        complete = true
    }
}
