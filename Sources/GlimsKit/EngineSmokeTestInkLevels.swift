import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInkLevels(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "ink-levels: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "InkLevelsSmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool, timeout: TimeInterval = 20, _ message: String) throws {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                // Pump before testing too: view notifications can invalidate a
                // previously current preview after a zoom or field action.
                EngineSmokeTestHost.pumpEvents(for: 0.01)
                if condition() {
                    EngineSmokeTestHost.pumpEvents(for: 0.01)
                    if condition() { return }
                }
            } while Date() < deadline
            try require(false, message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Image work drains")
        }
        func render(_ image: Int32) throws -> Data {
            let pixels = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let bytes = pixels.dataProvider?.data as Data? else {
                throw NSError(domain: "InkLevelsSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing rendered pixels"])
            }
            return bytes
        }
        func centerPixel(_ image: CGImage) throws -> [UInt8] {
            // Every seeded plane is uniform. Normalize the actual preview to
            // one sRGB pixel without assuming its viewport, stride or profile.
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
            try require(made, "Preview pixel can be normalized")
            return bytes
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func labelled(_ label: String, in content: NSView) throws -> NSTextField {
            let matches = descendants(content).compactMap { $0 as? NSTextField }
                .filter { $0.accessibilityLabel() == label }
            try require(matches.count == 1, "Exactly one '\(label)' accessibility field")
            return matches[0]
        }
        func menuItem(_ operation: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if (item.representedObject as? NativeFilterCommand)?.operation.name == operation { return item }
                if let submenu = item.submenu, let found = menuItem(operation, in: submenu) { return found }
            }
            return nil
        }
        func draft(_ panel: InkLevelsPanel, _ text: String, publish: Bool = true) throws -> NSTextView {
            guard let window = panel.window else {
                throw NSError(domain: "InkLevelsSmoke", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Missing actual Levels window"])
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(panel.gammaField)
            panel.gammaField.selectText(nil)
            try wait({ panel.gammaField.currentEditor() is NSTextView }, "Gamma field editor becomes active")
            let editor = panel.gammaField.currentEditor() as! NSTextView
            editor.string = text
            panel.gammaField.stringValue = text
            if publish {
                panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                        object: panel.gammaField))
            }
            return editor
        }
        func geometry(_ panel: InkLevelsPanel, _ name: String) throws {
            guard let window = panel.window, let content = window.contentView else {
                throw NSError(domain: "InkLevelsSmoke", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Levels has no content view"])
            }
            content.layoutSubtreeIfNeeded()
            let labels = try ["Ink", "Hint", "Status"].map { try labelled($0, in: content) }
            let fields = [panel.lowInputField, panel.highInputField, panel.gammaField,
                          panel.lowOutputField, panel.highOutputField]
            for (field, label) in zip(fields, ["Low input", "High input", "Gamma", "Low output", "High output"]) {
                expect(field.accessibilityLabel() == label, "\(name): numeric field exposes \(label)")
            }
            // Numeric captions deliberately share the editor's AX label;
            // inspect the actual controls rather than assuming label uniqueness.
            let controls: [NSView] = (labels + fields).map { $0 as NSView } +
                [panel.clampInputButton, panel.clampOutputButton,
                 panel.resetButton, panel.cancelButton, panel.applyButton]
            expect(window.isVisible, "\(name): actual Levels panel is visible")
            for control in controls {
                let rect = control.convert(control.bounds, to: content)
                // An empty status label can have no height until validation.
                expect(!control.isHiddenOrHasHiddenAncestor && rect.width > 0 &&
                       rect.minX >= -1 && rect.minY >= -1 &&
                       rect.maxX <= content.bounds.maxX + 1 && rect.maxY <= content.bounds.maxY + 1,
                       "\(name): \(control.accessibilityLabel() ?? "button") fits the panel")
            }
            expect(try labelled("Hint", in: content).stringValue.contains("0 = full ink"),
                   "\(name): intensity orientation is explicit")
        }
        func artifact(_ panel: InkLevelsPanel, _ filename: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            try require(!directory.isEmpty, "Artifact directory is not empty")
            guard let content = panel.window?.contentView else {
                throw NSError(domain: "InkLevelsSmoke", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "No panel content to capture"])
            }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw NSError(domain: "InkLevelsSmoke", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot capture actual Levels panel"])
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                throw NSError(domain: "InkLevelsSmoke", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot encode Levels panel PNG"])
            }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename), options: .atomic)
            expect(true, "saved actual panel artifact \(filename)")
        }

        var controllers: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var oldErrors: [(ImageDocument, ((String) -> Void)?)] = []
        var unexpectedErrors: [String] = []
        defer {
            for controller in controllers {
                controller.inkLevelsPanel?.cancel()
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            let owned = controllers.map(\.imageDocument)
            do {
                try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil } &&
                           !EngineActivity.shared.isBusy }, timeout: 30, "Owned ink Levels documents close")
            } catch { expect(false, "cleanup drains owned images: \(error)") }
            for id in nativeOnly {
                do { try session.closeImage(id) }
                catch { expect(false, "cleanup closes native image \(id): \(error)") }
            }
            expect(controllers.allSatisfy { $0.inkLevelsPanel == nil && $0.window?.attachedSheet == nil },
                   "cleanup leaves no owned panel or sheet")
            expect(unexpectedErrors.isEmpty, "no unexpected document or cleanup errors: \(unexpectedErrors)")
            for (document, old) in oldErrors { document.onError = old }
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
        }
        func attach(_ image: Int32, _ name: String) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: image, name: name)
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            oldErrors.append((document, document.onError))
            document.onError = { unexpectedErrors.append($0) }
            controllers.append(controller)
            nativeOnly.removeAll { $0 == image }
            documents.items.append(document)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            return controller
        }
        func ready(_ controller: DocumentWindowController, _ message: String) throws {
            try wait({ controller.inkLevelsPanel != nil && controller.canvas.inkLevelsPreviewIsCurrent &&
                       controller.inkLevelsPanel?.applyButton.isEnabled == true &&
                       controller.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }, message)
            expect(controller.statusBar.message != "Preparing Levels preview…",
                   "ready preview clears its preparing status")
        }

        try require(session.supportsInkLevelSnapshots, "Engine supports native ink snapshot APIs")
        guard let profile = NSColorSpace.genericCMYK.iccProfileData, let menu = NSApp.mainMenu else {
            throw NSError(domain: "InkLevelsSmoke", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Missing external CMYK profile or app menu"])
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        NativeFilterMenus.install(operations, in: menu)
        guard let operation = NativeFilterCatalog.shared.operation(named: "gimp:levels"),
              let levelsItem = menuItem("gimp:levels", in: menu),
              let ordinaryItem = menuItem("gegl:invert-gamma", in: menu) else {
            throw NSError(domain: "InkLevelsSmoke", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "Missing actual Levels/ordinary filter menu entries"])
        }
        let cases: [(String, EngineSession.ColorMode, EngineSession.ColorComponent)] = [
            ("CMYK u8", .cmyk, .u8), ("CMYK float", .cmyk, .float),
            ("Multichannel u8", .multichannel, .u8), ("Multichannel float", .multichannel, .float)
        ]
        for (name, mode, component) in cases {
            let image: Int32
            if mode == .cmyk {
                image = try session.newCmykImage(width: 32, height: 24, component: component, profileICC: profile)
            } else {
                image = try session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
            }
            nativeOnly.append(image)
            let channels = try session.channels(image)
            try require(channels.count == 4, "\(name): four native ink channels")
            let target = channels[0].id
            try session.channelCommand(.select, channel: target, image: image)
            try session.editInk(image, channel: target, settings: .init(operation: .fill, intensity: 0.25, opacity: 1))
            let original = try render(image)

            // The oracle never calls Levels. U8 seed .25 becomes64/255;
            // sqrt(64/255) quantizes to128/255. FLOAT .25 becomes exactly .5.
            let expectedCopy = try session.duplicateImage(image)
            nativeOnly.append(expectedCopy)
            let expectedChannels = try session.channels(expectedCopy)
            try require(expectedChannels.count == 4, "\(name): oracle has four copied planes")
            let expectedTarget = expectedChannels[0].id
            try session.channelCommand(.select, channel: expectedTarget, image: expectedCopy)
            try session.editInk(expectedCopy, channel: expectedTarget,
                                settings: .init(operation: .fill, intensity: component == .u8 ? 128.0 / 255.0 : 0.5, opacity: 1))
            let expected = try render(expectedCopy)
            try session.closeImage(expectedCopy)
            nativeOnly.removeAll { $0 == expectedCopy }
            expect(expected != original, "\(name): independent half-intensity oracle differs from source")

            let controller = try attach(image, name)
            let document = controller.imageDocument
            let beforeUndo = document.undoInfo.undoCount
            expect(document.colorInfo.mode == mode && document.activeChannel == target && document.layers.isEmpty,
                   "\(name): cached mode, native target and layerless document are correct")
            expect(controller.validateMenuItem(levelsItem), "\(name): actual Levels menu is enabled")
            expect(!controller.validateMenuItem(ordinaryItem), "\(name): unrelated RGB filter remains unavailable")
            controller.openNativeFilter(operation)
            try ready(controller, "\(name): real Levels panel and identity preview become current")
            let panel = controller.inkLevelsPanel!
            guard let identityImage = controller.canvas.inkLevelsPreviewImage else {
                throw NSError(domain: "InkLevelsSmoke", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Missing actual identity preview"])
            }
            let identityPixel = try centerPixel(identityImage)
            try geometry(panel, "\(name) initial")
            expect(try labelled("Ink", in: panel.window!.contentView!).stringValue == channels[0].name,
                   "\(name): panel names the captured ink")
            expect(!controller.validateMenuItem(levelsItem), "\(name): second Levels launch is gated while preview is open")
            let savesArtifacts = mode == .cmyk && component == .u8
            if savesArtifacts { try artifact(panel, "ink-levels-cmyk-u8-initial.png") }

            _ = try draft(panel, "2")
            try ready(controller, "\(name): gamma2 preview becomes current")
            let adjustedImage = controller.canvas.inkLevelsPreviewImage!
            expect(try centerPixel(adjustedImage) != identityPixel, "\(name): actual canvas preview visibly changes")
            expect(try render(image) == original && document.undoInfo.undoCount == beforeUndo,
                   "\(name): preview leaves source pixels and history unchanged")
            if savesArtifacts { try artifact(panel, "ink-levels-cmyk-u8-gamma2.png") }
            if savesArtifacts, ProcessInfo.processInfo.environment["GLIMS_SMOKE_CAPTURE_INK_LEVELS"] == "1" {
                // A bounded inspection window for a separate desktop capture.
                // Keep AppKit processing events; normal smoke runs do not pause.
                EngineSmokeTestHost.pumpEvents(for: 15)
            }

            for invalid in ["NaN", "0", "11"] {
                // Do not publish the draft first: Return must read the current
                // field editor instead of applying the last valid gamma2.
                let editor = try draft(panel, invalid, publish: false)
                expect(panel.control(panel.gammaField, textView: editor,
                                     doCommandBy: NSSelectorFromString("insertNewline:")),
                       "\(name): actual field delegate handles Return")
                try drain(document)
                expect(controller.inkLevelsPanel === panel && !panel.applyButton.isEnabled,
                       "\(name): invalid \(invalid) cannot apply an older valid preview")
                let invalidStatus = try labelled("Status", in: panel.window!.contentView!).stringValue
                expect(!invalidStatus.isEmpty,
                       "\(name): invalid draft has an accessible status message")
                expect(try render(image) == original && document.undoInfo.undoCount == beforeUndo,
                       "\(name): invalid Return changes neither source nor history")
                try geometry(panel, "\(name) invalid \(invalid)")
                if savesArtifacts && invalid == "NaN" { try artifact(panel, "ink-levels-cmyk-u8-invalid.png") }
            }
            _ = try draft(panel, "2")
            try ready(controller, "\(name): valid draft restores Apply")

            controller.window?.setContentSize(NSSize(width: 360, height: 240))
            controller.zoom(to: ZoomLadder.steps.last!)
            controller.center(on: CGPoint(x: 24, y: 18))
            try ready(controller, "\(name): zoomed preview becomes current")
            let farOrigin = controller.canvas.visibleRect.origin
            controller.center(on: CGPoint(x: 8, y: 6))
            try ready(controller, "\(name): panned preview becomes current")
            expect(controller.canvas.visibleRect.origin != farOrigin, "\(name): actual viewport pans")
            expect(try render(image) == original, "\(name): view zoom/pan does not edit source")
            controller.zoom(to: 100)
            try ready(controller, "\(name): restored viewport becomes current")

            _ = try draft(panel, "3")
            panel.cancelButton.performClick(nil) // Cancel with a preview reply still pending.
            expect(!controller.validateMenuItem(levelsItem),
                   "\(name): same-turn Cancel keeps Levels gated until native End drains")
            try wait({ controller.inkLevelsPanel == nil }, "\(name): Cancel dismisses panel")
            try drain(document)
            expect(controller.validateMenuItem(levelsItem), "\(name): Levels becomes available after native End")
            expect(controller.canvas.inkLevelsPreviewImage == nil && !controller.canvas.inkLevelsPreviewIsCurrent,
                   "\(name): late canceled preview cannot restore canvas pixels")
            expect(try render(image) == original && document.undoInfo.undoCount == beforeUndo,
                   "\(name): Cancel preserves source and history")

            if savesArtifacts {
                // A direct public target change is outside the window's input
                // gate but still must be rejected by native captured Apply.
                controller.openNativeFilter(operation)
                try ready(controller, "Captured-target panel opens")
                let capturedPanel = controller.inkLevelsPanel!
                _ = try draft(capturedPanel, "2")
                try ready(controller, "Captured-target preview becomes current")
                try session.channelCommand(.select, channel: channels[1].id, image: image)
                try drain(document)
                try ready(controller, "Frozen preview remains usable after external target change")
                capturedPanel.applyButton.performClick(nil)
                try wait({ !capturedPanel.applyButton.isEnabled && document.pendingWork == 0 &&
                           !EngineActivity.shared.isBusy }, "Captured-target Apply refuses")
                let capturedStatus = try labelled("Status", in: capturedPanel.window!.contentView!).stringValue
                expect(controller.inkLevelsPanel === capturedPanel && !capturedStatus.isEmpty,
                       "changed target keeps the actual panel open with a reason")
                expect(try render(image) == original && document.undoInfo.undoCount == beforeUndo,
                       "captured-target refusal preserves pixels/history")
                capturedPanel.cancelButton.performClick(nil)
                try drain(document)
                document.selectChannel(target)
                try drain(document)
            }

            if savesArtifacts { try document.startRecording() }
            controller.openNativeFilter(operation)
            try ready(controller, "\(name): Apply panel reopens with a fresh token")
            let applyPanel = controller.inkLevelsPanel!
            _ = try draft(applyPanel, "2")
            try ready(controller, "\(name): Apply preview is accepted")
            applyPanel.applyButton.performClick(nil)
            try wait({ controller.inkLevelsPanel == nil }, "\(name): Apply dismisses panel")
            try drain(document)
            expect(try render(image) == expected, "\(name): committed pixels equal independent Fill oracle")
            expect(document.undoInfo.undoCount == beforeUndo + 1, "\(name): Apply creates exactly one Undo")
            expect(controller.canvas.inkLevelsPreviewImage == nil, "\(name): Apply removes preview overlay")
            if savesArtifacts {
                expect(document.recorder.pendingCount == 0 && document.recorder.records.count == 1,
                       "Recorder settles exactly one accepted ink Levels row")
                if document.recorder.records.count == 1,
                   case .success(.applyInkLevels(let captured)) = document.recorder.records[0].resolution,
                   case .ink(_, let identity)? = document.recorderBindingDescriptions[0] {
                    expect(captured == .init(value: .init(gamma: 2)) && identity.isValid,
                           "Recorder captures exact final Levels settings and the original ink identity")
                } else { expect(false, "Recorder must capture the accepted ink Levels Apply") }
                try document.stopRecording()
                expect(!document.recorder.isRecording && document.recorder.pendingCount == 0,
                       "Recorder Stop leaves no pending reservation")
            }
            document.undo(); try drain(document)
            expect(try render(image) == original, "\(name): Undo restores exact original rendered pixels")
            document.redo(); try drain(document)
            expect(try render(image) == expected, "\(name): Redo restores exact expected pixels")

            let afterApplyUndo = document.undoInfo.undoCount
            controller.openNativeFilter(operation)
            try ready(controller, "\(name): Close-button panel opens")
            let closingPanel = controller.inkLevelsPanel!
            _ = try draft(closingPanel, "2")
            try ready(controller, "\(name): Close-button panel has a changed preview")
            closingPanel.window?.performClose(nil)
            try wait({ controller.inkLevelsPanel == nil }, "\(name): window Close invokes Cancel")
            try drain(document)
            expect(try render(image) == expected && document.undoInfo.undoCount == afterApplyUndo,
                   "\(name): panel Close changes neither source nor history")

            controller.openNativeFilter(operation)
            controller.closeDiscardingChanges() // Do not pump: Begin's reply is still pending.
            try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil &&
                       !EngineActivity.shared.isBusy }, "\(name): pending Begin drains through source close")
            expect(controller.inkLevelsPanel == nil && controller.canvas.inkLevelsPreviewImage == nil &&
                   controller.window?.attachedSheet == nil,
                   "\(name): stale Begin cannot revive a panel, preview or dialog")
        }
    }
}
