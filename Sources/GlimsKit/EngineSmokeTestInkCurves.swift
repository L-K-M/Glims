import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInkCurves(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "ink-curves: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "InkCurvesSmoke", code: 1,
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
                throw NSError(domain: "InkCurvesSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No rendered pixels"])
            }
            return bytes
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
        func menuItem(_ name: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if (item.representedObject as? NativeFilterCommand)?.operation.name == name { return item }
                if let child = item.submenu, let found = menuItem(name, in: child) { return found }
            }
            return nil
        }
        func ready(_ controller: DocumentWindowController) throws {
            try wait({ controller.inkCurvesPanel?.applyButton.isEnabled == true &&
                       controller.canvas.inkCurvesPreviewIsCurrent &&
                       controller.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy },
                     "Curves panel and latest canvas preview become current")
        }
        func drawHalf(_ panel: InkCurvesPanel) throws {
            guard let window = panel.window else { return try require(false, "Missing Curves window") }
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let graph = panel.graph
            let plot = graph.bounds.insetBy(dx: 12, dy: 12)
            try require(plot.width > 10 && plot.height > 10, "Actual graph has usable bounds")
            for (type, x) in [(NSEvent.EventType.leftMouseDown, plot.minX), (.leftMouseDragged, plot.maxX), (.leftMouseUp, plot.maxX)] {
                let point = graph.convert(NSPoint(x: x, y: plot.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return try require(false, "Cannot construct bounded graph input")
                }
                switch type {
                case .leftMouseDown: graph.mouseDown(with: event)
                case .leftMouseDragged: graph.mouseDragged(with: event)
                default: graph.mouseUp(with: event)
                }
            }
            expect(graph.state.kind == .free && graph.state.samples.allSatisfy { $0 == 0.5 },
                   "a real freehand drag edits all 256 actual samples")
        }
        func capturePanel(_ panel: InkCurvesPanel) throws {
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
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("ink-curves-cmyk-u8.png"))
        }
        func draft(_ panel: InkCurvesPanel, field: NSTextField, text: String,
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
        func geometry(_ panel: InkCurvesPanel) throws {
            guard let window = panel.window, let content = window.contentView else {
                return try require(false, "Missing visible panel")
            }
            content.layoutSubtreeIfNeeded()
            expect(window.isVisible, "actual Curves panel is visible")
            for control in [panel.graph, panel.sampleIndexField, panel.outputField,
                            panel.resetButton, panel.applyButton, panel.cancelButton] as [NSView] {
                let rect = control.convert(control.bounds, to: content)
                expect(!control.isHiddenOrHasHiddenAncestor && rect.width > 0 && rect.height > 0 &&
                       rect.minX >= -1 && rect.minY >= -1 && rect.maxX <= content.bounds.maxX + 1 &&
                       rect.maxY <= content.bounds.maxY + 1, "\(control.accessibilityLabel() ?? "control") fits the panel")
            }
        }

        var controllers: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var errors: [String] = []
        defer {
            for controller in controllers {
                controller.inkCurvesPanel?.cancel()
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            let owned = controllers.map(\.imageDocument)
            do {
                try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil }
                           && !EngineActivity.shared.isBusy }, "Owned Curves images close")
            } catch { expect(false, "cleanup: \(error)") }
            for image in nativeOnly {
                do { try session.closeImage(image) } catch { expect(false, "native cleanup: \(error)") }
            }
            expect(controllers.allSatisfy { $0.inkCurvesPanel == nil && $0.window?.attachedSheet == nil },
                   "cleanup leaves no owned panel or sheet")
            expect(errors.isEmpty, "no unexpected document errors: \(errors)")
            documents.items.removeAll { candidate in owned.contains { candidate === $0 } }
        }
        try require(session.supportsInkCurveSnapshots, "Producer supports ink Curves snapshots")
        guard let profile = NSColorSpace.genericCMYK.iccProfileData, let menu = NSApp.mainMenu else {
            return try require(false, "Missing CMYK profile or app menu")
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations); NativeFilterMenus.install(operations, in: menu)
        guard let operation = NativeFilterCatalog.shared.operation(named: "gimp:curves"),
              let curvesItem = menuItem("gimp:curves", in: menu),
              let ordinaryItem = menuItem("gegl:invert-gamma", in: menu) else {
            return try require(false, "Missing actual adjustment menu entries")
        }
        for mode in [EngineSession.ColorMode.cmyk, .multichannel] {
            for component in [EngineSession.ColorComponent.u8, .u16, .float] {
                let image: Int32 = try mode == .cmyk
                    ? session.newCmykImage(width: 32, height: 24, component: component, profileICC: profile)
                    : session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
                nativeOnly.append(image)
                let channels = try session.channels(image)
                try require(channels.count == 4, "Four native inks")
                let target = channels[0].id
                try session.channelCommand(.select, channel: target, image: image)
                try session.editInk(image, channel: target, settings: .init(operation: .fill, intensity: 0.25, opacity: 1))
                let original = try render(image)
                let identity = try session.inkChannelIdentity(image, channel: target)
                let expectedCopy = try session.duplicateImage(image); nativeOnly.append(expectedCopy)
                let expectedTarget = try session.channels(expectedCopy)[0].id
                try session.channelCommand(.select, channel: expectedTarget, image: expectedCopy)
                // Existing Fill provides an independent display oracle for a
                // constant-half curve, including native integer rounding.
                try session.editInk(expectedCopy, channel: expectedTarget,
                                    settings: .init(operation: .fill, intensity: 0.5, opacity: 1))
                let expected = try render(expectedCopy)
                let expectedPixel = try centerPixel(session.render(expectedCopy, scale: 1,
                                                       area: CGRect(x: 0, y: 0, width: 32, height: 24)))
                try session.closeImage(expectedCopy); nativeOnly.removeAll { $0 == expectedCopy }
                expect(expected != original, "half-intensity oracle differs from source")
                let document = try ImageDocument(session: session, image: image, name: "Ink Curves \(mode) \(component)")
                let controller = DocumentWindowController(document: document, exportDirectory: work)
                controllers.append(controller); nativeOnly.removeAll { $0 == image }; documents.items.append(document)
                document.onError = { errors.append($0) }
                controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true); controller.window?.makeKeyAndOrderFront(nil)
                try drain(document)
                let undo = document.undoInfo.undoCount
                expect(controller.validateMenuItem(curvesItem), "actual ink Curves command is enabled")
                expect(!controller.validateMenuItem(ordinaryItem), "unrelated RGB adjustment stays unavailable")
                controller.openNativeFilter(operation); try ready(controller)
                let panel = controller.inkCurvesPanel!
                expect(!controller.validateMenuItem(curvesItem), "another adjustment cannot open over a preview")
                try drawHalf(panel); try ready(controller)
                if let preview = controller.canvas.inkCurvesPreviewImage {
                    expect(try centerPixel(preview) == expectedPixel, "actual canvas preview matches the independent Fill oracle")
                } else { expect(false, "current Curves has an actual canvas preview") }
                expect(try render(image) == original && document.undoInfo.undoCount == undo,
                       "preview leaves source and history unchanged")
                expect(try session.inkChannelIdentity(image, channel: target).uuid == identity.uuid,
                       "preview retains durable source ink identity")
                try geometry(panel)
                if mode == .cmyk && component == .u8 {
                    try capturePanel(panel)
                    let panelSize = panel.window!.frame.size
                    for (field, invalid) in [(panel.outputField, "NaN"), (panel.outputField, "1.01"),
                                             (panel.sampleIndexField, "1e300")] {
                        let editor = try draft(panel, field: field, text: invalid, publish: false)
                        expect(panel.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")),
                               "Return reads the actual uncommitted numeric draft")
                        try drain(document)
                        expect(controller.inkCurvesPanel === panel && !panel.applyButton.isEnabled,
                               "invalid draft cannot apply an older valid preview")
                        expect(try render(image) == original && document.undoInfo.undoCount == undo,
                               "invalid Return preserves source and history")
                        expect(panel.window!.frame.size == panelSize, "validation does not move or resize the panel")
                        panel.resetButton.performClick(nil); try ready(controller)
                    }
                    _ = try draft(panel, field: panel.sampleIndexField, text: "128")
                    try ready(controller)
                    expect(panel.graph.state.samples == (0..<256).map { Double($0) / 255 },
                           "changing the active sample does not overwrite its value")
                    _ = try draft(panel, field: panel.outputField, text: "0.7")
                    panel.cancelButton.performClick(nil)
                    expect(!controller.validateMenuItem(curvesItem), "Cancel gates reopening until native End drains")
                    try drain(document)
                    expect(controller.inkCurvesPanel == nil && controller.canvas.inkCurvesPreviewImage == nil,
                           "late numeric preview cannot revive a canceled panel")
                    expect(try render(image) == original && document.undoInfo.undoCount == undo,
                           "queued-preview Cancel preserves pixels and history")
                    controller.openNativeFilter(operation); try ready(controller)
                }
                let resetPanel = controller.inkCurvesPanel!
                resetPanel.resetButton.performClick(nil); try ready(controller)
                expect(resetPanel.graph.state.samples == (0..<256).map { Double($0) / 255 }, "Reset retains exact identity table")
                try drawHalf(resetPanel); try ready(controller)
                resetPanel.cancelButton.performClick(nil); try drain(document)
                expect(controller.inkCurvesPanel == nil && controller.canvas.inkCurvesPreviewImage == nil,
                       "Cancel removes panel and preview")
                expect(try render(image) == original && document.undoInfo.undoCount == undo, "Cancel changes no source pixels or history")
                try document.startRecording()
                controller.openNativeFilter(operation); try ready(controller)
                let applying = controller.inkCurvesPanel!
                try drawHalf(applying); try ready(controller)
                applying.applyButton.performClick(nil)
                try wait({ controller.inkCurvesPanel == nil }, "Apply completes and closes its panel"); try drain(document)
                expect(try render(image) == expected, "committed pixels match independent Fill oracle")
                expect(document.undoInfo.undoCount == undo + 1, "Apply is exactly one Undo")
                expect(controller.canvas.inkCurvesPreviewImage == nil, "Apply discards preview overlay")
                expect(document.recorder.pendingCount == 0 && document.recorder.records.count == 1,
                       "actual panel Apply settles one Recorder row")
                if document.recorder.records.count == 1,
                   case .success(.applyInkCurves(let captured)) = document.recorder.records[0].resolution,
                   case .ink(_, let capturedIdentity)? = document.recorderBindingDescriptions[0] {
                    expect(captured.samples == Array(repeating: 0.5, count: 256) && capturedIdentity.uuid == identity.uuid,
                           "actual panel records the full accepted curve and original ink identity")
                } else { expect(false, "actual panel records a successful ink Curves command") }
                try document.stopRecording()
                document.undo(); try drain(document); expect(try render(image) == original, "Undo restores source")
                document.redo(); try drain(document); expect(try render(image) == expected, "Redo restores Curves result")
                // Close while a fresh capture is queued; no late panel may
                // survive the document that owned its native snapshot.
                controller.openNativeFilter(operation)
                controller.closeDiscardingChanges()
                try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil && !EngineActivity.shared.isBusy },
                         "Close drains queued Curves capture")
                expect(controller.inkCurvesPanel == nil && controller.canvas.inkCurvesPreviewImage == nil,
                       "late capture cannot revive a closed document")
            }
        }
    }
}
