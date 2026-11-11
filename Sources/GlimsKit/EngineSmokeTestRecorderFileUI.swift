import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderFileUI(_ session: EngineSession, work: URL, documents: DocumentList,
                                       driveFilePickers: Bool) throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "Recorder files: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "RecorderFileUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(seconds: TimeInterval = 12, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func views<T: NSView>(_ view: NSView, _ kind: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, kind) }
        }

        var owned: [DocumentWindowController] = []
        var unowned: [Int32] = []
        let fileURL = work.appendingPathComponent("Recorder UI file.glimsrecording")
        let inputURL = work.appendingPathComponent("Explicit targets.glimsrecording")
        defer {
            for controller in owned {
                if let window = controller.window, let sheet = window.attachedSheet {
                    if let panel = sheet as? NSSavePanel { panel.cancel(nil) }
                    else { window.endSheet(sheet, returnCode: .cancel) }
                    _ = wait { window.attachedSheet == nil }
                }
                controller.window?.close()
            }
            expect(wait { owned.allSatisfy { $0.imageDocument.pendingWork == 0 && (try? session.info($0.imageDocument.image)) == nil } },
                   "all accepted work and owned images close")
            expect(owned.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "all owned windows and sheets close")
            for image in unowned { try? session.closeImage(image) }
            documents.items.removeAll { document in owned.contains { $0.imageDocument === document } }
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: inputURL)
            print("     recorder-file-ui checks: \(checks)")
        }

        func host(_ image: Int32, _ name: String,
                  pickerDefaults: RecorderFileCoordinator.PickerDefaults? = nil) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: image, name: name)
            let controller = DocumentWindowController(document: document, recorderPickerDefaults: pickerDefaults)
            owned.append(controller)
            documents.items.append(document)
            unowned.removeAll { $0 == image }
            controller.showWindow(nil)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            try require(wait { document.pendingWork == 0 }, "image work did not settle")
            return controller
        }
        let imageA = try session.newImage(width: 56, height: 40)
        unowned.append(imageA)
        let imageB = try session.newImage(width: 31, height: 23)
        unowned.append(imageB)
        guard let base = try session.layers(imageA).first?.id else { throw NSError(domain: "RecorderFileUI", code: 2) }
        let group = try session.createGroup(image: imageA, index: 0, name: String(repeating: "Long group name ", count: 12))
        let sub = try session.createGroup(image: imageA, parent: group, index: 0, name: "Child of long group")
        try session.reparentLayer(base, image: imageA, toParent: sub, index: 0)
        try session.changeLayer(base, image: imageA, .init(name: "Duplicate name"))
        guard let later = try session.layerCommand(.new, image: imageA) else { throw NSError(domain: "RecorderFileUI", code: 3) }
        try session.changeLayer(later, image: imageA, .init(name: "Later unique target"))
        let a = try host(imageA, "Recording owner A", pickerDefaults: driveFilePickers
            ? .init(directory: work, saveFilename: fileURL.lastPathComponent) : nil)
        let b = try host(imageB, "Other image B")
        guard let windowA = a.window, let windowB = b.window else { throw NSError(domain: "RecorderFileUI", code: 4) }
        NSApp.activate(ignoringOtherApps: true)
        windowA.makeKeyAndOrderFront(nil)
        windowA.makeMain()
        try require(wait { windowA.isKeyWindow && a.canPresentRecorderFileSheet }, "owner A never became ready")
        let adoc = a.imageDocument, bdoc = b.imageDocument
        let originalB = bdoc.recorderFileMetadata
        let baselineA = try session.undoInfo(imageA)
        let nativePixelsA = try session.copyPixels(imageA, merged: true).pixels
        let originalA = adoc.recorderFileMetadata
        let menu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Recorder")?.submenu
        expect([RecorderPaletteAction.nameRecording, .saveRecording, .loadRecording].allSatisfy { action in
            menu?.items.contains(where: { $0.tag == action.rawValue && $0.title == action.title }) == true
        }, "Edit menu includes the actual naming and file commands")

        try a.presentRecorderFileAction(.nameRecording)
        try require(wait { windowA.attachedSheet != nil }, "Name did not attach an owner sheet")
        guard let nameView = windowA.attachedSheet?.contentView,
              let name = views(nameView, NSTextField.self).first(where: { $0.accessibilityLabel() == "Recording name" }),
              let confirm = views(nameView, NSButton.self).first(where: { $0.title == "Name" }) else {
            throw NSError(domain: "RecorderFileUI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Name controls are absent"])
        }
        windowB.makeKeyAndOrderFront(nil)
        windowB.makeMain()
        name.stringValue = "Named in its original window"
        confirm.performClick(nil)
        try require(wait { a.canPresentRecorderFileSheet }, "Name sheet did not finish")
        expect(adoc.recorderFileMetadata.name == "Named in its original window" &&
               adoc.recorderFileMetadata.recordingID == originalA.recordingID &&
               bdoc.recorderFileMetadata == originalB && adoc.hasUnsavedRecordingChanges,
               "naming while B is front changes only A's intrinsic title and keeps its identity")

        try a.presentRecorderFileAction(.saveRecording)
        try require(wait { windowA.attachedSheet is NSSavePanel }, "Save did not attach a native file panel")
        guard let cancelledSave = windowA.attachedSheet as? NSSavePanel else { throw NSError(domain: "RecorderFileUI", code: 6) }
        cancelledSave.cancel(nil)
        try require(wait { a.canPresentRecorderFileSheet }, "cancelled file panel did not finish")
        expect(adoc.hasUnsavedRecordingChanges && !FileManager.default.fileExists(atPath: fileURL.path),
               "cancelling the native Save panel leaves the recording dirty")

        if driveFilePickers {
            // The earlier Name check deliberately made B key. A person now
            // operating the native picker needs the owner's actual key focus.
            windowA.makeKeyAndOrderFront(nil)
            windowA.makeMain()
            try require(wait { windowA.isKeyWindow }, "the picker owner did not receive keyboard focus")
            try a.presentRecorderFileAction(.saveRecording)
            try require(wait { windowA.attachedSheet?.isVisible == true && windowA.attachedSheet is NSSavePanel },
                        "second native Save panel did not attach")
            FileHandle.standardError.write(Data("Recorder picker: save only to \(fileURL.path)\n".utf8))
            try require(wait(seconds: 90) { a.canPresentRecorderFileSheet && adoc.pendingWork == 0 },
                        "accepted native Save did not finish")
            let written = try RecorderFileCodec.decode(Data(contentsOf: fileURL))
            expect(written.name == "Named in its original window" && written.recordingID == originalA.recordingID
                    && !adoc.hasUnsavedRecordingChanges,
                   "accepting the native Save panel writes A's revision under a separate filename")
            try adoc.renameRecording("Named after saving")
        }

        func openAfterDiscard() throws {
            try a.presentRecorderFileAction(.loadRecording)
            try require(wait { windowA.attachedSheet != nil }, "dirty Load did not ask for consent")
            guard let replacementView = windowA.attachedSheet?.contentView,
                  let discard = views(replacementView, NSButton.self).first(where: { $0.title == "Discard Changes" }) else {
                throw NSError(domain: "RecorderFileUI", code: 7, userInfo: [NSLocalizedDescriptionKey: "Replacement consent controls are absent"])
            }
            discard.performClick(nil)
            try require(wait { windowA.attachedSheet?.isVisible == true && windowA.attachedSheet is NSOpenPanel },
                        "Load did not attach a native Open panel after consent")
        }
        let dirtyBeforeOpen = adoc.recorderFileMetadata
        try openAfterDiscard()
        expect(adoc.hasUnsavedRecordingChanges && adoc.recorderFileMetadata == dirtyBeforeOpen,
               "Discard grants permission without clearing the old recording while Open is pending")
        (windowA.attachedSheet as? NSOpenPanel)?.cancel(nil)
        try require(wait { a.canPresentRecorderFileSheet }, "cancelled Open panel did not finish")
        expect(adoc.hasUnsavedRecordingChanges && adoc.recorderFileMetadata.recordingID == originalA.recordingID,
               "cancelling Open after Discard preserves the old recording")

        let firstSymbol = UUID(), secondSymbol = UUID(), unused = UUID()
        func symbol(_ id: UUID, _ name: String) -> RecorderFileValue.Symbol {
            .init(id: id, description: .init(name: name, kind: .pixel, ancestors: [], siblingIndex: 0,
                bounds: .init(x: 0, y: 0, width: 56, height: 40)))
        }
        let file = RecorderFileValue(recordingID: UUID(), name: "Explicit targets", origin: originalA.origin,
            symbols: [symbol(firstSymbol, "Duplicate name"), symbol(secondSymbol, "Duplicate name"), symbol(unused, "Unused")],
            records: [
                .init(ordinal: 0, outcome: .success(.layerProperties(.init(name: "Changed one", visible: nil, opacity: nil, mode: nil)), .layer(firstSymbol))),
                .init(ordinal: 1, outcome: .success(.layerProperties(.init(name: "Changed two", visible: nil, opacity: nil, mode: nil)), .layer(secondSymbol)))
            ])
        let prepared = try RecorderFileSemanticBridge.prepare(file)
        let checkpoint = try adoc.recorderInstallCheckpoint()
        var selection: [UUID: ImageDocument.RecorderInstallChoice]?
        // The normal regression drives the binding UI without a machine's
        // file-panel service. The opt-in run exercises real Save and Open;
        // the external driver must verify the private destination before OK.
        var directSheet: RecorderBindingSheetController?
        if driveFilePickers {
            try RecorderFileCodec.encode(file).write(to: inputURL, options: .atomic)
            try openAfterDiscard()
            FileHandle.standardError.write(Data("Recorder picker: open only \(inputURL.path)\n".utf8))
            try require(wait(seconds: 90) {
                guard let sheet = windowA.attachedSheet, !(sheet is NSSavePanel),
                      let content = sheet.contentView else { return false }
                return views(content, NSTableView.self).first != nil
            }, "accepting the native Open panel did not reach the binding sheet")
            expect(adoc.hasUnsavedRecordingChanges && adoc.recorderFileMetadata == dirtyBeforeOpen,
                   "opening the real file still leaves the old revision in place until bindings are accepted")
        } else {
            directSheet = try RecorderBindingSheetController(file: prepared.file, document: adoc)
            directSheet?.begin(on: windowA) { selection = $0 }
        }
        guard let bindView = windowA.attachedSheet?.contentView,
              let table = views(bindView, NSTableView.self).first,
              let popup = views(bindView, NSPopUpButton.self).first,
              let load = views(bindView, NSButton.self).first(where: { $0.title == "Load Recording" }) else {
            throw NSError(domain: "RecorderFileUI", code: 8, userInfo: [NSLocalizedDescriptionKey: "Binding controls are absent"])
        }
        expect(table.numberOfRows == 2 && popup.indexOfSelectedItem == 0 && !load.isEnabled,
               "matching names and unused descriptions do not preselect or add a target")
        expect(Set(popup.itemTitles).count == popup.numberOfItems &&
               popup.itemTitles.contains(where: { $0.contains("Later unique target") }),
               "long ancestors cannot collapse a popup item or hide a later live choice")
        guard let laterItem = popup.itemTitles.firstIndex(where: { $0.contains("Later unique target") }),
              let action = popup.action else { throw NSError(domain: "RecorderFileUI", code: 9) }
        popup.selectItem(at: laterItem)
        _ = NSApp.sendAction(action, to: popup.target, from: popup)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        expect(popup.indexOfSelectedItem == 0 && !popup.itemTitles.contains(where: { $0.contains("Later unique target") }) &&
               !load.isEnabled, "one live choice cannot bind a second symbol")
        guard let baseItem = popup.itemTitles.firstIndex(where: { $0.contains("Duplicate name") }) else {
            throw NSError(domain: "RecorderFileUI", code: 10, userInfo: [NSLocalizedDescriptionKey: "Long ancestry hid the leaf target"])
        }
        popup.selectItem(at: baseItem)
        _ = NSApp.sendAction(action, to: popup.target, from: popup)
        expect(load.isEnabled, "complete distinct choices enable Load")
        load.performClick(nil)
        try require(wait { windowA.attachedSheet == nil }, "binding sheet did not finish")
        withExtendedLifetime(directSheet) {}
        if driveFilePickers {
            try require(wait { a.canPresentRecorderFileSheet && adoc.pendingWork == 0 },
                        "native Open and bound installation did not drain")
        } else {
            expect(selection == [firstSymbol: .layer(later), secondSymbol: .layer(base)],
                   "visible selections return the exact independent native IDs")
            if let selection {
                var result: Result<Void, Error>?
                adoc.installRecording(prepared, checkpoint: checkpoint, choices: selection) { result = $0 }
                try require(wait { result != nil && adoc.pendingWork == 0 }, "bound recording did not drain")
                if case .failure(let error)? = result { throw error }
            }
        }
        expect(adoc.recorderLoadedFile == file && bdoc.recorderFileMetadata == originalB && !adoc.hasUnsavedRecordingChanges,
               "explicit Load installs only A's recording and starts it clean")
        expect(try session.undoInfo(imageA) == baselineA && session.copyPixels(imageA, merged: true).pixels == nativePixelsA,
               "naming, file dialogs, binding and installation do not edit A's pixels or history")
        if driveFilePickers {
            try adoc.startReplay()
            try require(wait { adoc.replayStatus == .finished(total: 2) && adoc.pendingWork == 0 },
                        "replay of the recording opened through the picker did not complete")
            let layers = try session.layers(imageA)
            expect(layers.first(where: { $0.id == later })?.name == "Changed one" &&
                   layers.first(where: { $0.id == base })?.name == "Changed two" &&
                   bdoc.recorderFileMetadata == originalB,
                   "replay uses the two exact bound native layer IDs in A")
        }
    }
}
