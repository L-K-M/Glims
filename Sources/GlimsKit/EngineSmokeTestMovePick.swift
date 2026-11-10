import AppKit

private struct MovePickBuffer: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
}

private struct MovePickContent: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let channels: [EngineSession.Channel]
    let selectedChannels: [Int32]
    let floating: EngineSession.FloatingState
    let composite: MovePickBuffer
    let drawables: [MovePickBuffer]
    let locks: [EngineSession.LayerLockState]
    let masks: [EngineSession.MaskState]
    let selection: MovePickBuffer
    let guides: [EngineSession.Guide]
}

private struct MovePickSnapshot: Equatable {
    let content: MovePickContent
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

private final class MovePickInputHold: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func block() {
        ready.signal()
        if release.wait(timeout: .now() + 30) != .success {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
}

@MainActor
extension EngineSmokeTest {
    /// Tests only: finds the future mode through actual UI, never a future
    /// Swift property/type. Missing mode on the old frontend is explicit RED.
    static func exerciseMovePick(_ session: EngineSession, work: URL,
                                 documents: DocumentList, busyRestoreOnly: Bool = false) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) { count += 1; check(value, "Move pick: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MovePickFixture", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                if condition() { return true }
                EngineSmokeTestHost.pumpEvents()
            } while Date() < deadline
            return condition()
        }
        func all<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all($0, type) }
        }
        var owners: [DocumentWindowController] = []
        var loose: [Int32] = []
        var holds: [MovePickInputHold] = []
        let priorTool = ToolState.shared.current
        let options = ToolOptionsPaletteController()
        let panel = NSPanel(contentRect: CGRect(x: 20, y: 30, width: 280, height: 210),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        var priorMode: String?
        let board = NSPasteboard.withUniqueName()
        func mode() -> NSPopUpButton? {
            all(options.view, NSPopUpButton.self).first {
                $0.identifier?.rawValue == "move-target-mode" || $0.accessibilityLabel() == "Move target"
                    || $0.itemTitles == ["Current Layer", "Pick Layer or Guide"]
            }
        }
        func selectMode(_ title: String) throws {
            guard let control = mode(), control.itemTitles.contains(title) else {
                throw NSError(domain: "MovePickFixture", code: 2)
            }
            control.selectItem(withTitle: title)
            try require(control.sendAction(control.action, to: control.target), "Move mode control has no working action")
            try require(mode()?.selectedItem?.title == title, "Move mode did not reconcile its actual control")
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            holds.forEach { $0.release.signal() }
            if let priorMode {
                ToolState.shared.select(.move)
                try? selectMode(priorMode)
            }
            for owner in owners { owner.window?.close() }
            expect(wait { owners.allSatisfy { gone($0.imageDocument.image) && $0.imageDocument.pendingWork == 0 } },
                   "all owned windows/renderers/native images drain before engine shutdown")
            for image in loose { try? session.closeImage(image) }
            expect(loose.allSatisfy { gone($0) }, "every independent reference image closes")
            panel.close()
            expect(owners.allSatisfy { $0.window?.isVisible != true && $0.window?.attachedSheet == nil }
                    && !panel.isVisible && panel.attachedSheet == nil, "no owned window or dialog remains visible")
            expect(holds.allSatisfy { !$0.expired }, "no queue hold timeout substituted for an explicit release")
            documents.items.removeAll { doc in owners.contains { $0.imageDocument === doc } }
            ToolState.shared.select(priorTool)
            board.releaseGlobally()
            let smokeCase = busyRestoreOnly ? "move-pick-busy-restore" : "move-pick"
            print("     \(smokeCase) checks: \(count)")
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "accepted Move work did not drain")
        }
        func enqueueHold(_ document: ImageDocument) -> MovePickInputHold {
            let hold = MovePickInputHold(); holds.append(hold)
            document.inputQueue.async { hold.block() }
            return hold
        }
        func started(_ hold: MovePickInputHold) throws {
            var latched = false
            try require(wait {
                if !latched { latched = hold.ready.wait(timeout: .now()) == .success }
                return latched
            }, "owned queue hold did not start")
        }
        func hold(_ document: ImageDocument) throws -> MovePickInputHold {
            try drain(document)
            let hold = enqueueHold(document); try started(hold); return hold
        }
        func buffer(_ image: CGImage?) throws -> MovePickBuffer {
            guard let image, let bytes = image.dataProvider?.data as Data? else {
                throw NSError(domain: "MovePickFixture", code: 3)
            }
            return .init(width: image.width, height: image.height, pixels: bytes)
        }
        func snapshot(_ image: Int32, normalized: Bool = false) throws -> MovePickSnapshot {
            let info = try session.info(image), rows = try session.layers(image)
            let channels = try session.channels(image)
            try require(channels.isEmpty, "unexpected saved channel in owned layer fixture")
            let ids = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, Int32($0.offset + 1)) })
            func id(_ value: Int32) -> Int32 { normalized && value != 0 ? (ids[value] ?? -1) : value }
            let normalizedRows = rows.map {
                EngineSession.Layer(id: id($0.id), parent: id($0.parent), depth: $0.depth, kind: $0.kind,
                    name: $0.name, mode: $0.mode, isVisible: $0.isVisible, hasMask: $0.hasMask,
                    isSelected: $0.isSelected, opacity: $0.opacity, bounds: $0.bounds,
                    filterCount: $0.filterCount)
            }
            var pixels: [MovePickBuffer] = [], locks: [EngineSession.LayerLockState] = [], masks: [EngineSession.MaskState] = []
            for row in rows {
                let copied = try buffer(session.drawableThumbnail(row.id, image: image, maxSize: 256))
                try require(copied.width == Int(row.bounds.width) && copied.height == Int(row.bounds.height), "drawable oracle was downscaled")
                pixels.append(copied); locks.append(try session.layerState(row.id, image: image))
                if row.hasMask {
                    var mask = try session.layerMask(row.id, image: image)
                    pixels.append(try buffer(session.drawableThumbnail(mask.mask, image: image, maxSize: 256)))
                    if normalized { mask.mask = Int32(masks.count + 1) }
                    masks.append(mask)
                }
            }
            let undo = try session.undoInfo(image), history = try session.history(image)
            let probe = try session.duplicateImage(image)
            defer { try? session.closeImage(probe) }
            let channel = try session.channelFromSelection(probe, name: "Move selection oracle")
            let coverage = try buffer(session.drawableThumbnail(channel, image: probe, maxSize: 256))
            try require(coverage.width == info.width && coverage.height == info.height,
                        "selection oracle was not full resolution")
            try require(try session.undoInfo(image) == undo && session.history(image) == history,
                        "selection probe changed the original history")
            let floating = try session.floatingSelection(image)
            let guides = try session.guides(image).enumerated().map {
                EngineSession.Guide(id: normalized ? Int32($0.offset + 1) : $0.element.id,
                                    orientation: $0.element.orientation, position: $0.element.position)
            }
            return MovePickSnapshot(content: .init(info: info, layers: normalizedRows,
                selected: try session.selectedLayers(image).map { id($0) }, channels: channels,
                selectedChannels: try session.selectedItems(.channel, image: image),
                floating: .init(floating: id(floating.floating), target: id(floating.target), targetKind: floating.targetKind),
                composite: try buffer(session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))),
                drawables: pixels, locks: locks, masks: masks, selection: coverage, guides: guides), undo: undo, history: history)
        }
        let width = 128, height = 96
        var baseBytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                baseBytes.append(UInt8((x * 7 + y * 11) % 256))
                baseBytes.append(UInt8((x * 17 + y * 3) % 256))
                baseBytes.append(UInt8((x + y * 23 + 19) % 256))
                baseBytes.append((96..<108).contains(x) && (76..<88).contains(y) ? 0 : 255)
            }
        }
        let base = ClipboardImage(width: width, height: height, pixels: Data(baseBytes), origin: .zero)
        var topBytes: [UInt8] = []
        for y in 0..<12 {
            for x in 0..<12 {
                topBytes.append(UInt8(160 + (x * 3 + y * 5) % 96))
                topBytes.append(UInt8((x * 13 + y * 7) % 150))
                topBytes.append(UInt8(20 + (x * 5 + y * 11) % 160))
                topBytes.append((5...7).contains(x) && (5...7).contains(y) ? 0 : (x == 1 && y == 1 ? 1 : 255))
            }
        }
        let payload = ClipboardImage(width: 12, height: 12, pixels: Data(topBytes), origin: CGPoint(x: 24, y: 24))
        try payload.write(to: board)
        var select = EngineSession.SelectOptions(); select.antialias = false
        typealias Scene = (owner: DocumentWindowController, bottom: Int32, top: Int32, group: Int32?)
        func image(floating: Bool = false, grouped: Bool = false) throws -> (Int32, Int32, Int32, Int32?) {
            let image = try session.newImage(pixels: base); loose.append(image)
            guard let bottom = try session.layers(image).first?.id else { throw NSError(domain: "MovePickFixture", code: 4) }
            // Paste Into centers a 12px payload on this 24px selection:
            // both ordinary and floating payloads therefore start at (24,24).
            try session.select(.rectangle(CGRect(x: 18, y: 18, width: 24, height: 24)), image: image, options: select)
            let top: Int32
            if floating { top = try session.pasteInto(image, target: bottom, pixels: payload) }
            else { top = try session.pastePixels(image, pixels: payload, at: payload.origin) }
            try require(try session.layers(image).first(where: { $0.id == top })?.bounds
                        == CGRect(x: 24, y: 24, width: 12, height: 12), "native payload placement does not match the literal opacity points")
            var group: Int32?
            if grouped {
                let value = try session.createGroup(image: image, index: 0, name: "Pick group")
                try session.reparentLayer(top, image: image, toParent: value, index: 0)
                group = value
            }
            if !floating { try session.selectLayer(bottom, image: image) }
            return (image, bottom, top, group)
        }
        func scene(_ name: String, floating: Bool = false, grouped: Bool = false) throws -> Scene {
            let fixture = try image(floating: floating, grouped: grouped)
            let doc = try ImageDocument(session: session, image: fixture.0, name: name)
            let owner = DocumentWindowController(document: doc)
            owners.append(owner); documents.items.append(doc); loose.removeAll { $0 == fixture.0 }
            owner.showWindow(nil); owner.window?.contentView?.layoutSubtreeIfNeeded()
            try drain(doc)
            return (owner, fixture.1, fixture.2, fixture.3)
        }
        func front(_ owner: DocumentWindowController) throws -> NSWindow {
            guard let window = owner.window else { throw NSError(domain: "MovePickFixture", code: 5) }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeMain()
            try require(wait { NSApp.keyWindow === window && NSApp.mainWindow === window }, "actual key/main focus did not settle")
            return window
        }
        func mouse(_ owner: DocumentWindowController, _ type: NSEvent.EventType, _ point: CGPoint,
                   flags: NSEvent.ModifierFlags = []) throws {
            guard let window = owner.window else { throw NSError(domain: "MovePickFixture", code: 6) }
            let location = owner.canvas.convert(CGPoint(x: point.x * owner.canvas.scale, y: point.y * owner.canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "MovePickFixture", code: 7)
            }
            switch type {
            case .leftMouseDown: owner.canvas.mouseDown(with: event)
            case .leftMouseDragged: owner.canvas.mouseDragged(with: event)
            case .leftMouseUp: owner.canvas.mouseUp(with: event)
            default: throw NSError(domain: "MovePickFixture", code: 8)
            }
        }
        func key(_ owner: DocumentWindowController, down: Bool = true, code: UInt16,
                 characters: String, flags: NSEvent.ModifierFlags = []) throws {
            guard let window = owner.window,
                  let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                    modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw NSError(domain: "MovePickFixture", code: 9)
            }
            if down { owner.canvas.keyDown(with: event) } else { owner.canvas.keyUp(with: event) }
        }
        let opaque = CGPoint(x: 26, y: 26), hole = CGPoint(x: 30, y: 30)
        let miss = CGPoint(x: 100, y: 80), delta = CGSize(width: 7, height: 4)
        func end(_ point: CGPoint, _ delta: CGSize) -> CGPoint { CGPoint(x: point.x + delta.width, y: point.y + delta.height) }
        func selected(_ owner: DocumentWindowController, _ id: Int32) throws {
            try require(wait { (try? session.selectedLayers(owner.imageDocument.image)) == [id]
                && owner.imageDocument.pendingWork == 0 }, "native press selection/ack did not settle")
        }
        func reference(_ fixture: (Int32, Int32, Int32, Int32?), moving: Int32, by offset: CGSize) throws {
            try session.selectLayer(moving, image: fixture.0)
            try session.moveLayer(moving, image: fixture.0, by: offset)
        }
        ToolState.shared.select(.move)
        _ = options.view
        let first = try scene("Move mode baseline")
        options.retarget(to: first.owner.imageDocument)
        panel.contentView = options.view; panel.orderFront(nil)
        expect(NSApp.isRunning, "fixture owns an actual launched AppKit host")
        expect(mode() != nil, "Tool Options contains the actual Move target mode (old-frontend missing-mode RED)")
        guard let initial = mode() else {
            print("     remaining Move pick behavior groups NOT RUN: required mode control is absent")
            return
        }
        priorMode = initial.selectedItem?.title
        expect(initial.itemTitles == ["Current Layer", "Pick Layer or Guide"] && initial.selectedItem?.title == "Current Layer",
               "the honest full Move mode defaults to the existing Current Layer behavior")
        try selectMode("Pick Layer or Guide")

        if busyRestoreOnly {
            func cancelDuringActivity(_ fixture: Scene, newerChoice: (Int32, MovePickSnapshot)? = nil) throws {
                let owner = fixture.owner
                let document = owner.imageDocument
                let image = document.image
                _ = try front(owner)
                try selected(owner, fixture.bottom)
                let before = try snapshot(image)
                try mouse(owner, .leftMouseDown, opaque)
                try selected(owner, fixture.top)
                let picked = try snapshot(image)
                expect(before.content.selected == [fixture.bottom] && picked.content.selected == [fixture.top]
                        && document.activeLayer == fixture.top && owner.canvas.tools.hasPendingInteraction
                        && picked.content.composite == before.content.composite
                        && picked.content.drawables == before.content.drawables
                        && picked.content.coverage == before.content.coverage
                        && picked.undo == before.undo && picked.history == before.history,
                       "native Pick acknowledges B from A with no pixel, mask or history change")

                let activity = EngineActivity.shared
                let gate = MovePickInputHold()
                holds.append(gate)
                var activityFinished = false
                let label = "Move Pick cancellation activity"
                try require(activity.perform(label: label, work: { gate.block() }, completion: { activityFinished = true }),
                            "exclusive activity was not admitted")
                defer { gate.release.signal() }
                try started(gate)
                let heldTarget = try session.selectedLayers(image)
                expect(activity.label == label && !activityFinished && !document.acceptsEdits
                        && heldTarget == [fixture.top],
                       "real exclusive activity holds edit admission with native B still selected")

                var explicitChoiceRan = false
                if let (id, _) = newerChoice {
                    // The new user intent was submitted after Pick. Use the
                    // real idle queue to admit it before deferred restoration.
                    activity.whenIdle {
                        document.selectLayer(id)
                        explicitChoiceRan = true
                    }
                }
                try key(owner, code: 53, characters: "\u{1b}")
                let cancelledTarget = try session.selectedLayers(image)
                expect(activity.isBusy && !owner.canvas.tools.hasPendingInteraction
                        && cancelledTarget == [fixture.top],
                       "Escape retires the gesture while the native target is still held")

                gate.release.signal()
                try require(wait { activityFinished }, "exclusive activity did not complete")
                try drain(document)
                let settled = try snapshot(image)
                if let (id, expected) = newerChoice {
                    expect(explicitChoiceRan && settled.content.selected == [id] && settled == expected,
                           "the newer explicit target wins before deferred restore, with exact pixels and Undo")
                } else {
                    expect(settled == before && document.activeLayer == fixture.bottom,
                           "after busy Escape, idle cleanup restores native A with exact pixels, mask and Undo")
                }

                try mouse(owner, .leftMouseUp, end(opaque, delta))
                try drain(document)
                expect(try snapshot(image) == settled, "late release after busy cancellation stays inert")
            }

            try cancelDuringActivity(first)
            let superseded = try scene("Busy cancellation superseded")
            let document = superseded.owner.imageDocument
            guard let later = try session.layerCommand(.new, image: document.image) else {
                throw NSError(domain: "MovePickFixture", code: 15)
            }
            try session.selectLayer(later, image: document.image)
            let expected = try snapshot(document.image)
            try session.selectLayer(superseded.bottom, image: document.image)
            try document.reload()
            try drain(document)
            try cancelDuringActivity(superseded, newerChoice: (later, expected))
            return
        }

        // Inactive: the actual native hit is selected/acknowledged at PRESS.
        _ = try front(first.owner)
        let beforePress = try snapshot(first.owner.imageDocument.image)
        try mouse(first.owner, .leftMouseDown, opaque)
        try selected(first.owner, first.top)
        let pressed = try snapshot(first.owner.imageDocument.image)
        expect(pressed.content.selected == [first.top] && first.owner.imageDocument.activeLayer == first.top,
               "inactive Pick selects the literal opaque upper layer at press, before release")
        expect(pressed.undo == beforePress.undo && pressed.history == beforePress.history
                && pressed.content.composite == beforePress.content.composite && pressed.content.drawables == beforePress.content.drawables,
               "press selection changes no pixel or native history")
        try mouse(first.owner, .leftMouseDragged, end(opaque, delta))
        expect(try snapshot(first.owner.imageDocument.image) == pressed, "drag preview remains view-only after the press ack")
        try mouse(first.owner, .leftMouseUp, end(opaque, delta)); try drain(first.owner.imageDocument)
        let moved = try snapshot(first.owner.imageDocument.image)
        let ref = try image(); try reference(ref, moving: ref.2, by: delta)
        expect(try snapshot(first.owner.imageDocument.image, normalized: true).content == snapshot(ref.0, normalized: true).content,
               "release moves only the captured native hit and matches the independent direct move")
        expect(moved.undo.undoCount == pressed.undo.undoCount + 1, "a picked move has one native Undo")
        first.owner.imageDocument.undo(); try drain(first.owner.imageDocument)
        expect(try snapshot(first.owner.imageDocument.image).content == pressed.content, "Undo restores pre-move bytes and keeps the picked transient target")
        first.owner.imageDocument.redo(); try drain(first.owner.imageDocument)
        expect(try snapshot(first.owner.imageDocument.image).content == moved.content, "Redo restores exact picked movement")

        let click = try scene("Pick without translation"); _ = try front(click.owner)
        let beforeClick = try snapshot(click.owner.imageDocument.image)
        try mouse(click.owner, .leftMouseDown, opaque); try selected(click.owner, click.top)
        try mouse(click.owner, .leftMouseUp, opaque); try drain(click.owner.imageDocument)
        let clickRef = try image(); try session.selectLayer(clickRef.2, image: clickRef.0)
        let afterClick = try snapshot(click.owner.imageDocument.image)
        expect(try snapshot(click.owner.imageDocument.image, normalized: true).content == snapshot(clickRef.0, normalized: true).content
                && afterClick.undo == beforeClick.undo && afterClick.history == beforeClick.history,
               "a no-drag click selects the literal hit without a movement Undo or pixel change")

        // Cancellation restores only a press selection still owned by this gesture.
        let cancel = try scene("Owned cancel restore"); _ = try front(cancel.owner)
        let beforeCancel = try snapshot(cancel.owner.imageDocument.image)
        try mouse(cancel.owner, .leftMouseDown, opaque); try selected(cancel.owner, cancel.top)
        try key(cancel.owner, code: 53, characters: "\u{1b}"); try drain(cancel.owner.imageDocument)
        expect(try snapshot(cancel.owner.imageDocument.image) == beforeCancel, "Escape restores the owned pre-press selection with no pixel/history change")
        try mouse(cancel.owner, .leftMouseUp, end(opaque, delta)); try drain(cancel.owner.imageDocument)
        expect(try snapshot(cancel.owner.imageDocument.image) == beforeCancel, "a late release after cancel never falls back to ordinary movement")

        // Two real queue holds expose select-admitted / native-ack-pending cancellation.
        for superseded in [false, true] {
            let pending = try scene(superseded ? "Superseded cancel ack" : "Owned cancel ack")
            var laterTarget: Int32?
            var explicitPick: MovePickSnapshot?
            if superseded {
                guard let third = try session.layerCommand(.new, image: pending.owner.imageDocument.image) else {
                    throw NSError(domain: "MovePickFixture", code: 14)
                }
                laterTarget = third
                try session.selectLayer(third, image: pending.owner.imageDocument.image)
                explicitPick = try snapshot(pending.owner.imageDocument.image)
                try session.selectLayer(pending.bottom, image: pending.owner.imageDocument.image)
                try pending.owner.imageDocument.reload()
                try drain(pending.owner.imageDocument)
            }
            _ = try front(pending.owner)
            let original = try snapshot(pending.owner.imageDocument.image)
            let queryHold = try hold(pending.owner.imageDocument)
            try mouse(pending.owner, .leftMouseDown, opaque)
            let ackHold = enqueueHold(pending.owner.imageDocument)
            queryHold.release.signal(); try started(ackHold)
            try require(wait { pending.owner.imageDocument.activeLayer == pending.top }, "the picked target was not admitted while native ack was held")
            expect(try session.selectedLayers(pending.owner.imageDocument.image) == [pending.bottom], "the selection ack hold is real, not a fake query result")
            try key(pending.owner, code: 53, characters: "\u{1b}")
            if let laterTarget { pending.owner.imageDocument.selectLayer(laterTarget) }
            ackHold.release.signal(); try drain(pending.owner.imageDocument)
            let expected = explicitPick ?? original
            expect(try snapshot(pending.owner.imageDocument.image) == expected,
                   "\(superseded ? "later explicit pick wins over" : "owned cancellation restores after") a delayed selection ack")
            try mouse(pending.owner, .leftMouseUp, end(opaque, delta)); try drain(pending.owner.imageDocument)
            expect(try snapshot(pending.owner.imageDocument.image) == expected, "ack cleanup cannot resurrect a cancelled move")
        }
        let superseded = try scene("Explicit different target"); _ = try front(superseded.owner)
        try mouse(superseded.owner, .leftMouseDown, opaque); try selected(superseded.owner, superseded.top)
        let third = try session.layerCommand(.new, image: superseded.owner.imageDocument.image)
        guard let third else { throw NSError(domain: "MovePickFixture", code: 10) }
        try superseded.owner.imageDocument.reload()
        superseded.owner.imageDocument.selectLayer(third); try drain(superseded.owner.imageDocument)
        let userPick = try snapshot(superseded.owner.imageDocument.image)
        try key(superseded.owner, code: 53, characters: "\u{1b}")
        try mouse(superseded.owner, .leftMouseUp, end(opaque, delta)); try drain(superseded.owner.imageDocument)
        expect(try snapshot(superseded.owner.imageDocument.image) == userPick && session.selectedLayers(superseded.owner.imageDocument.image) == [third],
               "conditional cancel restoration never overwrites a newer explicit target")

        // Float hit, hole-other Anchor and miss all use press opacity, not bounds/release.
        let floatMove = try scene("Opaque float move", floating: true); _ = try front(floatMove.owner)
        let beforeFloatMove = try snapshot(floatMove.owner.imageDocument.image)
        try mouse(floatMove.owner, .leftMouseDown, opaque); try drain(floatMove.owner.imageDocument)
        try mouse(floatMove.owner, .leftMouseDragged, end(opaque, delta))
        expect(try snapshot(floatMove.owner.imageDocument.image) == beforeFloatMove, "opaque float picking and drag add no native edit before release")
        try mouse(floatMove.owner, .leftMouseUp, end(opaque, delta)); try drain(floatMove.owner.imageDocument)
        let floatRef = try image(floating: true); try session.moveLayer(floatRef.2, image: floatRef.0, by: delta)
        expect(try snapshot(floatMove.owner.imageDocument.image, normalized: true).content == snapshot(floatRef.0, normalized: true).content,
               "an opaque float hit moves the original unresolved float, never anchors")
        expect(try session.undoInfo(floatMove.owner.imageDocument.image).undoCount == beforeFloatMove.undo.undoCount + 1,
               "captured opaque float translation has exactly one Undo")
        for press in [hole, CGPoint(x: 60, y: 40)] {
            let anchor = try scene("Other-hit anchor", floating: true); _ = try front(anchor.owner)
            let before = try snapshot(anchor.owner.imageDocument.image)
            try mouse(anchor.owner, .leftMouseDown, press); try drain(anchor.owner.imageDocument)
            expect(try snapshot(anchor.owner.imageDocument.image) == before, "hole/other hit arms Anchor without selecting the unrelated hit")
            try mouse(anchor.owner, .leftMouseDragged, opaque)
            try mouse(anchor.owner, .leftMouseUp, opaque); try drain(anchor.owner.imageDocument)
            let direct = try image(floating: true)
            _ = try session.floatingCommand(.anchor, image: direct.0, expected: direct.2)
            let actual = try snapshot(anchor.owner.imageDocument.image)
            expect(try snapshot(anchor.owner.imageDocument.image, normalized: true).content == snapshot(direct.0, normalized: true).content,
                   "press-time other hit anchors like direct native Anchor regardless of release position")
            expect(actual.content.floating.isActive == false && actual.content.selected == [anchor.bottom]
                    && actual.undo.undoCount == before.undo.undoCount + 1,
                   "Anchor is one Undo and reactivates its attachment, not another picked layer")
            anchor.owner.imageDocument.undo(); try drain(anchor.owner.imageDocument)
            expect(try snapshot(anchor.owner.imageDocument.image).content == before.content, "Anchor Undo restores original float, attachment, selection and bytes")
            anchor.owner.imageDocument.redo(); try drain(anchor.owner.imageDocument)
            expect(try snapshot(anchor.owner.imageDocument.image).content == actual.content, "Anchor Redo restores the exact native result")
        }
        for floating in [false, true] {
            let empty = try scene(floating ? "Floating miss" : "Inactive miss", floating: floating); _ = try front(empty.owner)
            let before = try snapshot(empty.owner.imageDocument.image)
            try mouse(empty.owner, .leftMouseDown, miss)
            try mouse(empty.owner, .leftMouseDragged, opaque); try mouse(empty.owner, .leftMouseUp, opaque)
            try drain(empty.owner.imageDocument)
            expect(try snapshot(empty.owner.imageDocument.image) == before, "a \(floating ? "floating" : "nonfloating") native miss stays a no-op even when release hits content")
        }

        // The reviewed native167 profiles deliberately differ for alpha1/255.
        guard let tinyHitsFloat = ["3.2.8": false, "3.2.0": false, "3.0.8": false, "3.3.1": true][session.version] else {
            throw NSError(domain: "MovePickFixture", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unreviewed native opacity-pick profile: \(session.version)"])
        }
        let tiny = try scene("Native threshold profile", floating: true); _ = try front(tiny.owner)
        let tinyRef = try image(floating: true)
        let tinyStart = CGPoint(x: 25, y: 25)
        try mouse(tiny.owner, .leftMouseDown, tinyStart)
        try mouse(tiny.owner, .leftMouseDragged, end(tinyStart, delta))
        try mouse(tiny.owner, .leftMouseUp, end(tinyStart, delta)); try drain(tiny.owner.imageDocument)
        if tinyHitsFloat { try session.moveLayer(tinyRef.2, image: tinyRef.0, by: delta) }
        else { _ = try session.floatingCommand(.anchor, image: tinyRef.0, expected: tinyRef.2) }
        expect(try snapshot(tiny.owner.imageDocument.image, normalized: true).content == snapshot(tinyRef.0, normalized: true).content,
               "alpha1/255 follows this reviewed engine's native threshold, not a frontend constant")

        // Delayed query: retain drag/release, honour cancel/replacement, keep main actor live.
        let delayed = try scene("Release before query"); _ = try front(delayed.owner)
        let delayedHold = try hold(delayed.owner.imageDocument)
        let delayedBefore = try snapshot(delayed.owner.imageDocument.image)
        try mouse(delayed.owner, .leftMouseDown, opaque)
        expect(!delayedHold.expired && delayed.owner.imageDocument.pendingWork > 0, "press queues the real opacity read without blocking main or dirty input")
        let tick = DispatchSemaphore(value: 0)
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in tick.signal() }
        expect(wait {
            while tick.wait(timeout: .now()) == .success { ticks += 1 }
            return ticks >= 2
        }, "AppKit timers run while the real query is held")
        timer.invalidate()
        try mouse(delayed.owner, .leftMouseDragged, end(opaque, delta)); try mouse(delayed.owner, .leftMouseUp, end(opaque, delta))
        expect(try snapshot(delayed.owner.imageDocument.image) == delayedBefore, "release buffered before query adds no premature move or selection")
        delayedHold.release.signal(); try drain(delayed.owner.imageDocument)
        let delayedRef = try image(); try reference(delayedRef, moving: delayedRef.2, by: delta)
        expect(try snapshot(delayed.owner.imageDocument.image, normalized: true).content == snapshot(delayedRef.0, normalized: true).content,
               "a valid late query submits exactly the captured release action")
        expect(try session.undoInfo(delayed.owner.imageDocument.image).undoCount == delayedBefore.undo.undoCount + 1,
               "the buffered release is committed once")
        let lateCancel = try scene("Cancel before query"); _ = try front(lateCancel.owner)
        let cancelHold = try hold(lateCancel.owner.imageDocument)
        let beforeLateCancel = try snapshot(lateCancel.owner.imageDocument.image)
        try mouse(lateCancel.owner, .leftMouseDown, opaque)
        try key(lateCancel.owner, code: 53, characters: "\u{1b}")
        try mouse(lateCancel.owner, .leftMouseUp, end(opaque, delta))
        cancelHold.release.signal(); try drain(lateCancel.owner.imageDocument)
        expect(try snapshot(lateCancel.owner.imageDocument.image) == beforeLateCancel, "a query arriving after cancel cannot select, move, anchor or fall back")
        let replaced = try scene("Replaced pending press"); _ = try front(replaced.owner)
        let replaceHold = try hold(replaced.owner.imageDocument)
        let beforeReplacement = try snapshot(replaced.owner.imageDocument.image)
        try mouse(replaced.owner, .leftMouseDown, opaque)
        try mouse(replaced.owner, .leftMouseDown, miss); try mouse(replaced.owner, .leftMouseUp, opaque)
        replaceHold.release.signal(); try drain(replaced.owner.imageDocument)
        expect(try snapshot(replaced.owner.imageDocument.image) == beforeReplacement,
               "a replaced request's late reply cannot override the newer missed press")

        // Captured A routing while B already owns key/main; actual focus loss cancels separately.
        let a = try scene("Captured A"), b = try scene("B already front")
        let windowB = try front(b.owner), beforeB = try snapshot(b.owner.imageDocument.image)
        let aHold = try hold(a.owner.imageDocument)
        try mouse(a.owner, .leftMouseDown, opaque); try mouse(a.owner, .leftMouseUp, end(opaque, delta))
        aHold.release.signal(); try drain(a.owner.imageDocument)
        let abRef = try image(); try reference(abRef, moving: abRef.2, by: delta)
        expect(NSApp.keyWindow === windowB && NSApp.mainWindow === windowB, "B genuinely stays front during A-owned routing")
        expect(try snapshot(a.owner.imageDocument.image, normalized: true).content == snapshot(abRef.0, normalized: true).content,
               "captured source A receives its move while B is front")
        expect(try snapshot(b.owner.imageDocument.image) == beforeB, "the entire B image/selection/history is untouched")
        let focus = try scene("Focus cancel"); _ = try front(focus.owner)
        let beforeFocus = try snapshot(focus.owner.imageDocument.image)
        try mouse(focus.owner, .leftMouseDown, opaque); try selected(focus.owner, focus.top)
        _ = try front(b.owner)
        try drain(focus.owner.imageDocument)
        expect(try snapshot(focus.owner.imageDocument.image) == beforeFocus, "actual key-window loss cancels and restores only the owned press selection")
        try mouse(focus.owner, .leftMouseUp, end(opaque, delta)); try drain(focus.owner.imageDocument)
        expect(try snapshot(focus.owner.imageDocument.image) == beforeFocus, "release after actual focus cancel remains inert")

        // Guide ownership beats an otherwise actionable other-layer floating pick.
        let guided = try scene("Guide wins", floating: true)
        let guide = try session.putGuide(.init(id: 0, orientation: .vertical, position: 60), image: guided.owner.imageDocument.image)
        try guided.owner.imageDocument.reload(); _ = try front(guided.owner)
        let guideBefore = try snapshot(guided.owner.imageDocument.image)
        try mouse(guided.owner, .leftMouseDown, CGPoint(x: 60, y: 50))
        try mouse(guided.owner, .leftMouseDragged, CGPoint(x: 67, y: 50)); try mouse(guided.owner, .leftMouseUp, CGPoint(x: 67, y: 50))
        try drain(guided.owner.imageDocument)
        let guideAfter = try snapshot(guided.owner.imageDocument.image)
        expect(guideAfter.content.floating == guideBefore.content.floating && guideAfter.content.drawables == guideBefore.content.drawables
                && guideAfter.content.composite == guideBefore.content.composite && guideAfter.content.selected == guideBefore.content.selected,
               "a guide drag never resolves or translates the float beneath its press")
        expect(try session.guides(guided.owner.imageDocument.image).contains { $0.id == guide && $0.position == 67 }
                && guideAfter.undo.undoCount == guideBefore.undo.undoCount + 1, "only the guide moves as one Undo")

        // Public replacements/stale attachment expectations must not retarget a late query.
        let stale = try scene("Replacement float", floating: true); _ = try front(stale.owner)
        let staleHold = try hold(stale.owner.imageDocument)
        try mouse(stale.owner, .leftMouseDown, hole); try mouse(stale.owner, .leftMouseUp, opaque)
        _ = try session.floatingCommand(.discard, image: stale.owner.imageDocument.image, expected: stale.top)
        let replacement = try session.pasteInto(stale.owner.imageDocument.image, target: stale.bottom, pixels: payload)
        let afterIntervention = try snapshot(stale.owner.imageDocument.image)
        staleHold.release.signal(); try drain(stale.owner.imageDocument)
        expect(try snapshot(stale.owner.imageDocument.image) == afterIntervention
                && session.floatingSelection(stale.owner.imageDocument.image).floating == replacement,
               "late other-hit query never anchors a replaced float or another current target")

        // Current and temporary Command Move preserve ordinary modifiers and groups.
        try selectMode("Current Layer")
        let shifted = try scene("Current Shift diagonal"); _ = try front(shifted.owner)
        try mouse(shifted.owner, .leftMouseDown, opaque, flags: [.shift])
        try mouse(shifted.owner, .leftMouseUp, end(opaque, delta), flags: [.shift]); try drain(shifted.owner.imageDocument)
        let shiftedRef = try image(); try reference(shiftedRef, moving: shiftedRef.1, by: delta)
        expect(try snapshot(shifted.owner.imageDocument.image, normalized: true).content == snapshot(shiftedRef.0, normalized: true).content,
               "Current mode and ordinary Shift drag keep the existing diagonal selected-layer movement")
        try selectMode("Pick Layer or Guide")
        for variant in 0..<3 {
            let command = try scene("Command override \(variant)", floating: true); _ = try front(command.owner)
            ToolState.shared.select(variant == 0 ? .paintbrush : .move)
            // Paint Options may accept resource reads when the tool changes.
            // Wait for those real reads before testing pointer admission.
            try drain(first.owner.imageDocument); try drain(command.owner.imageDocument)
            if variant == 2 { try key(command.owner, code: 55, characters: "") }
            let flags: NSEvent.ModifierFlags = variant == 2 ? [] : [.command]
            try mouse(command.owner, .leftMouseDown, CGPoint(x: 60, y: 40), flags: flags)
            expect(command.owner.imageDocument.pendingWork == 0, "temporary/selected/held Command uses Current without even queuing a pick")
            try mouse(command.owner, .leftMouseDragged, CGPoint(x: 67, y: 44), flags: flags)
            try mouse(command.owner, .leftMouseUp, CGPoint(x: 67, y: 44), flags: flags)
            if variant == 2 { try key(command.owner, down: false, code: 55, characters: "") }
            try drain(command.owner.imageDocument)
            let commandRef = try image(floating: true); try session.moveLayer(commandRef.2, image: commandRef.0, by: delta)
            expect(try snapshot(command.owner.imageDocument.image, normalized: true).content == snapshot(commandRef.0, normalized: true).content,
                   "Command remains Current for paint, selected Move and held-key-only representations")
        }
        ToolState.shared.select(.move)
        let space = try scene("Space beats Command", floating: true); _ = try front(space.owner)
        let beforeSpace = try snapshot(space.owner.imageDocument.image)
        try key(space.owner, code: 49, characters: " ")
        try mouse(space.owner, .leftMouseDown, hole, flags: [.command]); try mouse(space.owner, .leftMouseUp, end(hole, delta), flags: [.command])
        try key(space.owner, down: false, code: 49, characters: " "); try drain(space.owner.imageDocument)
        expect(try snapshot(space.owner.imageDocument.image) == beforeSpace, "Space still takes Hand ahead of Command and Pick, with no native edit")
        let snap = try scene("Picked layer canvas snap"); _ = try front(snap.owner)
        snap.owner.zoom(to: 400)
        snap.owner.window?.contentView?.layoutSubtreeIfNeeded()
        let snapTolerance = CanvasSnapPlanner.defaultViewPointTolerance / snap.owner.canvas.scale
        try require(snapTolerance >= 2 && snapTolerance < 12,
                    "snap fixture must admit the 2px horizontal correction and exclude the 12px vertical candidate")
        snap.owner.canvas.snapTo.canvas = true
        try mouse(snap.owner, .leftMouseDown, opaque); try selected(snap.owner, snap.top)
        try mouse(snap.owner, .leftMouseDragged, CGPoint(x: 4, y: 26)); try mouse(snap.owner, .leftMouseUp, CGPoint(x: 4, y: 26))
        try drain(snap.owner.imageDocument)
        let snapRef = try image(); try reference(snapRef, moving: snapRef.2, by: CGSize(width: -24, height: 0))
        expect(try snapshot(snap.owner.imageDocument.image, normalized: true).content == snapshot(snapRef.0, normalized: true).content,
               "existing canvas-edge snapping applies to the captured picked layer")

        let grouped = try scene("Native child pick", grouped: true); _ = try front(grouped.owner)
        try mouse(grouped.owner, .leftMouseDown, opaque); try selected(grouped.owner, grouped.top)
        expect(grouped.owner.imageDocument.activeLayer == grouped.top, "authentic populated-group picking selects its content child, not an invented group hit")
        try key(grouped.owner, code: 53, characters: "\u{1b}"); try drain(grouped.owner.imageDocument)
        guard let group = grouped.group else { throw NSError(domain: "MovePickFixture", code: 12) }
        try session.setLayerLocks(group, image: grouped.owner.imageDocument.image, mask: [.position], values: [.position])
        try grouped.owner.imageDocument.reload()
        var lockErrors: [String] = []
        let originalError = grouped.owner.imageDocument.onError
        grouped.owner.imageDocument.onError = { message in originalError?(message); lockErrors.append(message) }
        try mouse(grouped.owner, .leftMouseDown, opaque); try selected(grouped.owner, grouped.top)
        let lockedPress = try snapshot(grouped.owner.imageDocument.image)
        try mouse(grouped.owner, .leftMouseUp, end(opaque, delta)); try drain(grouped.owner.imageDocument)
        expect(try snapshot(grouped.owner.imageDocument.image) == lockedPress && !lockErrors.isEmpty,
               "native inherited position lock refuses translation while preserving the authentic picked target")
        try session.setLayerLocks(group, image: grouped.owner.imageDocument.image, mask: [.position], values: [])
        try grouped.owner.imageDocument.reload()
        try selectMode("Current Layer")
        grouped.owner.imageDocument.selectLayer(group); try drain(grouped.owner.imageDocument)
        _ = try front(grouped.owner)
        try mouse(grouped.owner, .leftMouseDown, miss); try mouse(grouped.owner, .leftMouseUp, end(miss, delta)); try drain(grouped.owner.imageDocument)
        let groupRef = try image(grouped: true)
        guard let refGroup = groupRef.3 else { throw NSError(domain: "MovePickFixture", code: 13) }
        try reference(groupRef, moving: refGroup, by: delta)
        expect(try snapshot(grouped.owner.imageDocument.image, normalized: true).content == snapshot(groupRef.0, normalized: true).content,
               "existing Current mode translates a whole group exactly like native movement")
        try session.setLayerLocks(grouped.top, image: grouped.owner.imageDocument.image, mask: [.position], values: [.position])
        try grouped.owner.imageDocument.reload(); let beforeGroupLock = try snapshot(grouped.owner.imageDocument.image)
        lockErrors.removeAll()
        try mouse(grouped.owner, .leftMouseDown, miss); try mouse(grouped.owner, .leftMouseUp, end(miss, delta)); try drain(grouped.owner.imageDocument)
        expect(try snapshot(grouped.owner.imageDocument.image) == beforeGroupLock && !lockErrors.isEmpty,
               "a position-locked descendant prevents Current-mode group translation")
        grouped.owner.imageDocument.onError = originalError
        try selectMode("Pick Layer or Guide")

        // Close while a counted read is waiting: no late selection/Anchor can enter.
        let closing = try scene("Close during pick", floating: true); _ = try front(closing.owner)
        let closeHold = try hold(closing.owner.imageDocument)
        try mouse(closing.owner, .leftMouseDown, hole); try mouse(closing.owner, .leftMouseUp, opaque)
        expect(closing.owner.imageDocument.pendingWork > 0, "an accepted opacity query is counted before close")
        closing.owner.window?.close()
        expect(closing.owner.imageDocument.isClosing && !gone(closing.owner.imageDocument.image), "actual close waits for the accepted query while stopping new admission")
        closeHold.release.signal()
        expect(wait { gone(closing.owner.imageDocument.image) && closing.owner.imageDocument.pendingWork == 0 }, "the read drains and native image closes without late mutation")
        try mouse(closing.owner, .leftMouseUp, end(hole, delta))
        expect(closing.owner.imageDocument.pendingWork == 0 && gone(closing.owner.imageDocument.image), "a stale release after close cannot restart selection or Anchor")
        _ = work
    }
}
