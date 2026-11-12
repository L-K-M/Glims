import AppKit
import RigiUI

private final class LabSelectionUIHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false, expired = false
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func block() {
        lock.lock(); started = true; lock.unlock()
        let timeout = gate.wait(timeout: .now() + 30) == .timedOut
        lock.lock(); expired = timeout; lock.unlock()
    }
    func release() { gate.signal() }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseLabSelectionUI(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-selection-ui: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LabSelectionUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(20)
            while !ready() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            EngineSmokeTestHost.pumpEvents()
            try require(ready(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !document.targetCommandIsPending
                       && !EngineActivity.shared.isBusy }, "Selection document work drains")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control<T: NSView>(_ type: T.Type, label: String, in root: NSView) throws -> T {
            let rows = descendants(root).compactMap { $0 as? T }.filter { $0.accessibilityLabel() == label }
            try require(rows.count == 1, "One actual control has AX label '\(label)'")
            return rows[0]
        }
        func button(_ title: String, in root: NSView) throws -> NSButton {
            let rows = descendants(root).compactMap { $0 as? NSButton }.filter { $0.title == title }
            try require(rows.count == 1, "One actual button is named '\(title)'")
            return rows[0]
        }
        func visible(_ view: NSView, in root: NSView) -> Bool {
            !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true
                && view.bounds.width > 1 && view.bounds.height > 1
                && view.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(view.bounds)
                && root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.convert(view.bounds, to: root))
        }
        func render(_ image: Int32, at point: CGPoint? = nil) throws -> Data {
            let area = point.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) }
                ?? CGRect(x: 0, y: 0, width: 32, height: 24)
            let result = try session.render(image, scale: 1, area: area)
            guard result.bitsPerPixel >= 24, let bytes = result.dataProvider?.data as Data?, bytes.count >= 3 else {
                throw NSError(domain: "LabSelectionUISmoke", code: 2)
            }
            return bytes
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func item(_ action: Selector, in menu: NSMenu, tag: Int? = nil) throws -> NSMenuItem {
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for entry in menu.items {
                    if entry.action == action && (tag == nil || tag == entry.tag) { return entry }
                    if let child = entry.submenu, let found = find(child) { return found }
                }
                return nil
            }
            guard let result = find(menu) else { throw NSError(domain: "LabSelectionUISmoke", code: 3) }
            return result
        }

        try require(session.supportsLabSelections && session.supportsLabBrush, "Fixture requires qualified Lab selection and brush routes")
        let state = ToolState.shared, oldTool = ToolState.shared.current
        let oldOptions = state.selectOptions, oldBrush = state.brush(for: .paintbrush)
        let oldMenu = NSApp.mainMenu, menu = MainMenu.make(), app = AppController()
        let options = ToolOptionsPaletteController(), tools = ToolsPaletteController()
        let size = ToolOptionsPaletteController.definition.contentSize
        let panel = ClassicPaletteWindow(contentSize: NSSize(width: size.width + 2,
            height: size.height + PaletteChromeView.titleBarHeight + 1))
        let chrome = PaletteChromeView(title: "Tool Options")
        var owners: [DocumentWindowController] = [], looseImages: [Int32] = [], holds: [LabSelectionUIHold] = []
        var errors: [String] = []
        defer {
            holds.forEach { $0.release() }
            panel.makeFirstResponder(nil); options.retarget(to: nil); tools.retarget(to: nil)
            panel.orderOut(nil); panel.close()
            for owner in owners {
                if owner.imageDocument.labBrushStrokeIsActive { owner.imageDocument.cancelLabBrushStroke() }
                if let window = owner.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil)
                }
                if !owner.closeStarted { owner.closeDiscardingChanges() }
            }
            do { try wait({ !EngineActivity.shared.isBusy && owners.allSatisfy {
                $0.imageDocument.pendingWork == 0 && gone($0.imageDocument.image)
            } }, "All owned Lab selection images drain and close") }
            catch { expect(false, "cleanup drains work: \(error)") }
            expect(holds.allSatisfy { !$0.timedOut }, "bounded fixture holds were released rather than timing out")
            expect(owners.allSatisfy { $0.window?.attachedSheet == nil }, "cleanup leaves no owned sheets")
            documents.items.removeAll { candidate in owners.contains { $0.imageDocument === candidate } }
            for image in looseImages {
                do { try session.closeImage(image) } catch { expect(false, "loose image cleanup: \(error)") }
            }
            expect(errors.isEmpty, "no unexpected document or cleanup errors")
            state.selectOptions = oldOptions; state.update(.paintbrush) { $0 = oldBrush }
            state.select(oldTool); NSApp.mainMenu = oldMenu
        }
        state.selectOptions = .init(operation: .replace, antialias: false, feather: 0, cornerRadius: 0)
        state.update(.paintbrush) { $0 = EngineSession.Brush(); $0.size = 4; $0.hardness = 1 }
        state.select(.rectangleSelect); state.select(.paintbrush)
        NSApp.mainMenu = menu
        chrome.embedContent(options.view); panel.contentView = chrome
        _ = tools.view
        let all = try item(#selector(DocumentWindowController.selectAll(_:)), in: menu)
        let none = try item(#selector(DocumentWindowController.selectNone(_:)), in: menu)
        let inverse = try item(#selector(DocumentWindowController.selectInverse(_:)), in: menu)
        let fill = try item(#selector(DocumentWindowController.fill(_:)), in: menu)
        let featherMenu = try item(#selector(DocumentWindowController.featherSelection(_:)), in: menu)

        func target(_ owner: DocumentWindowController) throws {
            guard let window = owner.window else { throw NSError(domain: "LabSelectionUISmoke", code: 4) }
            panel.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeMain()
            try wait({ NSApp.isActive && NSApp.mainWindow === window && app.frontDocument === owner.imageDocument },
                     "Actual main window supplies the tool-menu target")
            options.retarget(to: owner.imageDocument); tools.retarget(to: owner.imageDocument)
            panel.orderFront(nil); EngineSmokeTestHost.pumpEvents(); options.view.layoutSubtreeIfNeeded()
            try require(app.frontDocument === owner.imageDocument, "Palette preserves the real menu target")
        }
        func attach(_ image: Int32, name: String) throws -> DocumentWindowController {
            looseImages.append(image)
            let document = try ImageDocument(session: session, image: image, name: name)
            let owner = DocumentWindowController(document: document, exportDirectory: work)
            owners.append(owner); documents.items.append(document); looseImages.removeAll { $0 == image }
            document.onError = { errors.append($0) }
            owner.showWindow(nil); owner.zoom(to: 400)
            try drain(document); try target(owner)
            if let axis = document.labAxes?.axes.first(where: { $0.role == .lightness }) {
                try require(document.selectLabAxis(axis), "L* target selection is accepted")
                try drain(document)
            }
            return owner
        }
        func choose(_ tool: ToolID) throws {
            let entry = try item(#selector(AppController.selectToolFromMenu(_:)), in: menu, tag: ToolMenuCatalog.tag(for: tool))
            try require(app.validateMenuItem(entry), "Actual tool menu enables \(tool.name)")
            try require(NSApp.sendAction(entry.action!, to: app, from: entry), "Actual tool menu action is dispatched")
            try require(state.current == tool, "Actual tool menu selects \(tool.name)")
            options.view.layoutSubtreeIfNeeded()
        }
        var eventTime = ProcessInfo.processInfo.systemUptime
        func timestamp() -> TimeInterval { eventTime += 0.01; return eventTime }
        func key(_ owner: DocumentWindowController, _ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            guard let window = owner.window else { throw NSError(domain: "LabSelectionUISmoke", code: 5) }
            panel.makeFirstResponder(nil); window.makeFirstResponder(owner.canvas)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: timestamp(), windowNumber: window.windowNumber, context: nil,
                    characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                    throw NSError(domain: "LabSelectionUISmoke", code: 6)
                }
                if type == .keyDown { owner.canvas.keyDown(with: event) } else { owner.canvas.keyUp(with: event) }
            }
            options.view.layoutSubtreeIfNeeded()
        }
        func mouse(_ owner: DocumentWindowController, _ type: NSEvent.EventType, _ point: CGPoint,
                   flags: NSEvent.ModifierFlags = []) throws {
            guard let window = owner.window else { throw NSError(domain: "LabSelectionUISmoke", code: 7) }
            let canvas = owner.canvas
            guard let event = NSEvent.mouseEvent(with: type,
                location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                modifierFlags: flags, timestamp: timestamp(), windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "LabSelectionUISmoke", code: 8)
            }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: throw NSError(domain: "LabSelectionUISmoke", code: 9)
            }
        }
        @discardableResult func drag(_ owner: DocumentWindowController, from start: CGPoint, to end: CGPoint,
                                    during: NSEvent.ModifierFlags = []) throws -> CGRect? {
            panel.makeFirstResponder(nil)
            try mouse(owner, .leftMouseDown, start)
            try mouse(owner, .leftMouseDragged, end, flags: during)
            let preview = owner.canvas.tools.selectionDragRect
            try mouse(owner, .leftMouseUp, end, flags: during)
            try drain(owner.imageDocument)
            return preview
        }
        func mode(_ value: EngineSession.SelectOperation) throws {
            let control = try control(NSSegmentedControl.self, label: "Selection mode", in: options.view)
            try require((0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
                        == ["New", "Add", "Subtract", "Intersect"], "All four actual selection modes are present")
            control.selectedSegment = Int(value.rawValue)
            try require(control.sendAction(control.action, to: control.target), "Selection mode action is delivered")
            try require(state.selectOptions.operation == value, "Selection mode action updates the owned option")
        }
        func draft(_ field: NSTextField, _ value: String, window: NSWindow) throws {
            window.makeKeyAndOrderFront(nil)
            try require(window.makeFirstResponder(field), "Actual numeric editor accepts focus")
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Actual numeric field editor exists")
            field.currentEditor()?.string = value; field.stringValue = value
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            try require(window.makeFirstResponder(nil), "Actual numeric editor commits")
            EngineSmokeTestHost.pumpEvents()
        }
        func numeric(_ title: String, _ value: String) throws {
            try draft(control(NSTextField.self, label: title + " value", in: options.view), value, window: panel)
        }
        func antialias(_ enabled: Bool) throws {
            let box = try button("Antialiasing", in: options.view)
            if (box.state == .on) != enabled { box.performClick(nil) }
            try require(state.selectOptions.antialias == enabled, "Actual antialias checkbox updates selection options")
        }
        func send(_ entry: NSMenuItem, _ owner: DocumentWindowController, validate: Bool = true) throws {
            if validate { try require(owner.validateMenuItem(entry), "Actual menu enables \(entry.title)") }
            guard let action = entry.action else { throw NSError(domain: "LabSelectionUISmoke", code: 10) }
            try require(NSApp.sendAction(action, to: owner, from: entry), "Actual selection menu action reaches its controller")
        }
        func bounds(_ owner: DocumentWindowController, _ expected: CGRect?, _ label: String) throws {
            let document = owner.imageDocument
            let native = try session.selectionBounds(image: document.image)
            let outline = try session.selectionOutline(image: document.image)
            expect(native == expected && document.selectionBounds == expected, label + ": native and cached bounds")
            expect(document.selectionOutline == outline && owner.canvas.selectionOutline == outline
                   && (expected == nil ? outline.isEmpty : !outline.isEmpty) && owner.canvas.showsSelectionEdges,
                   label + ": native, document and canvas marching ants agree")
        }
        func fillWitness(_ owner: DocumentWindowController, inside: [CGPoint], outside: [CGPoint],
                         soft: CGPoint? = nil, label: String) throws {
            let document = owner.imageDocument, before = try render(owner.imageDocument.image)
            let oldBounds = document.selectionBounds, oldOutline = document.selectionOutline
            let oldUndo = document.undoInfo.undoCount
            try send(fill, owner)
            try wait({ owner.window?.attachedSheet != nil }, "Actual Lab Fill sheet opens")
            guard let window = owner.window?.attachedSheet, let root = window.contentView else {
                throw NSError(domain: "LabSelectionUISmoke", code: 11)
            }
            try draft(control(NSTextField.self, label: "Lightness (L*) physical value", in: root), "0", window: window)
            try draft(control(NSTextField.self, label: "Lab fill opacity, percent", in: root), "100", window: window)
            try button("Fill", in: root).performClick(nil)
            try wait({ owner.window?.attachedSheet == nil }, "Actual Fill sheet closes")
            try drain(document)
            for point in inside {
                expect(Array(try render(document.image, at: point).prefix(3)) == [0, 0, 0], label + ": known selected sample fills black")
            }
            for point in outside {
                expect(Array(try render(document.image, at: point).prefix(3)) == [255, 255, 255], label + ": known excluded sample stays white")
            }
            if let soft {
                let sample = try render(document.image, at: soft)
                expect(sample[0] > 0 && sample[0] < 255, label + ": known boundary has fractional coverage")
            }
            expect(document.undoInfo.undoCount == oldUndo + 1, label + ": masked Fill makes one Undo")
            document.undo(); try drain(document)
            expect(try render(document.image) == before && document.selectionBounds == oldBounds
                   && document.selectionOutline == oldOutline, label + ": Fill Undo restores pixels without changing the mask")
        }
        func artifact() throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            do {
                try require(!directory.isEmpty, "Artifact directory is nonempty")
                guard let frame = panel.contentView?.superview else { throw NSError(domain: "LabSelectionUISmoke", code: 12) }
                frame.layoutSubtreeIfNeeded(); frame.displayIfNeeded()
                guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    throw NSError(domain: "LabSelectionUISmoke", code: 13)
                }
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw NSError(domain: "LabSelectionUISmoke", code: 14)
                }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("lab-selection-options.png"), options: .atomic)
                expect(true, "saved actual selection Options chrome artifact")
            } catch { expect(false, "selection artifact: \(error)"); throw error }
        }

        let a = CGRect(x: 4, y: 4, width: 12, height: 12)
        for component in [EngineSession.ColorComponent.u8, .float] {
            let tag = component == .u8 ? "u8" : "float"
            let owner = try attach(session.newLabImage(width: 32, height: 24, component: component), name: "Lab selection \(tag)")
            let document = owner.imageDocument, image = document.image
            let original = try render(image)
            try choose(.rectangleSelect); try choose(.paintbrush)
            try key(owner, "m", code: 46)
            expect(state.current == .rectangleSelect, "\(tag): actual M key chooses Rectangle")
            try mode(.replace); try numeric("Feather", "0"); try numeric("Corners", "0"); try antialias(false)
            let initialBounds = document.selectionBounds, initialOutline = document.selectionOutline
            let initialUndo = document.undoInfo.undoCount
            try drag(owner, from: a.origin, to: CGPoint(x: a.maxX, y: a.maxY))
            try bounds(owner, a, "\(tag) Rectangle")
            let rectangularOutline = document.selectionOutline
            expect(try render(image) == original && document.undoInfo.undoCount == initialUndo + 1,
                   "\(tag): selection changes mask/history once, leaving the Lab preview exact")
            document.undo(); try drain(document)
            expect(document.selectionBounds == initialBounds && document.selectionOutline == initialOutline,
                   "\(tag): selection Undo restores exact bounds and outline")
            document.redo(); try drain(document)
            expect(document.selectionBounds == a && document.selectionOutline == rectangularOutline,
                   "\(tag): selection Redo restores exact bounds and outline")
            try fillWitness(owner, inside: [CGPoint(x: 8, y: 8)], outside: [CGPoint(x: 1, y: 1)], label: "\(tag) New")

            try mode(.add); try drag(owner, from: CGPoint(x: 12, y: 4), to: CGPoint(x: 24, y: 16))
            try bounds(owner, CGRect(x: 4, y: 4, width: 20, height: 12), "\(tag) Add")
            try fillWitness(owner, inside: [CGPoint(x: 8, y: 8), CGPoint(x: 20, y: 8)],
                            outside: [CGPoint(x: 1, y: 1)], label: "\(tag) Add")
            try mode(.subtract); try drag(owner, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 10, y: 16))
            try bounds(owner, CGRect(x: 10, y: 4, width: 14, height: 12), "\(tag) Subtract")
            try fillWitness(owner, inside: [CGPoint(x: 20, y: 8)], outside: [CGPoint(x: 8, y: 8)], label: "\(tag) Subtract")
            try mode(.intersect); try drag(owner, from: CGPoint(x: 14, y: 8), to: CGPoint(x: 22, y: 20))
            try bounds(owner, CGRect(x: 14, y: 8, width: 8, height: 8), "\(tag) Intersect")
            try fillWitness(owner, inside: [CGPoint(x: 16, y: 12)],
                            outside: [CGPoint(x: 12, y: 12), CGPoint(x: 20, y: 6)], label: "\(tag) Intersect")
            try mode(.replace)
            let square = try drag(owner, from: CGPoint(x: 8, y: 6), to: CGPoint(x: 14, y: 9), during: .shift)
            expect(square == CGRect(x: 8, y: 6, width: 6, height: 6), "\(tag): live Shift rubber band has equal sides")
            try bounds(owner, square, "\(tag) constrained Rectangle")
            let centered = try drag(owner, from: CGPoint(x: 16, y: 12), to: CGPoint(x: 20, y: 15), during: .option)
            expect(centered == CGRect(x: 12, y: 9, width: 8, height: 6), "\(tag): live Option rubber band is centered on the press")
            try bounds(owner, centered, "\(tag) centered Rectangle")
            try key(owner, "m", code: 46, flags: .shift)
            expect(state.current == .ellipseSelect, "\(tag): actual Shift-M cycles to Ellipse")
            try drag(owner, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 20))
            try fillWitness(owner, inside: [CGPoint(x: 12, y: 12)], outside: [CGPoint(x: 4, y: 4)], label: "\(tag) Ellipse")
            try antialias(true)
            try drag(owner, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 20))
            try fillWitness(owner, inside: [CGPoint(x: 12, y: 12)], outside: [CGPoint(x: 1, y: 1)],
                            soft: CGPoint(x: 4, y: 8), label: "\(tag) antialiased Ellipse")
            try key(owner, "l", code: 37)
            expect(state.current == .lasso, "\(tag): actual L key chooses Lasso")
            try antialias(false)
            try mouse(owner, .leftMouseDown, CGPoint(x: 4, y: 4))
            try mouse(owner, .leftMouseDragged, CGPoint(x: 24, y: 4))
            try mouse(owner, .leftMouseDragged, CGPoint(x: 4, y: 20))
            try mouse(owner, .leftMouseUp, CGPoint(x: 4, y: 4)); try drain(document)
            expect(!document.selectionOutline.isEmpty && owner.canvas.selectionOutline == document.selectionOutline,
                   "\(tag): actual Lasso produces a mask and canvas ants")
            try fillWitness(owner, inside: [CGPoint(x: 8, y: 8)], outside: [CGPoint(x: 22, y: 18)], label: "\(tag) Lasso")

            try choose(.rectangleSelect); try numeric("Corners", "4")
            try drag(owner, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 20))
            try fillWitness(owner, inside: [CGPoint(x: 12, y: 12)], outside: [CGPoint(x: 4, y: 4)], label: "\(tag) rounded Rectangle")
            try numeric("Feather", "2"); try antialias(true)
            expect(state.selectOptions.cornerRadius == 4 && state.selectOptions.feather == 2 && state.selectOptions.antialias,
                   "\(tag): actual Corners/Feather/Antialiasing controls retain their requested values")
            let optionControls: [NSView] = [
                try control(NSSegmentedControl.self, label: "Selection mode", in: options.view),
                try control(NSTextField.self, label: "Feather value", in: options.view),
                try control(NSTextField.self, label: "Corners value", in: options.view),
                try button("Antialiasing", in: options.view)
            ]
            expect(optionControls.allSatisfy { visible($0, in: options.view) },
                   "\(tag): actual selection mode, numeric fields and antialias control fit the visible Options chrome")
            for control in optionControls where !visible(control, in: options.view) {
                print("selection layout: \(control.accessibilityLabel() ?? String(describing: type(of: control))) bounds=\(control.bounds) visible=\(control.visibleRect) root=\(options.view.bounds) converted=\(control.convert(control.bounds, to: options.view))")
            }
            if component == .u8 { try artifact() }
            try drag(owner, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 20))
            try fillWitness(owner, inside: [], outside: [CGPoint(x: 31, y: 23)],
                            soft: CGPoint(x: 4, y: 12), label: "\(tag) feathered rounded Rectangle")
            try numeric("Feather", "0"); try numeric("Corners", "0"); try antialias(false)
            try drag(owner, from: a.origin, to: CGPoint(x: a.maxX, y: a.maxY))
            let beforeCancel = document.undoInfo, outlineBeforeCancel = document.selectionOutline
            try mouse(owner, .leftMouseDown, CGPoint(x: 1, y: 1))
            try mouse(owner, .leftMouseDragged, CGPoint(x: 30, y: 22))
            try key(owner, "\u{1b}", code: 53)
            try mouse(owner, .leftMouseUp, CGPoint(x: 30, y: 22)); try drain(document)
            expect(document.selectionBounds == a && document.selectionOutline == outlineBeforeCancel
                   && document.undoInfo == beforeCancel && owner.canvas.tools.selectionDragRect == nil,
                   "\(tag): Escape cancels the uncommitted shape, including late release, without Undo")
            try mouse(owner, .leftMouseDown, CGPoint(x: 2, y: 2)); try mouse(owner, .leftMouseUp, CGPoint(x: 2, y: 2))
            try drain(document); try bounds(owner, nil, "\(tag) click without drag deselects")
            try send(all, owner); try drain(document)
            try bounds(owner, CGRect(x: 0, y: 0, width: 32, height: 24), "\(tag) actual Select All")
            try send(inverse, owner); try drain(document); try bounds(owner, nil, "\(tag) actual Inverse of All")
            try send(all, owner); try drain(document); try send(none, owner); try drain(document)
            try bounds(owner, nil, "\(tag) actual Select None")
            try drag(owner, from: a.origin, to: CGPoint(x: a.maxX, y: a.maxY))
            try send(inverse, owner); try drain(document)
            try fillWitness(owner, inside: [CGPoint(x: 1, y: 1)], outside: [CGPoint(x: 8, y: 8)], label: "\(tag) Inverse")
            try send(inverse, owner); try drain(document); try bounds(owner, a, "\(tag) double Inverse")
            expect(try render(image) == original && !owner.validateMenuItem(featherMenu),
                   "\(tag): selection operations preserve exact image pixels and keep unsupported menu operations disabled")

            if component == .u8 {
                let beforeBusy = document.undoInfo, busyOutline = document.selectionOutline
                let hold = LabSelectionUIHold(); holds.append(hold)
                var activityDone = false
                try require(EngineActivity.shared.perform(label: "Lab selection UI busy witness", document: document,
                    work: { hold.block() }, completion: { activityDone = true }), "Real exclusive activity is admitted")
                try wait({ hold.hasStarted }, "Real exclusive worker is held")
                expect([all, none, inverse].allSatisfy { !owner.validateMenuItem($0) }, "busy activity disables actual Lab selection menus")
                let errorCount = errors.count
                try send(all, owner, validate: false)
                expect(errors.count == errorCount + 1 && document.pendingWork == 0,
                       "forced selection action reports refusal rather than queuing during busy activity")
                errors.removeSubrange(errorCount..<errors.count)
                hold.release(); try wait({ activityDone }, "Busy witness releases"); try drain(document)
                expect(document.undoInfo == beforeBusy && document.selectionOutline == busyOutline,
                       "busy selection refusal preserves history and mask")

                try choose(.paintbrush)
                try draft(control(NSTextField.self, label: "Lab brush Lightness (L*) physical value", in: options.view), "0", window: panel)
                let strokeHistory = document.undoInfo
                try mouse(owner, .leftMouseDown, CGPoint(x: 8.5, y: 8.5)); try drain(document)
                let livePixels = try render(image)
                expect(document.labBrushStrokeIsActive && livePixels != original, "live Brush actually paints before selection refusal")
                expect([all, none, inverse].allSatisfy { !owner.validateMenuItem($0) }, "live Brush disables actual selection menus")
                let strokeErrors = errors.count
                try send(none, owner, validate: false)
                expect(errors.count == strokeErrors + 1 && document.labBrushStrokeIsActive,
                       "forced selection refuses without ending the live Brush")
                errors.removeSubrange(strokeErrors..<errors.count)
                try mouse(owner, .leftMouseDragged, CGPoint(x: 12.5, y: 8.5))
                try key(owner, "\u{1b}", code: 53); try mouse(owner, .leftMouseUp, CGPoint(x: 12.5, y: 8.5)); try drain(document)
                expect(try render(image) == original && document.selectionBounds == a
                       && document.selectionOutline == busyOutline && document.undoInfo == strokeHistory,
                       "selection refusal leaves Brush cancellable with exact image, mask and history restoration")
                try mouse(owner, .leftMouseDown, CGPoint(x: 2.5, y: 8.5))
                try mouse(owner, .leftMouseDragged, CGPoint(x: 20.5, y: 8.5))
                try mouse(owner, .leftMouseUp, CGPoint(x: 20.5, y: 8.5)); try drain(document)
                let paintedInside = try render(image, at: CGPoint(x: 8, y: 8))
                let untouchedLeft = try render(image, at: CGPoint(x: 2, y: 8))
                let untouchedRight = try render(image, at: CGPoint(x: 20, y: 8))
                expect(Array(paintedInside.prefix(3)) == [0, 0, 0]
                       && Array(untouchedLeft.prefix(3)) == [255, 255, 255]
                       && Array(untouchedRight.prefix(3)) == [255, 255, 255],
                       "real Brush across the mask paints only selected pixels")
                expect(document.undoInfo.undoCount == strokeHistory.undoCount + 1, "masked Brush commits one Undo")
                document.undo(); try drain(document)
                expect(try render(image) == original && document.selectionOutline == busyOutline,
                       "masked Brush Undo restores pixels and retains the selection")
            }

            let saveBounds = document.selectionBounds, saveOutline = document.selectionOutline
            let ids = try session.labAxes(image).axes.map(\.uuid)
            let url = work.appendingPathComponent("lab-selection-ui-\(tag).xcf")
            var saved = false, saveError: Error?
            document.save(to: url) { saveError = $0; saved = true }
            try wait({ saved }, "Lab selection XCF Save completes"); try drain(document)
            if let saveError { throw saveError }
            document.noteSaved(to: url)
            let reopened = try session.openImage(path: url.path); looseImages.append(reopened)
            expect(try session.selectionBounds(image: reopened) == saveBounds
                   && session.selectionOutline(image: reopened) == saveOutline && render(reopened) == original
                   && session.labAxes(reopened).axes.map(\.uuid) == ids && !document.hasUnsavedChanges
                   && document.fileState.nativeURL == url,
                   "\(tag): successful Save/reopen retains exact selection, Lab preview, identities and adopted destination")
        }

        let closing = try attach(session.newLabImage(width: 32, height: 24, component: .u8), name: "Queued Lab selection close")
        try choose(.rectangleSelect); try mode(.replace)
        let hold = LabSelectionUIHold(); holds.append(hold)
        closing.imageDocument.inputQueue.async { hold.block() }
        try wait({ hold.hasStarted }, "Input queue is held before selection admission")
        try mouse(closing, .leftMouseDown, a.origin)
        try mouse(closing, .leftMouseDragged, CGPoint(x: a.maxX, y: a.maxY))
        try mouse(closing, .leftMouseUp, CGPoint(x: a.maxX, y: a.maxY))
        expect(closing.imageDocument.pendingWork > 0, "released pointer selection is counted while queued")
        var closeObservation: Result<CGRect?, Error>?
        let closingImage = closing.imageDocument.image
        let priorStateChange = closing.imageDocument.onStateChange
        // Observe the counted input's final acknowledgement before its real
        // destruction callback runs. A separate, uncounted queue read would
        // race close and could report NOT_FOUND after a correct input drain.
        closing.imageDocument.onStateChange = { [weak document = closing.imageDocument] in
            if let document, document.isClosing, document.pendingWork == 0, closeObservation == nil {
                closeObservation = Result { try session.selectionBounds(image: closingImage) }
            }
            priorStateChange?()
        }
        closing.closeDiscardingChanges()
        expect(!gone(closingImage), "Close cannot destroy an image with accepted selection input still held")
        hold.release()
        try wait({ closeObservation != nil && gone(closingImage) && closing.imageDocument.pendingWork == 0 },
                 "Queued selection and Close both drain")
        closing.imageDocument.onStateChange = priorStateChange
        expect(try closeObservation?.get() == a && closing.closeStarted,
               "native queued selection commits before image destruction during accepted discard-close")

        let rgb = try attach(session.newImage(pixels: ClipboardImage(width: 32, height: 24,
            pixels: Data(repeating: 255, count: 32 * 24 * 4), origin: .zero)), name: "RGB selection after Lab")
        try choose(.rectangleSelect); try choose(.paintbrush); try key(rgb, "m", code: 46)
        let rgbOriginal = try render(rgb.imageDocument.image), rgbUndo = rgb.imageDocument.undoInfo.undoCount
        try mode(.replace); try drag(rgb, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 11, y: 10))
        try bounds(rgb, CGRect(x: 3, y: 3, width: 8, height: 7), "ordinary RGB pointer selection")
        let wand = try item(#selector(AppController.selectToolFromMenu(_:)), in: menu, tag: ToolMenuCatalog.tag(for: .magicWand))
        expect(app.validateMenuItem(wand) && rgb.validateMenuItem(featherMenu)
               && rgb.imageDocument.undoInfo.undoCount == rgbUndo + 1,
               "RGB retarget restores ordinary selection tools/menus and one-step mask Undo")
        rgb.imageDocument.undo(); try drain(rgb.imageDocument)
        expect(try render(rgb.imageDocument.image) == rgbOriginal && rgb.imageDocument.selectionBounds == nil,
               "ordinary RGB Undo restores its empty mask with unchanged image pixels")
    }
}
