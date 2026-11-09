import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseCurves(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(12)
            while !condition() && Date() < limit { spin(0.01) }
        }
        let bytes = Data((0..<(24 * 16)).flatMap { _ in [UInt8(192), 64, 96, 160] })
        let image = try session.newImage(pixels: ClipboardImage(width: 24, height: 16, pixels: bytes, origin: .zero))
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Curves A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Curves B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        var ownedPanels: [CurvesPanel] = []
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? CurvesPanel)?.cancel()
            for panel in ownedPanels { panel.cancel(); panel.window?.orderOut(nil) }
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() { document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03) }
        let operations = try session.filterOperations(); NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gimp:curves" }),
              let layer = document.activeLayer, let menu = NSApp.mainMenu else {
            return check(false, "Curves and its captured target are available")
        }
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu,
              let item = adjust.item(withTitle: "Curves…"), let action = item.action else {
            return check(false, "Image Adjust exposes the dedicated Curves command")
        }
        func mouse(_ panel: CurvesPanel, _ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            let rect = panel.graph.bounds.insetBy(dx: 12, dy: 12)
            let local = NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            return NSEvent.mouseEvent(with: type, location: panel.graph.convert(local, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.window?.windowNumber ?? 0, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func key(_ panel: CurvesPanel, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.window?.windowNumber ?? 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        // Controlled replies reproduce real field-editor/mouse reentry without
        // relying on the native worker to lose a scheduling race.
        do {
            let filter = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
            var patches: [CurvesDraft.Patch] = []
            var replies: [@MainActor (Result<EngineSession.CurvesSettings, Error>) -> Void] = []
            guard let panel = CurvesPanel(document: document, filter: filter, settings: try session.curvesSettings(filter), write: { _, patch, reply in
                patches.append(patch); replies.append(reply)
            }) else { try session.abortFilter(filter); return check(false, "controlled mode panel constructs") }
            ownedPanels.append(panel); panel.window?.makeKeyAndOrderFront(nil)
            panel.window?.makeFirstResponder(panel.outputField)
            guard let editor = panel.outputField.currentEditor() else {
                panel.cancel(); settle(); return check(false, "controlled mode test obtains a field editor")
            }
            editor.string = "0.2"
            panel.modePopup.selectItem(at: 1); panel.modeChanged(panel.modePopup)
            let expected = CurvesDraft.Patch.curve(.smooth(channel: .value,
                points: [.init(x: 0, y: 0.2), .init(x: 1, y: 1)]))
            check(patches == [expected] && replies.count == 1 && panel.modePopup.indexOfSelectedItem == 0,
                  "mode conversion waits for an active smooth field's authoritative samples")
            panel.cancel(); settle()
        }
        do {
            let filter = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
            let settings = try session.curvesSettings(filter)
            var patches: [CurvesDraft.Patch] = []
            var replies: [@MainActor (Result<EngineSession.CurvesSettings, Error>) -> Void] = []
            guard let panel = CurvesPanel(document: document, filter: filter, settings: settings, write: { _, patch, reply in
                patches.append(patch); replies.append(reply)
            }) else { try session.abortFilter(filter); return check(false, "controlled insertion panel constructs") }
            ownedPanels.append(panel); panel.window?.makeKeyAndOrderFront(nil)
            panel.outputField.stringValue = "0.2"; panel.fieldsChanged(panel.outputField)
            check(patches.count == 1 && replies.count == 1, "insertion test holds one smooth edit's reply")
            panel.graph.mouseDown(with: mouse(panel, .leftMouseDown, 0.5, 0.6))
            check(panel.graph.isInteracting && panel.graph.selectedPoint == 1,
                  "new graph point is locally selected during its gesture")
            var accepted = settings; accepted.value.points[0].y = 0.2
            accepted.value.samples = Array(repeating: 0.42, count: 256)
            replies.first?(.success(accepted))
            check(panel.graph.isInteracting && panel.graph.selectedPoint == 1,
                  "older native reply preserves the active new-point selection")
            panel.graph.mouseUp(with: mouse(panel, .leftMouseUp, 0.5, 0.6))
            check(panel.graph.selectedPoint == 1 && panel.indexField.stringValue == "1",
                  "completed graph insertion keeps its new index for numeric edits")
            panel.cancel(); settle()
        }
        do {
            let filter = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
            let settings = try session.curvesSettings(filter)
            var patches: [CurvesDraft.Patch] = []
            var replies: [@MainActor (Result<EngineSession.CurvesSettings, Error>) -> Void] = []
            guard let panel = CurvesPanel(document: document, filter: filter, settings: settings, write: { _, patch, reply in
                patches.append(patch); replies.append(reply)
            }) else { try session.abortFilter(filter); return check(false, "controlled deferred-refresh panel constructs") }
            ownedPanels.append(panel); panel.window?.makeKeyAndOrderFront(nil)
            panel.outputField.stringValue = "0.2"; panel.fieldsChanged(panel.outputField)
            check(patches.count == 1 && replies.count == 1, "deferred-refresh test holds one smooth edit's reply")
            panel.graph.mouseDown(with: mouse(panel, .leftMouseDown, 0, 0.2))
            var accepted = settings; accepted.value.points[0].y = 0.2
            accepted.value.samples = Array(repeating: 0.42, count: 256)
            replies.first?(.success(accepted))
            panel.graph.mouseUp(with: mouse(panel, .leftMouseUp, 0, 0.2))
            check(!panel.graph.isInteracting && panel.graph.state.samples == accepted.value.samples,
                  "unchanged graph gesture applies the deferred native sample refresh")
            panel.cancel(); settle()
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        func open() -> CurvesPanel? {
            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            return controller.previewPanel as? CurvesPanel
        }
        guard let panel = open(), let filter = panel.filter else { return check(false, "Curves opens its dedicated form") }
        check(try panel.channelPopup.itemTitles == ["Value", "Red", "Green", "Blue", "Alpha"] &&
              session.curvesSettings(filter).trc == .perceptual,
              "Curves shows five channels and native perceptual default")
        front.window?.makeKeyAndOrderFront(nil)
        panel.outputField.stringValue = "0.125"; panel.fieldsChanged(panel.outputField); settle()
        let initial = try session.curvesSettings(filter)
        check(initial.value.points.first?.y == 0.125,
              "numeric control changes authoritative native Value points")
        check(try session.copyPixels(image, merged: true).pixels != original &&
              session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "Curves preview edits its captured document while the other image remains exact")
        panel.graph.mouseDown(with: mouse(panel, .leftMouseDown, 0.5, 0.6))
        panel.graph.mouseUp(with: mouse(panel, .leftMouseUp, 0.5, 0.6)); settle()
        check(try session.curvesSettings(filter).value.points.count == 3,
              "graph insertion reaches the actual native preview")
        panel.graph.selectedPoint = 1
        panel.graph.keyDown(with: key(panel, 126)); settle()
        check(try abs(session.curvesSettings(filter).value.points[1].y - (0.6 + 1.0 / 255)) < 1e-9,
              "graph arrow key nudges the selected native point")
        panel.pointKindPopup.selectItem(at: 1); panel.pointTypeChanged(panel.pointKindPopup); settle()
        check(try session.curvesSettings(filter).value.points[1].kind == .corner,
              "selected control point switches to native Corner interpolation")
        panel.graph.keyDown(with: key(panel, 51)); settle()
        check(try session.curvesSettings(filter).value.points.count == 2,
              "graph Delete removes the selected native point")
        let beforeDrag = try session.curvesSettings(filter)
        panel.graph.mouseDown(with: mouse(panel, .leftMouseDown, 0, 0.125))
        panel.graph.mouseDragged(with: mouse(panel, .leftMouseDragged, 0, 0.3))
        panel.graph.keyDown(with: key(panel, 53))
        panel.graph.mouseUp(with: mouse(panel, .leftMouseUp, 0, 0.3)); settle()
        check(try session.curvesSettings(filter) == beforeDrag && !panel.graph.isInteracting,
              "Escape cancels an unfinished graph drag without a native edit")
        for selected in 1...4 {
            panel.channelPopup.selectItem(at: selected); panel.channelChanged(panel.channelPopup)
            panel.outputField.stringValue = String(Double(selected) / 20)
            panel.fieldsChanged(panel.outputField); settle()
            let channel = EngineSession.CurveChannel(rawValue: UInt32(selected + 1))!
            check(try session.curvesSettings(filter)[channel].points.first?.y == Double(selected) / 20,
                  "native channel \(selected) accepts an independent point edit")
        }
        panel.modePopup.selectItem(at: 1); panel.modeChanged(panel.modePopup); settle()
        check(try session.curvesSettings(filter).alpha.kind == .free,
              "Freehand conversion uses accepted native samples")
        panel.indexField.stringValue = "127"; panel.fieldsChanged(panel.indexField)
        panel.outputField.stringValue = "0.75"; panel.fieldsChanged(panel.outputField); settle()
        check(try session.curvesSettings(filter).alpha.samples[127] == 0.75,
              "individual Free sample edit reaches native sample127")
        panel.graph.mouseDown(with: mouse(panel, .leftMouseDown, 0.25, 0.2))
        panel.graph.mouseDragged(with: mouse(panel, .leftMouseDragged, 0.75, 0.8))
        panel.graph.mouseUp(with: mouse(panel, .leftMouseUp, 0.75, 0.8)); settle()
        let painted = try session.curvesSettings(filter)
        check(abs(painted.alpha.samples[64] - 0.2) < 1e-9 && abs(painted.alpha.samples[191] - 0.8) < 1e-9,
              "Freehand drag writes its complete native sample span")
        panel.resetChannel(nil); settle()
        let reset = try session.curvesSettings(filter)
        let resetError = zip(reset.alpha.samples, EngineSession.CurveState().samples)
            .map { abs($0 - $1) }.max() ?? .infinity
        print("Curves native Reset: max sample error \(resetError), value preserved \(reset.value == painted.value), red preserved \(reset.red == painted.red)")
        check(reset.alpha.kind == .smooth && reset.alpha.points.count == 2 &&
              resetError < 1e-12 && reset.value == painted.value && reset.red == painted.red,
              "Reset channel restores native identity shape and retains the other channels")
        panel.trcPopup.selectItem(at: 0); panel.trcChanged(panel.trcPopup); settle()
        check(try session.curvesSettings(filter).trc == .linear && session.curvesSettings(filter).value == reset.value,
              "global transfer curve writes preserve native channel payloads")
        let acceptedSettings = try session.curvesSettings(filter)
        panel.outputField.stringValue = "invalid"
        panel.channelPopup.selectItem(at: 0); panel.channelChanged(panel.channelPopup); settle()
        check(try panel.channelPopup.indexOfSelectedItem == 4 && panel.outputField.stringValue == "invalid" &&
              panel.lastError != nil && session.curvesSettings(filter) == acceptedSettings,
              "invalid text keeps its channel and draft without native mutation")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Curves Cancel restores exact original pixels and history")
        guard let applying = open() else { return check(false, "Curves reopens after Cancel") }
        applying.outputField.stringValue = "0.125"; applying.fieldsChanged(applying.outputField); settle()
        applying.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        check(effects.count == 1 && effects.first?.operation == operation.name && applied != original,
              "Apply stores one editable Curves effect")
        check(try session.undoInfo(image).undoCount == baseline + 1,
              "Curves Apply contributes one Undo")
        guard let effect = effects.first else { return }
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? CurvesPanel, let editingFilter = editing.filter else {
            return check(false, "committed Curves reopens in its dedicated form")
        }
        check(try session.curvesSettings(editingFilter).value.points.first?.y == 0.125,
              "existing Curves form loads exact accepted control points")
        editing.cancel(); settle()
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original, "Curves Undo restores original pixels")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == applied, "Curves Redo restores accepted pixels")
        let path = work.appendingPathComponent("curves-controls.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        defer { try? session.closeImage(reopened) }
        check(try session.copyPixels(reopened, merged: true).pixels == applied,
              "Curves XCF reopens with its real rendered result")
    }
}
