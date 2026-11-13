import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseLabLevels(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-levels: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "LabLevelsSmoke", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(30)
            repeat {
                EngineSmokeTestHost.pumpEvents(for: 0.01)
                if condition() {
                    EngineSmokeTestHost.pumpEvents(for: 0.01)
                    if condition() { return }
                }
            } while Date() < deadline
            try require(false, message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Owned work drains")
        }
        func render(_ image: Int32) throws -> Data {
            let pixels = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let bytes = pixels.dataProvider?.data as Data? else {
                throw NSError(domain: "LabLevelsSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No rendered pixels"])
            }
            return bytes
        }
        func menuItem(_ name: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if (item.representedObject as? NativeFilterCommand)?.operation.name == name { return item }
                if let child = item.submenu, let found = menuItem(name, in: child) { return found }
            }
            return nil
        }
        func ready(_ controller: DocumentWindowController) throws {
            try wait({ controller.labLevelsPanel?.applyButton.isEnabled == true &&
                       controller.canvas.labLevelsPreviewIsCurrent &&
                       controller.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy },
                     "Levels panel and latest canvas preview become current")
        }
        func draft(_ panel: InkLevelsPanel, field: NSTextField, text: String,
                   publish: Bool = true) throws -> NSTextView {
            panel.window?.makeKeyAndOrderFront(nil)
            panel.window?.makeFirstResponder(field)
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Numeric field editor becomes active")
            let editor = field.currentEditor() as! NSTextView
            editor.string = text
            field.stringValue = text
            if publish {
                panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            return editor
        }
        func geometry(_ panel: InkLevelsPanel) throws {
            guard let window = panel.window, let content = window.contentView else {
                return try require(false, "Missing visible panel")
            }
            content.layoutSubtreeIfNeeded()
            expect(window.isVisible, "actual Levels panel is visible")
            for control in [panel.lowInputField, panel.highInputField, panel.gammaField,
                            panel.lowOutputField, panel.highOutputField, panel.clampInputButton,
                            panel.clampOutputButton, panel.resetButton, panel.applyButton, panel.cancelButton] as [NSView] {
                let rect = control.convert(control.bounds, to: content)
                expect(!control.isHiddenOrHasHiddenAncestor && rect.width > 0 && rect.height > 0 &&
                       rect.minX >= -1 && rect.minY >= -1 && rect.maxX <= content.bounds.maxX + 1 &&
                       rect.maxY <= content.bounds.maxY + 1, "\(control.accessibilityLabel() ?? "control") fits the panel")
            }
        }
        func capturePanel(_ panel: InkLevelsPanel, name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
                  let content = panel.window?.contentView?.superview else { return }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                return try require(false, "No panel capture")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return try require(false, "No PNG panel capture")
            }
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        func centerPixel(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            try require(made, "Preview pixels can be normalized")
            return bytes
        }
        func setAffine(_ controller: DocumentWindowController, role: EngineSession.LabAxisRole) throws {
            guard let panel = controller.labLevelsPanel else {
                return try require(false, "Missing Levels panel for affine edit")
            }
            // These physical endpoints represent normalized .25 and .75.
            _ = try draft(panel, field: panel.lowOutputField, text: role == .lightness ? "25" : "-64.25")
            try ready(controller)
            _ = try draft(panel, field: panel.highOutputField, text: role == .lightness ? "75" : "63.25")
            try ready(controller)
            _ = try draft(panel, field: panel.gammaField, text: "1")
            try ready(controller)
        }
        let settings = EngineSession.LabLevelsSettings(value: .init(lowInput: 0, highInput: 1,
            gamma: 1, lowOutput: 0.25, highOutput: 0.75), clampInput: false, clampOutput: false)
        var controllers: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var directTokens: [(ImageDocument, UInt64)] = []
        var errors: [String] = []
        func openDocument(_ image: Int32, name: String) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: image, name: name)
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller)
            nativeOnly.removeAll { $0 == image }
            documents.items.append(document)
            document.onError = { errors.append($0) }
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            return controller
        }
        defer {
            for (document, token) in directTokens {
                document.endLabLevelsPreview(token)
                document.filterPreviewIsOpen = false
            }
            for controller in controllers {
                controller.labLevelsPanel?.cancel()
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            let owned = controllers.map(\.imageDocument)
            do {
                try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil }
                           && !EngineActivity.shared.isBusy }, "Owned Lab Levels images close")
            } catch { expect(false, "cleanup: \(error)") }
            for image in nativeOnly {
                do { try session.closeImage(image) } catch { expect(false, "native cleanup: \(error)") }
            }
            expect(controllers.allSatisfy { $0.labLevelsPanel == nil && $0.window?.attachedSheet == nil },
                   "cleanup leaves no owned panel or sheet")
            expect(errors.isEmpty, "no unexpected document errors: \(errors)")
            documents.items.removeAll { candidate in owned.contains { candidate === $0 } }
        }
        try require(session.supportsLabLevelSnapshots, "Producer supports Lab Levels snapshots")
        guard let menu = NSApp.mainMenu else { return try require(false, "Missing app menu") }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        NativeFilterMenus.install(operations, in: menu)
        guard let operation = NativeFilterCatalog.shared.operation(named: "gimp:levels"),
              let levelsItem = menuItem("gimp:levels", in: menu),
              let ordinaryItem = menuItem("gegl:invert-gamma", in: menu) else {
            return try require(false, "Missing adjustment menu entries")
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for role in 0..<3 {
                let image = try session.newLabImage(width: 32, height: 24, component: component)
                nativeOnly.append(image)
                var axis = try session.labAxes(image).axes[role]
                try session.channelCommand(.select, channel: axis.id, image: image)
                axis = try session.labAxes(image).axes[role]
                try session.fillLab(image, axis: axis, value: role == 0 ? 25 : -64, opacity: 1)
                let original = try render(image)

                let expectedCopy = try session.newLabImage(width: 32, height: 24, component: component)
                nativeOnly.append(expectedCopy)
                var expectedAxis = try session.labAxes(expectedCopy).axes[role]
                try session.channelCommand(.select, channel: expectedAxis.id, image: expectedCopy)
                expectedAxis = try session.labAxes(expectedCopy).axes[role]
                // Literal analytic oracle: normalized y=.25+.5*x. The seeded
                // L25/chroma-64 maps to L37.5/chroma-32.25, including the final
                // integer rounding of these particular U8/U16 witnesses.
                try session.fillLab(expectedCopy, axis: expectedAxis, value: role == 0 ? 37.5 : -32.25, opacity: 1)
                let expected = try render(expectedCopy)
                let expectedPixel = try centerPixel(session.render(expectedCopy, scale: 1,
                    area: CGRect(x: 0, y: 0, width: 32, height: 24)))
                var gammaPixel: [UInt8]?
                if role == 0 {
                    // Independent gamma-2 Lightness witness: sqrt(.25)=.5.
                    try session.fillLab(expectedCopy, axis: expectedAxis, value: 50, opacity: 1)
                    gammaPixel = try centerPixel(session.render(expectedCopy, scale: 1,
                        area: CGRect(x: 0, y: 0, width: 32, height: 24)))
                }
                try session.closeImage(expectedCopy)
                nativeOnly.removeAll { $0 == expectedCopy }
                expect(expected != original, "physical affine oracle differs from source")

                let controller = try openDocument(image, name: "Lab Levels \(component) axis \(role)")
                let document = controller.imageDocument
                let undo = document.undoInfo.undoCount
                try document.startRecording()
                expect(controller.validateMenuItem(levelsItem), "actual Lab Levels command is enabled")
                expect(!controller.validateMenuItem(ordinaryItem), "unqualified Lab adjustment remains disabled")
                controller.openNativeFilter(operation)
                try ready(controller)
                let panel = controller.labLevelsPanel!
                expect(panel.window?.title == "Lab Levels", "panel names the physical Lab adjustment")
                expect(!controller.validateMenuItem(levelsItem), "another adjustment cannot open over preview")
                try setAffine(controller, role: axis.role)
                if let preview = controller.canvas.labLevelsPreviewImage {
                    expect(try centerPixel(preview) == expectedPixel,
                           "actual canvas preview matches independent affine physical Fill oracle")
                } else { expect(false, "current Lab Levels has actual preview pixels") }
                expect(try render(image) == original && document.undoInfo.undoCount == undo,
                       "preview leaves source and history unchanged")
                expect(try session.labAxes(image).axes[role].uuid == axis.uuid,
                       "preview preserves captured axis identity")
                try geometry(panel)
                if component == .u8 {
                    try capturePanel(panel, name: "lab-levels-axis-\(role).png")
                    let editor = try draft(panel, field: panel.highOutputField,
                                           text: role == 0 ? "100.1" : "127.1", publish: false)
                    expect(panel.control(panel.highOutputField, textView: editor,
                                         doCommandBy: NSSelectorFromString("insertNewline:")),
                           "Return checks the live physical numeric draft")
                    try drain(document)
                    expect(controller.labLevelsPanel === panel && !panel.applyButton.isEnabled,
                           "out-of-range physical draft cannot Apply stale preview")
                    expect(try render(image) == original && document.undoInfo.undoCount == undo,
                           "invalid physical draft preserves source and history")
                    panel.resetButton.performClick(nil)
                    try ready(controller)
                    try setAffine(controller, role: axis.role)
                }
                if let gammaPixel {
                    panel.resetButton.performClick(nil)
                    try ready(controller)
                    _ = try draft(panel, field: panel.gammaField, text: "2")
                    try ready(controller)
                    if let preview = controller.canvas.labLevelsPreviewImage {
                        expect(try centerPixel(preview) == gammaPixel,
                               "gamma 2 L25 preview matches independent physical L50 Fill")
                    } else { expect(false, "gamma preview has actual pixels") }
                }
                panel.cancelButton.performClick(nil)
                try drain(document)
                expect(controller.labLevelsPanel == nil && controller.canvas.labLevelsPreviewImage == nil,
                       "Cancel removes Lab Levels panel and preview")
                expect(try render(image) == original && document.undoInfo.undoCount == undo,
                       "Cancel leaves original pixels and history")
                expect(document.recorder.records.isEmpty && document.recorder.pendingCount == 0,
                       "preview, invalid drafts and Cancel produce no Recorder rows")

                controller.openNativeFilter(operation)
                try ready(controller)
                try setAffine(controller, role: axis.role)
                controller.labLevelsPanel!.applyButton.performClick(nil)
                try wait({ controller.labLevelsPanel == nil && document.pendingWork == 0 &&
                           document.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy },
                         "Apply finishes and disposes snapshot and Recorder reservation")
                try document.stopRecording()
                expect(try render(image) == expected && document.undoInfo.undoCount == undo + 1,
                       "Apply matches independent affine Fill and creates one Undo")
                expect(document.recorder.records.count == 1, "Apply produces one Recorder row")
                if case .success(.applyLabLevels(let recorded))? = document.recorder.records.first?.resolution {
                    expect(recorded == settings, "successful Recorder row retains exact analytic settings and flags")
                } else { expect(false, "successful Apply records the typed Lab Levels command") }
                let expectedIdentity = try RecorderLabIdentity(axis: axis, component: component)
                if case .lab(_, let identity)? = document.recorderBindingDescriptions[0] {
                    expect(identity == expectedIdentity, "Recorder retains original Lab role, precision and UUID")
                } else { expect(false, "Recorder has an explicit Lab binding") }

                let url = work.appendingPathComponent("lab-levels-\(component.rawValue)-\(role).glims-recording")
                var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                document.saveRecording(to: url, checkpoint: try document.recorderSaveCheckpoint()) { saved = $0 }
                try wait({ saved != nil && document.pendingWork == 0 }, "Lab Levels recording save callback")
                _ = try saved!.get()
                let bytes = try Data(contentsOf: url)
                let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                expect(json?["version"] as? Int == 17, "actual saved Lab Levels recording uses version 17")
                var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                document.prepareRecordingFile(at: url, checkpoint: try document.recorderInstallCheckpoint()) { loaded = $0 }
                try wait({ loaded != nil && document.pendingWork == 0 }, "Lab Levels recording load callback")
                let prepared = try loaded!.get()
                expect(prepared.log.records.count == 1 && prepared.file.records.count == 1,
                       "actual load retains one completed Lab Levels row")
                if case .success(.applyLabLevels(let value))? = prepared.log.records.first?.resolution {
                    expect(value == settings, "loaded Lab Levels settings match the actual accepted values exactly")
                } else { expect(false, "loaded recording prepares the typed Lab Levels command") }
                if case .success(_, let binding)? = prepared.file.records.first?.outcome {
                    expect(binding == document.recorderBindingDescriptions[0], "loaded recording retains exact captured binding")
                } else { expect(false, "loaded recording retains a successful bound command") }
                document.undo()
                try drain(document)
                expect(try render(image) == original, "Undo restores original rendered pixels")
                document.redo()
                try drain(document)
                expect(try render(image) == expected, "Redo restores applied rendered pixels")

                // Execute the actual disk-loaded command in a separately owned
                // document; value round-trips alone do not prove replay routing.
                guard case .success(_, .lab(let symbol, _))? = prepared.file.records.first?.outcome else {
                    throw NSError(domain: "LabLevelsSmoke", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Loaded Lab Levels binding missing"])
                }
                let destination = try session.newLabImage(width: 32, height: 24, component: component)
                nativeOnly.append(destination)
                let destinationAxis = try session.labAxes(destination).axes[role]
                try session.channelCommand(.select, channel: destinationAxis.id, image: destination)
                try session.fillLab(destination, axis: destinationAxis, value: role == 0 ? 25 : -64, opacity: 1)
                let targetController = try openDocument(destination, name: "Lab Levels replay")
                let target = targetController.imageDocument
                let targetOriginal = try render(destination)
                let targetHistory = try session.undoInfo(destination)
                expect(destinationAxis.uuid != axis.uuid && targetOriginal == original,
                       "replay destination has a distinct owning UUID and matching seed pixels")
                var installed: Result<Void, Error>?
                target.installRecording(prepared, checkpoint: try target.recorderInstallCheckpoint(),
                                        choices: [symbol: .channel(destinationAxis.id)]) { installed = $0 }
                try wait({ installed != nil && target.pendingWork == 0 && !EngineActivity.shared.isBusy },
                         "Loaded Lab Levels recording installs with an explicit destination axis")
                try installed!.get()
                expect(RecorderPalettePresentation(document: target).canPerform(.replay),
                       "actual loaded recording exposes Replay")
                try RecorderPaletteAction.replay.perform(on: target)
                try wait({ !target.recorder.isReplaying && target.pendingWork == 0 && !EngineActivity.shared.isBusy },
                         "Loaded Lab Levels replay settles")
                if case .finished(1) = target.replayStatus {
                    expect(true, "one loaded Lab Levels command replays through document admission")
                } else { expect(false, "loaded Lab Levels replay did not finish") }
                expect(try render(destination) == expected &&
                       session.undoInfo(destination).undoCount == targetHistory.undoCount + 1,
                       "rebound replay matches the independent physical oracle with one Undo")
                target.undo(); try drain(target)
                expect(try render(destination) == targetOriginal,
                       "Undo restores the rebound replay destination exactly")
                expect(try render(image) == expected,
                       "rebound replay and Undo leave the original document untouched")
                targetController.closeDiscardingChanges()
                try wait({ target.pendingWork == 0 && (try? session.info(destination)) == nil },
                         "Replay target document closes")
                controller.closeDiscardingChanges()
                try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil },
                         "Completed Lab Levels document closes")
            }
        }

        // Pending begin/render Cancel+Close ownership regressions (Curves pattern).
        for kind in 0..<4 {
            let image = try session.newLabImage(width: 32, height: 24, component: .u8)
            nativeOnly.append(image)
            let axis = try session.labAxes(image).axes[0]
            let original = try render(image)
            let document = try ImageDocument(session: session, image: image, name: "Lab levels cleanup \(kind)")
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller); nativeOnly.removeAll { $0 == image }; documents.items.append(document)
            document.onError = { errors.append($0) }
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            controller.openNativeFilter(operation)
            if kind >= 2 {
                try ready(controller)
                _ = try draft(controller.labLevelsPanel!, field: controller.labLevelsPanel!.lowOutputField, text: "37.5", publish: true)
            }
            if kind % 2 == 0 {
                controller.cancelOperation(nil)
                try drain(document)
                expect(controller.labLevelsPanel == nil && controller.canvas.labLevelsPreviewImage == nil && document.acceptsEdits,
                       "Cancel during pending begin/render clears preview ownership and re-enables editing")
                expect(try render(image) == original, "late canceled work leaves source pixels unchanged")
                let token = try session.beginLabLevelsSnapshot(image, axis: axis)
                try session.endLabLevelsSnapshot(image, token: token)
                expect(token != 0, "cancelled UI token is released before another native snapshot begins")
            }
            controller.closeDiscardingChanges()
            try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil && !EngineActivity.shared.isBusy },
                     "Close drains pending begin/render and destroys native image")
            expect(controller.labLevelsPanel == nil && controller.window?.isVisible == false,
                   "close during begin/render leaves no Lab panel or document window")
        }

        // Native target and pixel mutations below are deliberate controls;
        // the accepted snapshot itself is always owned by ImageDocument.
        for stalePixels in [false, true] {
            let image = try session.newLabImage(width: 32, height: 24, component: .u8)
            nativeOnly.append(image)
            var axes = try session.labAxes(image).axes
            try session.channelCommand(.select, channel: axes[0].id, image: image)
            axes = try session.labAxes(image).axes
            let axis = axes[0]
            try session.fillLab(image, axis: axis, value: 25, opacity: 1)
            let controller = try openDocument(image, name: stalePixels ? "Stale Lab Levels" : "Retarget Lab Levels")
            let document = controller.imageDocument
            document.filterPreviewIsOpen = true
            var began: Result<UInt64, Error>?
            document.beginLabLevelsPreview(axis: axis) { began = $0 }
            try wait({ began != nil && document.pendingWork == 0 }, "Document-owned Lab Levels snapshot begins")
            let token = try began!.get()
            directTokens.append((document, token))
            if stalePixels {
                try session.fillLab(image, axis: axis, value: 40, opacity: 1)
            } else {
                try session.channelCommand(.select, channel: axes[1].id, image: image)
            }
            try document.reload()
            if !stalePixels {
                expect(document.labLevelsRefusal(axis: axis) != nil, "retarget refuses the original captured Lab axis")
            }
            let before = try render(image)
            let history = try session.undoInfo(image)
            var applied: Result<Void, Error>?
            let accepted = document.applyLabLevelsPreview(token, settings: settings) { applied = $0 }
            if stalePixels { expect(accepted, "stale-pixel Apply reaches the native baseline validation") }
            try wait({ applied != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy },
                     "Refused Lab Levels Apply completes")
            if case .failure? = applied {
                expect(true, stalePixels ? "stale pixels refuse Apply" : "changed selected axis refuses Apply")
            } else { expect(false, "changed snapshot was unexpectedly applied") }
            expect(try render(image) == before && session.undoInfo(image) == history,
                   "refused Apply preserves current pixels and history")
            if !stalePixels {
                expect(try session.selectedItems(.channel, image: image) == [axes[1].id],
                       "refused Apply does not redirect to or reselect another channel")
            }
            var ended: Result<Void, Error>?
            document.endLabLevelsPreview(token) { ended = $0 }
            try wait({ ended != nil && document.pendingWork == 0 }, "Refused preview token cleanup completes")
            try ended!.get()
            directTokens.removeAll { $0.0 === document && $0.1 == token }
            document.filterPreviewIsOpen = false
            let fresh = try session.beginLabLevelsSnapshot(image, axis: try session.labAxes(image).axes[stalePixels ? 0 : 1])
            try session.endLabLevelsSnapshot(image, token: fresh)
            expect(fresh != token, "refusal retains no hidden snapshot ownership after End")
            controller.closeDiscardingChanges()
            try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil }, "Guard fixture document closes")
        }
    }
}
