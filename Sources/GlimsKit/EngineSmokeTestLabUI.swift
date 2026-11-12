import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseLabUI(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-ui: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LabUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, timeout: TimeInterval = 15, _ message: String) throws {
            let limit = Date().addingTimeInterval(timeout)
            while !ready() && Date() < limit { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            EngineSmokeTestHost.pumpEvents()
            try require(ready(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !document.targetCommandIsPending
                       && !EngineActivity.shared.isBusy }, "Lab document work drains")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control<T: NSView>(_ type: T.Type, label: String, in root: NSView) throws -> T {
            let matches = descendants(root).compactMap { $0 as? T }.filter { $0.accessibilityLabel() == label }
            try require(matches.count == 1, "Exactly one actual control has AX label '\(label)'")
            return matches[0]
        }
        func button(_ title: String, in root: NSView) throws -> NSButton {
            let matches = descendants(root).compactMap { $0 as? NSButton }.filter { $0.title == title }
            try require(matches.count == 1, "Exactly one actual button is named '\(title)'")
            return matches[0]
        }
        func draft(_ field: NSTextField, _ text: String, in window: NSWindow) throws {
            window.makeFirstResponder(field)
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Numeric field has its actual field editor")
            (field.currentEditor() as? NSTextView)?.string = text
            field.stringValue = text
        }
        func render(_ image: Int32) throws -> Data {
            let result = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let data = result.dataProvider?.data as Data? else {
                throw NSError(domain: "LabUISmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing rendered bytes"])
            }
            return data
        }
        func visible(_ view: NSView, in root: NSView) -> Bool {
            !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true
                && view.bounds.width > 1 && view.bounds.height > 1
                && view.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(view.bounds)
                && root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.convert(view.bounds, to: root))
        }
        func artifact(_ view: NSView, _ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            do {
                try require(!directory.isEmpty, "Artifact directory is nonempty")
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "LabUISmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot capture \(name)"])
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw NSError(domain: "LabUISmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot encode \(name)"])
                }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
                expect(true, "saved actual AppKit artifact \(name)")
            } catch { expect(false, "artifact \(name): \(error)"); throw error }
        }
        func menuItem(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let child = item.submenu, let match = menuItem(action, in: child) { return match }
            }
            return nil
        }

        let oldMenu = NSApp.mainMenu, oldTool = ToolState.shared.current
        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        let palette = ChannelsPaletteController(), tools = ToolsPaletteController()
        let paletteWindow = ClassicPaletteWindow(contentSize: ChannelsPaletteController.definition.contentSize)
        var controllers: [DocumentWindowController] = [], bareDocuments: [ImageDocument] = []
        var nativeOnly: [Int32] = [], unexpectedErrors: [String] = []
        var oldHandlers: [(ImageDocument, ((String) -> Void)?)] = []
        defer {
            palette.retarget(to: nil); tools.retarget(to: nil)
            paletteWindow.orderOut(nil); paletteWindow.close()
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            for document in bareDocuments where !document.isClosing { document.closeImageWhenDrained() }
            let owned = controllers.map(\.imageDocument) + bareDocuments
            do {
                try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil } },
                         timeout: 20, "All owned Lab UI images close")
            } catch { expect(false, "cleanup drains images: \(error)") }
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "cleanup leaves no owned sheets")
            expect(unexpectedErrors.isEmpty, "fixture and cleanup have no unexpected document errors")
            for (document, handler) in oldHandlers { document.onError = handler }
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            for id in nativeOnly {
                do { try session.closeImage(id) } catch { expect(false, "cleanup closes native-only image: \(error)") }
            }
            ToolState.shared.select(oldTool)
            NSApp.mainMenu = oldMenu
        }
        func observe(_ document: ImageDocument) {
            oldHandlers.append((document, document.onError))
            document.onError = { unexpectedErrors.append($0) }
            documents.items.append(document)
            nativeOnly.removeAll { $0 == document.image }
        }
        func attach(_ id: Int32, name: String) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: id, name: name)
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller); observe(document)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            return controller
        }
        func newSettings(_ component: EngineSession.ColorComponent) throws -> NewImageSettings {
            let panel = NewImagePanel(supportsLab: true)
            defer { panel.close() }
            panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
            guard let window = panel.window, let root = window.contentView else {
                throw NSError(domain: "LabUISmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "New Image window missing"])
            }
            try draft(control(NSTextField.self, label: "Width in pixels", in: root), "32", in: window)
            try draft(control(NSTextField.self, label: "Height in pixels", in: root), "24", in: window)
            let mode = try control(NSPopUpButton.self, label: "Image mode", in: root)
            let precision = try control(NSPopUpButton.self, label: "Precision", in: root)
            try require(mode.indexOfItem(withTitle: "Lab (D50)") >= 0, "New Image exposes Lab (D50)")
            mode.selectItem(withTitle: "Lab (D50)")
            _ = mode.sendAction(mode.action, to: mode.target)
            guard let index = [EngineSession.ColorComponent.u8, .u16, .float].firstIndex(of: component) else {
                throw NSError(domain: "LabUISmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unexpected fixture precision"])
            }
            precision.selectItem(at: index)
            let create = try button("Create", in: root)
            expect(precision.isEnabled && create.isEnabled, "\(component.title): Lab creation enables precision and Create")
            var captured: NewImageSettings?
            panel.onCreate = { captured = $0 }
            create.performClick(nil)
            try wait({ captured != nil && !window.isVisible }, "Actual Create captures settings and closes New Image")
            guard let settings = captured else { throw NSError(domain: "LabUISmoke", code: 7) }
            expect(settings.kind == .lab && settings.component == component && settings.width == 32
                   && settings.height == 24 && settings.channelCount == 3 && settings.profileICC == nil,
                   "\(component.title): New Image emits fixed-three-axis, profile-free Lab settings")
            return settings
        }
        func axisButton(_ role: EngineSession.LabAxisRole) throws -> NSButton {
            let matches = descendants(palette.view).compactMap { $0 as? NSButton }.filter {
                $0.accessibilityIdentifier() == "lab-axis-\(role.rawValue)"
            }
            try require(matches.count == 1, "Exactly one current Lab axis button exists")
            return matches[0]
        }
        func pick(_ role: EngineSession.LabAxisRole, in document: ImageDocument) throws {
            // Reload rebuilds rows: never retain a detached button across picks.
            do {
                try wait({
                    palette.view.layoutSubtreeIfNeeded()
                    guard let current = try? axisButton(role) else { return false }
                    return current.isEnabled && visible(current, in: palette.view)
                }, "Lab axis button is enabled and visible after layout")
            } catch {
                if let current = try? axisButton(role) {
                    var node: NSView? = current
                    while let view = node {
                        print("     Lab geometry \(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect) hidden=\(view.isHiddenOrHasHiddenAncestor) shown=\(view.window?.isVisible == true)")
                        node = view.superview
                    }
                    try artifact(palette.view, "lab-geometry-refusal.png")
                }
                throw error
            }
            let row = try axisButton(role)
            row.performClick(nil)
            try drain(document); palette.reload()
            EngineSmokeTestHost.pumpEvents()
            let native = try session.labAxes(document.image).axes.filter(\.isSelected)
            try require(native.count == 1 && native[0].role == role && document.selectedLabAxis?.id == native[0].id,
                        "Actual palette action selects the same sole native and cached axis")
        }
        func fillSheet(_ controller: DocumentWindowController) throws -> (NSWindow, NSView) {
            controller.fill(nil)
            try wait({ controller.window?.attachedSheet != nil }, "Actual Fill opens its sheet")
            guard let sheet = controller.window?.attachedSheet, let root = sheet.contentView else {
                throw NSError(domain: "LabUISmoke", code: 8, userInfo: [NSLocalizedDescriptionKey: "Fill sheet missing"])
            }
            root.layoutSubtreeIfNeeded()
            return (sheet, root)
        }
        func fillDraft(_ value: String, opacity: String = "100", sheet: NSWindow, root: NSView) throws {
            try draft(control(NSTextField.self, label: "Lightness (L*) physical value", in: root), value, in: sheet)
            try draft(control(NSTextField.self, label: "Lab fill opacity, percent", in: root), opacity, in: sheet)
        }
        func cancelSheet(_ window: NSWindow, root: NSView) throws {
            try button("Cancel", in: root).performClick(nil)
            try wait({ window.attachedSheet == nil }, "Cancel dismisses the owned sheet")
        }

        guard let fillMenu = menuItem(#selector(DocumentWindowController.fill(_:)), in: menu),
              let blurMenu = menuItem(#selector(DocumentWindowController.gaussianBlur(_:)), in: menu),
              let clearMenu = menuItem(#selector(DocumentWindowController.deleteBackward(_:)), in: menu),
              let proofMenu = menuItem(#selector(DocumentWindowController.toggleSoftProof(_:)), in: menu) else {
            throw NSError(domain: "LabUISmoke", code: 9, userInfo: [NSLocalizedDescriptionKey: "Actual Lab workflow menu items missing"])
        }
        paletteWindow.contentView = palette.view
        _ = tools.view
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let tag = component == .u8 ? "u8" : component == .u16 ? "u16" : "float"
            let settings = try newSettings(component)
            let image = try session.newLabImage(width: settings.width, height: settings.height, component: settings.component)
            nativeOnly.append(image)
            let controller = try attach(image, name: "Lab UI \(tag)"), document = controller.imageDocument
            guard let window = controller.window else { throw NSError(domain: "LabUISmoke", code: 10) }
            palette.retarget(to: document); paletteWindow.orderFront(nil)
            palette.view.layoutSubtreeIfNeeded()
            let original = try render(image), originalUndo = document.undoInfo
            try pick(.a, in: document); try pick(.b, in: document); try pick(.lightness, in: document)
            expect(document.colorInfo.mode == .lab && document.colorInfo.component == component
                   && document.activeDrawable == nil && document.channels.isEmpty,
                   "\(tag): real document exposes typed Lab axes without a generic paint target")
            expect(try render(image) == original && document.undoInfo == originalUndo,
                   "\(tag): all three actual axis picks preserve pixels and history")
            // The final reload replaces controls; finish their AppKit layout
            // before checking geometry, as the next displayed frame does.
            palette.view.layoutSubtreeIfNeeded()
            let rows = try EngineSession.LabAxisRole.allCases.map(axisButton)
            expect(rows.allSatisfy { visible($0, in: palette.view) && !($0.accessibilityLabel() ?? "").isEmpty },
                   "\(tag): all three named Lab axis controls fit the visible palette")
            expect(controller.validateMenuItem(fillMenu) && !controller.validateMenuItem(blurMenu)
                   && !controller.validateMenuItem(clearMenu) && !controller.validateMenuItem(proofMenu),
                   "\(tag): actual menus allow Fill and refuse Blur, Clear and soft proof")
            if component == .u8 { try artifact(palette.view, "lab-channels-u8.png") }

            let (sheet, root) = try fillSheet(controller)
            let amount = try control(NSTextField.self, label: "Lightness (L*) physical value", in: root)
            let opacity = try control(NSTextField.self, label: "Lab fill opacity, percent", in: root)
            let message = try control(NSTextField.self, label: "Lab fill validation message", in: root)
            let apply = try button("Fill", in: root), cancel = try button("Cancel", in: root)
            expect([amount as NSView, opacity, message, apply, cancel].allSatisfy { visible($0, in: root) },
                   "\(tag): Fill fields, validation and actions are visible and in bounds")
            if component == .u8 { try artifact(root, "lab-fill-u8-initial.png") }
            try fillDraft("NaN", sheet: sheet, root: root); apply.performClick(nil)
            try wait({ window.attachedSheet === sheet && !message.stringValue.isEmpty }, "Invalid Lab draft remains open with reason")
            expect(try render(image) == original && document.undoInfo == originalUndo && document.pendingWork == 0,
                   "\(tag): invalid physical draft changes no pixels/history and queues nothing")
            if component == .u8 { try artifact(root, "lab-fill-u8-invalid.png") }
            try fillDraft("50", opacity: "101", sheet: sheet, root: root); apply.performClick(nil)
            expect(window.attachedSheet === sheet && message.stringValue.contains("opacity")
                   && document.pendingWork == 0 && document.recorder.pendingCount == 0,
                   "\(tag): out-of-range opacity stays open without a reservation")
            try cancelSheet(window, root: root)
            expect(try render(image) == original && document.undoInfo == originalUndo,
                   "\(tag): Cancel preserves pixels and history")

            let (staleSheet, staleRoot) = try fillSheet(controller)
            try fillDraft("50", sheet: staleSheet, root: staleRoot)
            try pick(.a, in: document)
            try button("Fill", in: staleRoot).performClick(nil)
            let staleReason = try control(NSTextField.self, label: "Lab fill validation message", in: staleRoot)
            expect(window.attachedSheet === staleSheet && staleReason.stringValue.contains("original Lab channel")
                   && document.selectedLabAxis?.role == .a && document.pendingWork == 0,
                   "\(tag): stale captured sheet refuses rather than redirecting to a*")
            expect(try render(image) == original && document.undoInfo == originalUndo,
                   "\(tag): refused captured Fill preserves all displayed pixels and history")
            try cancelSheet(window, root: staleRoot); try pick(.lightness, in: document)

            let (validSheet, validRoot) = try fillSheet(controller)
            try fillDraft("50", sheet: validSheet, root: validRoot)
            try button("Fill", in: validRoot).performClick(nil)
            try wait({ window.attachedSheet == nil }, "Accepted physical Fill dismisses its sheet")
            try drain(document)
            let filled = try render(image)
            expect(filled != original && document.undoInfo.undoCount == originalUndo.undoCount + 1,
                   "\(tag): physical Fill visibly changes pixels with exactly one Undo")
            guard let undo = window.undoManager else { throw NSError(domain: "LabUISmoke", code: 11) }
            try require(undo.canUndo, "Actual document Undo manager offers Undo")
            undo.undo(); try drain(document)
            expect(try render(image) == original, "\(tag): real Undo restores exact displayed pixels")
            try require(undo.canRedo, "Actual document Undo manager offers Redo")
            undo.redo(); try drain(document)
            expect(try render(image) == filled, "\(tag): real Redo restores exact filled pixels")

            let url = work.appendingPathComponent("lab-ui-\(tag).xcf")
            var saved = false, saveError: Error?
            document.save(to: url) { saveError = $0; saved = true }
            try wait({ saved }, "Lab Save completes"); try drain(document)
            if let saveError { throw saveError }
            document.noteSaved(to: url)
            expect(!document.hasUnsavedChanges && document.fileState.nativeURL == url,
                   "\(tag): successful XCF Save owns its target and clears dirty state")
            let reopened = try session.openImage(path: url.path)
            nativeOnly.append(reopened)
            let reopenedDocument = try ImageDocument(session: session, image: reopened, name: url.lastPathComponent, openedFrom: url)
            bareDocuments.append(reopenedDocument); observe(reopenedDocument)
            guard let axes = document.labAxes, let restored = reopenedDocument.labAxes else {
                throw NSError(domain: "LabUISmoke", code: 12, userInfo: [NSLocalizedDescriptionKey: "Reopened typed Lab axes missing"])
            }
            expect(restored.component == component && restored.axes.map(\.role) == axes.axes.map(\.role)
                   && restored.axes.map(\.uuid) == axes.axes.map(\.uuid) && restored.axes.map(\.name) == axes.axes.map(\.name)
                   && Set(restored.axes.map(\.id)).isDisjoint(with: Set(axes.axes.map(\.id))),
                   "\(tag): XCF reopen preserves roles/UUIDs/names and obtains distinct live handles")
            expect(try render(reopened) == filled && reopenedDocument.colorInfo.mode == .lab
                   && !reopenedDocument.hasUnsavedChanges && reopenedDocument.fileState.nativeURL == url,
                   "\(tag): reopened Lab document preserves displayed pixels and native file identity")

            if component == .u8 {
                let rgbImage = try session.newImage(width: 32, height: 24)
                nativeOnly.append(rgbImage)
                let rgb = try ImageDocument(session: session, image: rgbImage, name: "Lab tools RGB control")
                bareDocuments.append(rgb); observe(rgb)
                tools.retarget(to: rgb)
                guard let grid = descendants(tools.view).compactMap({ $0 as? ClassicToolGrid }).first else {
                    throw NSError(domain: "LabUISmoke", code: 13, userInfo: [NSLocalizedDescriptionKey: "Actual Tools grid missing"])
                }
                func enabled() -> Set<String> { Set(grid.slots.flatMap(\.tools).filter(\.isEnabled).map(\.id)) }
                expect(enabled().contains(ToolID.paintbrush.rawValue), "RGB tool grid initially enables Paintbrush")
                tools.retarget(to: document)
                var allowed: Set<ToolID> = [.hand, .zoom]
                if session.supportsLabBrush { allowed.insert(.paintbrush) }
                if session.supportsLabSelections {
                    allowed.formUnion([.rectangleSelect, .ellipseSelect, .lasso])
                }
                expect(enabled() == Set(allowed.map(\.rawValue)), "Lab tool grid enables exactly the qualified Brush, selection and viewing routes")
                tools.retarget(to: rgb)
                expect(enabled().contains(ToolID.paintbrush.rawValue), "RGB tool grid restores Paintbrush after Lab retarget")
                tools.retarget(to: document)

                // The saved document is clean. Close is requested synchronously
                // by the busy observer before the accepted Fill worker commits.
                try require(!document.hasUnsavedChanges, "Close regression starts from a clean saved Lab document")
                let beforeClose = try render(image), beforeCloseUndo = document.undoInfo.undoCount
                let (closingSheet, closingRoot) = try fillSheet(controller)
                try fillDraft("25", sheet: closingSheet, root: closingRoot)
                let oldObserver = document.onStateChange
                var requested = false, closeResult: Bool?
                document.onStateChange = {
                    if !requested && EngineActivity.shared.isBusy {
                        requested = true
                        controller.requestClose { closeResult = $0 }
                    }
                    oldObserver?()
                }
                defer { document.onStateChange = oldObserver }
                try button("Fill", in: closingRoot).performClick(nil)
                document.onStateChange = oldObserver
                try wait({ controller.closeStarted || (document.pendingWork == 0 && !EngineActivity.shared.isBusy
                         && window.attachedSheet !== closingSheet && window.attachedSheet != nil) },
                         "Close during accepted Fill reaches a save prompt or an observable erroneous close")
                expect(requested && !controller.closeStarted && !document.isClosing,
                       "busy-observer Close preserves the accepted Lab edit and keeps the document open")
                try require(!controller.closeStarted && !document.isClosing,
                            "Close must ask to save the accepted Lab Fill rather than discard it")
                guard let saveSheet = window.attachedSheet, let saveRoot = saveSheet.contentView else {
                    throw NSError(domain: "LabUISmoke", code: 14, userInfo: [NSLocalizedDescriptionKey: "Expected save confirmation sheet"])
                }
                _ = try button("Save", in: saveRoot); _ = try button("Don't Save", in: saveRoot)
                let closeCancel = try button("Cancel", in: saveRoot)
                let committed = try render(image)
                expect(committed != beforeClose && document.undoInfo.undoCount == beforeCloseUndo + 1,
                       "close confirmation appears after exactly one completed physical Fill")
                closeCancel.performClick(nil)
                try wait({ closeResult != nil && window.attachedSheet == nil }, "Cancel answers the pending Close request")
                let retained = try render(image)
                expect(closeResult == false && window.isVisible && !document.isClosing && document.hasUnsavedChanges
                       && retained == committed,
                       "Cancel Close retains the open, dirty window and exact completed edit")
            }
        }
    }
}
