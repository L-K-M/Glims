import AppKit

@MainActor
private final class InkBindingSheetReply {
    var calls = 0
    var choices: [UUID: ImageDocument.RecorderInstallChoice]?
}

private struct InkBindingNativeState: Equatable {
    let pixels: Data
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
    let selectedChannels: [Int32]
    let selectedLayers: [Int32]
}

@MainActor
extension EngineSmokeTest {
    /// Actual binding controls; native replay and all precisions have a separate fixture.
    static func exerciseRecorderInkBindings(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "Recorder ink bindings: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderInkBindings", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            try require(condition(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy }, "Image work did not drain")
        }
        func settleEvents(_ document: ImageDocument) throws {
            var delivered = false
            DispatchQueue.main.async { delivered = true }
            try wait({ delivered }, "Native setup events did not reach main")
            try drain(document)
        }
        func views<T: NSView>(in view: NSView, _ kind: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(in: $0, kind) }
        }
        func nativeState(_ image: Int32) throws -> InkBindingNativeState {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 12, height: 8))
            guard let pixels = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "RecorderInkBindings", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing rendered pixels"])
            }
            return try InkBindingNativeState(pixels: pixels, undo: session.undoInfo(image),
                history: session.history(image), selectedChannels: session.selectedItems(.channel, image: image),
                selectedLayers: session.selectedLayers(image))
        }
        func capturePNG(_ view: NSView, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            do {
                try require(!directory.isEmpty, "Artifact directory is empty")
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "RecorderInkBindings", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot capture sheet content"])
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw NSError(domain: "RecorderInkBindings", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot encode sheet PNG"])
                }
                try png.write(to: root.appendingPathComponent(name), options: .atomic)
                expect(true, "saved actual sheet artifact \(name)")
            } catch {
                expect(false, "sheet artifact \(name): \(error.localizedDescription)")
                throw error
            }
        }

        var controllers: [DocumentWindowController] = []
        var sheets: [RecorderBindingSheetController] = []
        var unownedImages: [Int32] = []
        defer {
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                    try? wait({ window.attachedSheet == nil }, "Owned binding sheet did not dismiss")
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            do {
                try wait({ controllers.allSatisfy {
                    $0.imageDocument.pendingWork == 0 && (try? session.info($0.imageDocument.image)) == nil
                } }, "Owned windows and native images did not drain")
            } catch { expect(false, "cleanup: \(error)") }
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "all owned windows and sheets close")
            documents.items.removeAll { doc in controllers.contains { $0.imageDocument === doc } }
            for image in unownedImages { try? session.closeImage(image) }
            expect(unownedImages.allSatisfy { (try? session.info($0)) == nil }, "all unhosted native images close")
            withExtendedLifetime(sheets) {}
            print("     recorder-ink-bindings checks: \(checks)")
        }

        for mode in [EngineSession.ColorMode.cmyk, .multichannel] {
            let label = mode == .cmyk ? "cmyk" : "multichannel"
            let image: Int32
            if mode == .cmyk {
                guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
                    throw NSError(domain: "RecorderInkBindings", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing generic CMYK profile"])
                }
                image = try session.newCmykImage(width: 12, height: 8, component: .u8, profileICC: profile)
            } else {
                image = try session.newMultichannelImage(width: 12, height: 8, component: .u8, channelCount: 4)
            }
            unownedImages.append(image)
            let nativeIDs = try session.channels(image).map(\.id)
            try require(nativeIDs.count == 4, "\(label): expected four canonical ink channels")
            for id in nativeIDs { try session.changeChannel(id, image: image, .init(name: "Same Ink")) }
            try session.channelCommand(.select, channel: nativeIDs[1], image: image)
            let document = try ImageDocument(session: session, image: image, name: "Ink \(label)")
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller)
            documents.items.append(document)
            unownedImages.removeAll { $0 == image }
            controller.showWindow(nil)
            guard let window = controller.window else {
                throw NSError(domain: "RecorderInkBindings", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Missing document window"])
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            try settleEvents(document)
            let initialNative = try nativeState(image)
            let initialMetadata = document.recorderFileMetadata
            let initialFile = document.recorderLoadedFile
            let initialBindings = document.recorderBindingDescriptions
            let symbol = UUID()
            let sourceIdentity = RecorderInkIdentity(mode: mode == .cmyk ? .cmyk : .multichannel,
                role: mode == .cmyk ? .cyan : .unspecified, uuid: UUID())
            let file = RecorderFileValue(recordingID: UUID(), name: "Ink binding \(label)",
                origin: .init(imageLabel: "Ink source", initialWidth: 12, initialHeight: 8),
                symbols: [.init(id: symbol, description: .init(name: "Same Ink", kind: .channel,
                    ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 12, height: 8)))],
                records: [.init(ordinal: 0, outcome: .success(
                    .editInk(.init(operation: .invert, intensity: 0, opacity: 1)),
                    .ink(symbol: symbol, identity: sourceIdentity)))])
            let prepared = try RecorderFileSemanticBridge.prepare(file)
            let eligible = (mode == .cmyk ? [nativeIDs[0]] : nativeIDs).map { ImageDocument.RecorderInstallChoice.channel($0) }
            let chosenID = mode == .cmyk ? nativeIDs[0] : nativeIDs[2]

            for cancelling in [true, false] {
                try settleEvents(document)
                let checkpoint = try document.recorderInstallCheckpoint()
                let reply = InkBindingSheetReply()
                let sheetController = try RecorderBindingSheetController(file: prepared.file, document: document)
                sheets.append(sheetController) // Controls and delegate use weak targets; retain through completion.
                sheetController.begin(on: window) { reply.calls += 1; reply.choices = $0 }
                try wait({ window.attachedSheet?.isVisible == true }, "Binding sheet did not become visible")
                guard let content = window.attachedSheet?.contentView else {
                    throw NSError(domain: "RecorderInkBindings", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing binding sheet content"])
                }
                let tables = views(in: content, NSTableView.self).filter { $0.identifier?.rawValue == "recorder-bind-symbols" }
                let popups = views(in: content, NSPopUpButton.self).filter { $0.identifier?.rawValue == "recorder-bind-choice" }
                let loads = views(in: content, NSButton.self).filter { $0.identifier?.rawValue == "recorder-bind-load" }
                let cancels = views(in: content, NSButton.self).filter { $0.title == "Cancel" }
                try require(tables.count == 1 && popups.count == 1 && loads.count == 1 && cancels.count == 1,
                            "Binding controls must each occur exactly once")
                let popup = popups[0], load = loads[0]
                expect(tables[0].numberOfRows == 1, "\(label): one required ink target")
                expect(popup.indexOfSelectedItem == 0 && popup.selectedItem?.representedObject == nil && !load.isEnabled,
                       "\(label): \(cancelling ? "initial" : "reopened") sheet requires an explicit choice")
                let actual = popup.itemArray.compactMap { $0.representedObject as? ImageDocument.RecorderInstallChoice }
                expect(actual == eligible && popup.numberOfItems == eligible.count + 1,
                       "\(label): exact eligible IDs survive identical display names")
                if cancelling { try capturePNG(content, name: "recorder-ink-bindings-\(label)-initial.png") }
                guard let index = popup.itemArray.firstIndex(where: {
                    ($0.representedObject as? ImageDocument.RecorderInstallChoice) == .channel(chosenID)
                }), let action = popup.action else {
                    throw NSError(domain: "RecorderInkBindings", code: 8,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected ink choice/action missing"])
                }
                popup.selectItem(at: index)
                try require(NSApp.sendAction(action, to: popup.target, from: popup), "Actual popup action was not delivered")
                expect(load.isEnabled && (popup.selectedItem?.representedObject as? ImageDocument.RecorderInstallChoice) == .channel(chosenID),
                       "\(label): explicit ink choice enables Load")
                if cancelling {
                    cancels[0].performClick(nil)
                    try wait({ window.attachedSheet == nil && reply.calls > 0 }, "Cancel did not complete")
                    try settleEvents(document)
                    expect(reply.calls == 1 && reply.choices == nil, "\(label): Cancel completes exactly once without choices")
                    expect(document.recorderFileMetadata == initialMetadata && document.recorderLoadedFile == initialFile &&
                        document.recorderBindingDescriptions == initialBindings && document.recorder.records.isEmpty,
                        "\(label): Cancel preserves the existing recording")
                    expect(try nativeState(image) == initialNative, "\(label): choosing and cancelling preserve pixels, history and selection")
                } else {
                    try capturePNG(content, name: "recorder-ink-bindings-\(label)-selected.png")
                    load.performClick(nil)
                    try wait({ window.attachedSheet == nil && reply.calls > 0 }, "Load did not complete")
                    try settleEvents(document)
                    let expected: [UUID: ImageDocument.RecorderInstallChoice] = [symbol: .channel(chosenID)]
                    expect(reply.calls == 1 && reply.choices == expected, "\(label): Load returns exactly the explicitly chosen ID")
                    guard let choices = reply.choices else {
                        throw NSError(domain: "RecorderInkBindings", code: 9,
                                      userInfo: [NSLocalizedDescriptionKey: "Load returned no choices"])
                    }
                    var result: Result<Void, Error>?
                    var completions = 0
                    document.installRecording(prepared, checkpoint: checkpoint, choices: choices) {
                        completions += 1
                        result = $0
                    }
                    try wait({ result != nil && document.pendingWork == 0 }, "Ink recording installation did not drain")
                    guard let result else {
                        throw NSError(domain: "RecorderInkBindings", code: 10,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing install result"])
                    }
                    try result.get()
                    expect(completions == 1 && document.recorderLoadedFile == file &&
                        document.recorderBindingDescriptions[0] == .ink(symbol: symbol, identity: sourceIdentity),
                        "\(label): explicit choices install the intact source recording once")
                    expect(try nativeState(image) == initialNative, "\(label): installation preserves every displayed pixel, history and selection")
                }
            }
        }
    }
}
