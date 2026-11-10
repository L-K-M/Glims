import AppKit

private struct SelectionAnchorContent: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let floating: EngineSession.FloatingState
    let locks: [EngineSession.LayerLockState]
    let composite: Data
    let drawables: [Data]
    let coverage: Data
}

private struct SelectionAnchorSnapshot: Equatable {
    let content: SelectionAnchorContent
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

private final class SelectionAnchorQueueHold: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false

    var expired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func block() {
        ready.signal()
        if release.wait(timeout: .now() + 30) == .timedOut {
            lock.lock()
            timedOut = true
            lock.unlock()
        }
    }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseSelectionAnchor(_ session: EngineSession, documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1
            check(value, "Selection anchor: \(message)")
        }
        func fixtureError(_ message: String) -> NSError {
            NSError(domain: "SelectionAnchorFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw fixtureError(message) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                if condition() { return true }
                EngineSmokeTestHost.pumpEvents()
            } while Date() < deadline
            return condition()
        }
        func drain(_ owner: DocumentWindowController) throws {
            try require(wait { owner.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy },
                        "accepted selection work did not drain")
        }

        var owners: [DocumentWindowController] = []
        var referenceImages: [Int32] = []
        var holds: [SelectionAnchorQueueHold] = []
        let priorTool = ToolState.shared.current
        let priorOptions = ToolState.shared.selectOptions
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            holds.forEach { $0.release.signal() }
            for owner in owners where !owner.imageDocument.isClosing { owner.window?.close() }
            expect(wait { owners.allSatisfy { gone($0.imageDocument.image) && $0.imageDocument.pendingWork == 0 } },
                   "every owned image and its accepted work drain")
            for image in referenceImages { try? session.closeImage(image) }
            expect(referenceImages.allSatisfy { gone($0) }, "every independent reference image closes")
            expect(owners.allSatisfy { $0.window?.isVisible != true && $0.window?.attachedSheet == nil },
                   "no owned document window or dialog remains")
            expect(holds.allSatisfy { !$0.expired }, "no queue hold timed out")
            documents.items.removeAll { doc in owners.contains { $0.imageDocument === doc } }
            ToolState.shared.selectOptions = priorOptions
            ToolState.shared.select(priorTool)
            print("     selection-anchor checks: \(count)")
        }

        func hold(_ owner: DocumentWindowController) throws -> SelectionAnchorQueueHold {
            try drain(owner)
            let hold = SelectionAnchorQueueHold()
            holds.append(hold)
            owner.imageDocument.inputQueue.async { hold.block() }
            var started = false
            try require(wait {
                if !started { started = hold.ready.wait(timeout: .now()) == .success }
                return started
            }, "selection input queue hold did not start")
            return hold
        }
        func bytes(_ image: CGImage?, width: Int, height: Int) throws -> Data {
            guard let image, image.width == width, image.height == height,
                  let data = image.dataProvider?.data as Data? else {
                throw fixtureError("missing full-resolution native pixel buffer")
            }
            return data
        }
        func snapshot(_ image: Int32, normalized: Bool = false) throws -> SelectionAnchorSnapshot {
            let info = try session.info(image)
            let rows = try session.layers(image)
            let ids = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, Int32($0.offset + 1)) })
            func id(_ value: Int32) -> Int32 { normalized && value != 0 ? (ids[value] ?? -1) : value }
            let layers = rows.map {
                EngineSession.Layer(id: id($0.id), parent: id($0.parent), depth: $0.depth, kind: $0.kind,
                    name: $0.name, mode: $0.mode, isVisible: $0.isVisible, hasMask: $0.hasMask,
                    isSelected: $0.isSelected, opacity: $0.opacity, bounds: $0.bounds,
                    filterCount: $0.filterCount)
            }
            let floating = try session.floatingSelection(image)
            let undo = try session.undoInfo(image)
            let history = try session.history(image)
            let probe = try session.duplicateImage(image)
            defer { try? session.closeImage(probe) }
            // Only the disposable duplicate receives the saved channel.
            let channel = try session.channelFromSelection(probe, name: "Selection anchor coverage")
            let coverage = try bytes(session.drawableThumbnail(channel, image: probe, maxSize: 256),
                                     width: info.width, height: info.height)
            try require(try session.undoInfo(image) == undo && session.history(image) == history,
                        "selection mask probe changed the original history")
            let drawables = try rows.map {
                try bytes(session.drawableThumbnail($0.id, image: image, maxSize: 256),
                          width: Int($0.bounds.width), height: Int($0.bounds.height))
            }
            let composite = try bytes(session.render(image, scale: 1,
                area: CGRect(x: 0, y: 0, width: info.width, height: info.height)),
                width: info.width, height: info.height)
            return .init(content: .init(info: info, layers: layers,
                selected: try session.selectedLayers(image).map { id($0) },
                floating: .init(floating: id(floating.floating), target: id(floating.target), targetKind: floating.targetKind),
                locks: try rows.map { try session.layerState($0.id, image: image) },
                composite: composite, drawables: drawables, coverage: coverage), undo: undo, history: history)
        }

        let width = 96, height = 72
        var baseBytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                baseBytes.append(UInt8((x * 7 + y * 11) % 256))
                baseBytes.append(UInt8((x * 17 + y * 3) % 256))
                baseBytes.append(UInt8((x + y * 23 + 19) % 256))
                baseBytes.append((76..<86).contains(x) && (56..<66).contains(y) ? 0 : 255)
            }
        }
        var payloadBytes: [UInt8] = []
        for y in 0..<12 {
            for x in 0..<12 {
                payloadBytes.append(UInt8(160 + (x * 3 + y * 5) % 96))
                payloadBytes.append(UInt8((x * 13 + y * 7) % 150))
                payloadBytes.append(UInt8(20 + (x * 5 + y * 11) % 160))
                payloadBytes.append((5...7).contains(x) && (5...7).contains(y) ? 0 : 255)
            }
        }
        let base = ClipboardImage(width: width, height: height, pixels: Data(baseBytes), origin: .zero)
        let payload = ClipboardImage(width: 12, height: 12, pixels: Data(payloadBytes), origin: .zero)
        let initialSelection = CGRect(x: 18, y: 18, width: 24, height: 24)
        var options = EngineSession.SelectOptions()
        options.antialias = false
        ToolState.shared.selectOptions = options

        typealias Native = (image: Int32, target: Int32, float: Int32)
        typealias Scene = (owner: DocumentWindowController, native: Native)
        func seed(floating: Bool = true, emptyMask: Bool = false) throws -> Native {
            let image = try session.newImage(pixels: base)
            referenceImages.append(image)
            guard let target = try session.layers(image).first?.id else {
                throw fixtureError("native fixture has no target")
            }
            try session.select(.rectangle(initialSelection), image: image, options: options)
            var float: Int32 = 0
            if floating {
                float = try session.pasteInto(image, target: target, pixels: payload)
                // Paste Into centers the 12px payload in the literal 24px mask.
                try require(try session.layers(image).first(where: { $0.id == float })?.bounds
                                == CGRect(x: 24, y: 24, width: 12, height: 12),
                            "native floating bounds do not match literal opacity points")
                try require(try session.floatingSelection(image)
                                == .init(floating: float, target: target, targetKind: .layer),
                            "native floating attachment was not seeded")
            }
            if emptyMask { try session.select(.none, image: image) }
            try require(try (session.selectionBounds(image: image) == nil) == emptyMask,
                        "native selection-mask precondition differs")
            return (image, target, float)
        }
        func scene(_ name: String, floating: Bool = true, emptyMask: Bool = false,
                   observeEvents: Bool = true) throws -> Scene {
            let native = try seed(floating: floating, emptyMask: emptyMask)
            let document = try ImageDocument(session: session, image: native.image, name: name)
            let owner = DocumentWindowController(document: document)
            owners.append(owner)
            referenceImages.removeAll { $0 == native.image }
            if observeEvents { documents.items.append(document) }
            owner.showWindow(nil)
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            try drain(owner)
            return (owner, native)
        }
        func retire(_ scene: Scene) throws {
            scene.owner.window?.close()
            try require(wait { gone(scene.native.image) && scene.owner.imageDocument.pendingWork == 0 },
                        "completed selection fixture window did not drain")
        }
        @discardableResult
        func front(_ owner: DocumentWindowController) throws -> NSWindow {
            guard let window = owner.window else { throw fixtureError("owned window is missing") }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            try require(wait { NSApp.keyWindow === window && NSApp.mainWindow === window },
                        "actual key and main window did not settle")
            return window
        }
        let clickInterval = NSEvent.doubleClickInterval
        try require(clickInterval.isFinite && clickInterval > 0, "AppKit click interval is unavailable")
        let start: TimeInterval = 100
        let short = min(0.04, clickInterval / 2)
        let long = clickInterval + 0.5
        @discardableResult
        func pointer(_ scene: Scene, _ type: NSEvent.EventType, _ point: CGPoint,
                     elapsed: TimeInterval = 0, flags: NSEvent.ModifierFlags = []) throws -> CGPoint {
            let canvas = scene.owner.canvas
            guard let window = scene.owner.window else { throw fixtureError("pointer window is missing") }
            let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                timestamp: start + elapsed, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw fixtureError("could not construct AppKit pointer event")
            }
            let delivered = canvas.imagePoint(for: event)
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: throw fixtureError("unexpected pointer event type")
            }
            return delivered
        }
        func escape(_ scene: Scene) throws {
            guard let window = scene.owner.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: start + short / 2, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                throw fixtureError("could not construct Escape event")
            }
            scene.owner.canvas.keyDown(with: event)
        }
        func click(_ scene: Scene, _ point: CGPoint, press: NSEvent.ModifierFlags = []) throws {
            try pointer(scene, .leftMouseDown, point, flags: press)
            try pointer(scene, .leftMouseUp, point, elapsed: short)
            try drain(scene.owner)
        }
        func matches(_ native: Native, _ reference: Native) throws -> Bool {
            try snapshot(native.image, normalized: true).content
                == snapshot(reference.image, normalized: true).content
        }
        func anchorReference() throws -> Native {
            let reference = try seed()
            try session.floatingCommand(.anchor, image: reference.image, expected: reference.float)
            return reference
        }

        let miss = CGPoint(x: 80, y: 60)
        let hole = CGPoint(x: 30, y: 30)
        let opaque = CGPoint(x: 26, y: 26)
        let movedPoint = CGPoint(x: 33, y: 30)
        expect(NSApp.isRunning, "actual AppKit host is running")
        let anchoredReference = try anchorReference()

        for tool in [ToolID.rectangleSelect, .ellipseSelect] {
            ToolState.shared.select(tool)
            let name = tool.name
            let point = tool == .rectangleSelect ? miss : hole
            let active = try scene("\(name) confirmed click")
            try front(active.owner)
            let before = try snapshot(active.native.image)
            try pointer(active, .leftMouseDown, point)
            try drain(active.owner)
            expect(try snapshot(active.native.image) == before, "\(name) press and opacity read make no native edit")
            try pointer(active, .leftMouseUp, point, elapsed: short)
            try drain(active.owner)
            let after = try snapshot(active.native.image)
            expect(try matches(active.native, anchoredReference),
                   "\(name) short click at \(point == miss ? "empty image space" : "transparent float hole") matches direct native Anchor")
            expect(!after.content.floating.isActive && after.content.selected == [active.native.target]
                    && after.undo.undoCount == before.undo.undoCount + 1,
                   "\(name) resolves the original float, reselects its attachment and adds one Undo")
            active.owner.imageDocument.undo()
            try drain(active.owner)
            expect(try snapshot(active.native.image).content == before.content,
                   "\(name) Undo restores exact float, attachment and selection bytes")
            active.owner.imageDocument.redo()
            try drain(active.owner)
            expect(try snapshot(active.native.image).content == after.content,
                   "\(name) Redo restores the exact anchored result")

            try retire(active)

            let line = CGPoint(x: point.x + 7, y: point.y)
            let tiny = CGPoint(x: point.x + 0.125, y: point.y + 0.125)
            let nonClicks: [(String, CGPoint, CGPoint?, TimeInterval)] = [
                ("long still press", point, nil, long),
                ("one-axis line", line, line, short),
                ("tiny nonzero release", tiny, nil, short),
                ("delivered drag back to its start", point, line, short)
            ]
            for (description, end, drag, elapsed) in nonClicks {
                let inert = try scene("\(name) \(description)")
                try front(inert.owner)
                let original = try snapshot(inert.native.image)
                let deliveredDown = try pointer(inert, .leftMouseDown, point)
                if let drag { try pointer(inert, .leftMouseDragged, drag, elapsed: elapsed / 2) }
                let deliveredUp = try pointer(inert, .leftMouseUp, end, elapsed: elapsed)
                try drain(inert.owner)
                if end == tiny {
                    expect(deliveredUp != deliveredDown, "\(name) tiny release delivers a different image point")
                }
                expect(try snapshot(inert.native.image) == original,
                       "\(name) \(description) preserves float, mask and history")
                try retire(inert)
            }

            let cancelled = try scene("\(name) Escape cancellation")
            try front(cancelled.owner)
            let original = try snapshot(cancelled.native.image)
            try pointer(cancelled, .leftMouseDown, point)
            try escape(cancelled)
            try pointer(cancelled, .leftMouseUp, point, elapsed: short)
            try drain(cancelled.owner)
            expect(try snapshot(cancelled.native.image) == original,
                   "\(name) Escape and late release preserve all native state")
            try retire(cancelled)

            // An empty mask with configured Subtract must not prevent opaque MOVE.
            var subtract = options
            subtract.operation = .subtract
            ToolState.shared.selectOptions = subtract
            let moving = try scene("\(name) opaque movement", emptyMask: true)
            try front(moving.owner)
            let beforeMove = try snapshot(moving.native.image)
            try click(moving, opaque)
            expect(try snapshot(moving.native.image) == beforeMove, "\(name) opaque still click adds no Anchor or Move Undo")
            try pointer(moving, .leftMouseDown, opaque)
            try pointer(moving, .leftMouseDragged, movedPoint, elapsed: short / 2)
            expect(try snapshot(moving.native.image) == beforeMove, "\(name) opaque drag preview is view-only")
            try pointer(moving, .leftMouseUp, movedPoint, elapsed: short)
            try drain(moving.owner)
            let moved = try snapshot(moving.native.image)
            let moveRef = try seed(emptyMask: true)
            try session.moveLayer(moveRef.float, image: moveRef.image, by: CGSize(width: 7, height: 4))
            expect(try matches(moving.native, moveRef), "\(name) opaque handoff matches direct translation with an empty Subtract mask")
            expect(moved.content.floating == beforeMove.content.floating
                    && moved.undo.undoCount == beforeMove.undo.undoCount + 1,
                   "\(name) translation keeps its original attachment and adds one Undo")
            moving.owner.imageDocument.undo()
            try drain(moving.owner)
            expect(try snapshot(moving.native.image).content == beforeMove.content, "\(name) movement Undo restores exact pixels and bounds")
            moving.owner.imageDocument.redo()
            try drain(moving.owner)
            expect(try snapshot(moving.native.image).content == moved.content, "\(name) movement Redo restores exact translated pixels")

            try retire(moving)

            ToolState.shared.selectOptions = options
            let modified = try scene("\(name) modified Anchor")
            try front(modified.owner)
            try click(modified, opaque, press: tool == .rectangleSelect ? .shift : .option)
            expect(try matches(modified.native, anchoredReference),
                   "\(name) physical modifier at press suppresses opaque MOVE and permits short Anchor")
            try retire(modified)
        }

        // Literal bounds and combiner use independent native shape calls.
        let shapeCases: [(ToolID, CGPoint, CGPoint, NSEvent.ModifierFlags, NSEvent.ModifierFlags,
                          EngineSession.SelectOperation, CGRect)] = [
            (.rectangleSelect, .init(x: 50, y: 40), .init(x: 61, y: 45), .shift, [], .add,
                .init(x: 50, y: 40, width: 11, height: 5)),
            (.ellipseSelect, .init(x: 45, y: 45), .init(x: 53, y: 45), [], .shift, .replace,
                .init(x: 45, y: 45, width: 8, height: 8)),
            (.rectangleSelect, .init(x: 50, y: 44), .init(x: 56, y: 48), [], .option, .replace,
                .init(x: 44, y: 40, width: 12, height: 8)),
            (.rectangleSelect, .init(x: 34, y: 32), .init(x: 39, y: 35), [.shift, .option], [], .intersect,
                .init(x: 34, y: 32, width: 5, height: 3))
        ]
        for (tool, from, to, press, release, operation, bounds) in shapeCases {
            ToolState.shared.select(tool)
            let shaped = try scene("Captured \(operation) with live geometry")
            try front(shaped.owner)
            let before = try snapshot(shaped.native.image)
            try pointer(shaped, .leftMouseDown, from, flags: press)
            try pointer(shaped, .leftMouseDragged, to, elapsed: short / 2, flags: release)
            try pointer(shaped, .leftMouseUp, to, elapsed: short, flags: release)
            try drain(shaped.owner)
            let reference = try seed()
            var nativeOptions = options
            nativeOptions.operation = operation
            try session.select(tool == .ellipseSelect ? .ellipse(bounds) : .rectangle(bounds),
                               image: reference.image, options: nativeOptions)
            let after = try snapshot(shaped.native.image)
            expect(try matches(shaped.native, reference) && after.content.floating == before.content.floating
                    && after.content.coverage != before.content.coverage && after.undo.undoCount == before.undo.undoCount + 1,
                   "\(tool.name) captures \(operation) at press and applies live release geometry, preserving its float")
            try retire(shaped)
        }

        ToolState.shared.select(.rectangleSelect)
        let ordinary = try scene("No float", floating: false)
        try front(ordinary.owner)
        let plainRef = try seed(floating: false)
        try session.select(.none, image: plainRef.image)
        try click(ordinary, miss)
        expect(try matches(ordinary.native, plainRef), "ordinary short click still clears an existing selection")
        let ordinaryBounds = CGRect(x: 46, y: 40, width: 11, height: 7)
        try pointer(ordinary, .leftMouseDown, ordinaryBounds.origin)
        try pointer(ordinary, .leftMouseDragged, CGPoint(x: 57, y: 47), elapsed: short / 2)
        try pointer(ordinary, .leftMouseUp, CGPoint(x: 57, y: 47), elapsed: short)
        try drain(ordinary.owner)
        try session.select(.rectangle(ordinaryBounds), image: plainRef.image, options: options)
        expect(try matches(ordinary.native, plainRef), "ordinary no-float drag still matches a direct native rectangle")
        try retire(ordinary)

        // Deliberately exclude these owners from the fixture's native-event relay.
        // Their cached state stays stale after the direct native intervention.
        let empty = try scene("Fresh subtract mask", observeEvents: false)
        try front(empty.owner)
        try pointer(empty, .leftMouseDown, opaque, flags: .option)
        try drain(empty.owner)
        try session.select(.none, image: empty.native.image)
        expect(try session.selectionBounds(image: empty.native.image) == nil
                && empty.owner.imageDocument.selectionBounds != nil,
               "native mask is empty after press while the owning document still caches a mask")
        let afterClear = try snapshot(empty.native.image)
        try pointer(empty, .leftMouseUp, opaque, elapsed: short)
        try drain(empty.owner)
        expect(try snapshot(empty.native.image) == afterClear, "captured Subtract refuses fresh empty mask after Option release")
        try retire(empty)

        var intersect = options
        intersect.operation = .intersect
        ToolState.shared.selectOptions = intersect
        ToolState.shared.select(.ellipseSelect)
        let intersecting = try scene("Empty Intersect", emptyMask: true)
        try front(intersecting.owner)
        let beforeIntersect = try snapshot(intersecting.native.image)
        try click(intersecting, hole)
        expect(try snapshot(intersecting.native.image) == beforeIntersect, "configured Intersect refuses an empty mask at a float hole")
        try retire(intersecting)
        ToolState.shared.selectOptions = options

        let locked = try scene("Fresh selected floating lock", observeEvents: false)
        try front(locked.owner)
        let lockHold = try hold(locked.owner)
        try pointer(locked, .leftMouseDown, opaque)
        try session.setLayerLocks(locked.native.float, image: locked.native.image, mask: .pixels, values: .pixels)
        expect(try session.selectedLayers(locked.native.image) == [locked.native.float]
                && session.layerState(locked.native.float, image: locked.native.image).effective.contains(.pixels)
                && locked.owner.imageDocument.layerLocks[locked.native.float]?.effective.contains(.pixels) == false,
               "selected float has a fresh native pixel lock before the held read and cached locks stay stale")
        let afterLock = try snapshot(locked.native.image)
        try pointer(locked, .leftMouseDragged, movedPoint, elapsed: short / 2)
        try pointer(locked, .leftMouseUp, movedPoint, elapsed: short)
        lockHold.release.signal()
        try drain(locked.owner)
        expect(try snapshot(locked.native.image) == afterLock, "fresh selected-float pixel lock refuses opaque movement without history")
        try retire(locked)

        ToolState.shared.select(.rectangleSelect)
        let a = try scene("Captured selection document A")
        let b = try scene("Front selection document B")
        let frontB = try front(b.owner)
        let originalA = try snapshot(a.native.image)
        let originalB = try snapshot(b.native.image)
        let blocked = try hold(a.owner)
        try pointer(a, .leftMouseDown, miss)
        expect(a.owner.imageDocument.pendingWork > 0, "A press admits a counted opacity read on its blocked input queue")
        try pointer(a, .leftMouseUp, miss, elapsed: short)
        expect(try snapshot(a.native.image) == originalA && snapshot(b.native.image) == originalB,
               "buffered release before the native reply changes neither document")
        blocked.release.signal()
        try drain(a.owner)
        expect(try matches(a.native, anchoredReference), "buffered short release anchors only captured A while B is front")
        expect(try snapshot(b.native.image) == originalB && NSApp.keyWindow === frontB && NSApp.mainWindow === frontB,
               "B retains its exact native state and actual window focus")

        let losing = try scene("Focus cancellation")
        try front(losing.owner)
        let beforeFocusLoss = try snapshot(losing.native.image)
        let focusHold = try hold(losing.owner)
        try pointer(losing, .leftMouseDown, miss)
        try front(b.owner)
        try pointer(losing, .leftMouseUp, miss, elapsed: short)
        focusHold.release.signal()
        try drain(losing.owner)
        expect(try snapshot(losing.native.image) == beforeFocusLoss && snapshot(b.native.image) == originalB,
               "actual focus loss retires the held query and ignores the late release")

        for detach in [false, true] {
            let stale = try scene(detach ? "Detached float" : "Replaced float", observeEvents: false)
            try front(stale.owner)
            let held = try hold(stale.owner)
            try pointer(stale, .leftMouseDown, miss)
            try pointer(stale, .leftMouseUp, miss, elapsed: short)
            let originalID = stale.native.float
            try session.floatingCommand(detach ? .toLayer : .discard, image: stale.native.image, expected: originalID)
            if detach {
                try require(try session.layers(stale.native.image).contains { $0.id == originalID }
                                && !session.floatingSelection(stale.native.image).isActive,
                            "native detach did not retain the same id as an ordinary layer")
            } else {
                try session.select(.rectangle(initialSelection), image: stale.native.image, options: options)
                let replacement = try session.pasteInto(stale.native.image, target: stale.native.target, pixels: payload)
                try require(try replacement != originalID
                                && session.floatingSelection(stale.native.image)
                                    == .init(floating: replacement, target: stale.native.target, targetKind: .layer),
                            "native replacement did not produce a distinct float with the same attachment")
            }
            let intervened = try snapshot(stale.native.image)
            held.release.signal()
            try drain(stale.owner)
            expect(try snapshot(stale.native.image) == intervened,
                   "\(detach ? "Same-id detach" : "Replacement float") makes the pending gesture stale without a fallback edit")
            try retire(stale)
        }

        let closing = try scene("Close during selection opacity read")
        let closingWindow = try front(closing.owner)
        let closeHold = try hold(closing.owner)
        try pointer(closing, .leftMouseDown, miss)
        let pending = closing.owner.imageDocument.pendingWork
        closingWindow.close()
        expect(pending > 0 && closing.owner.imageDocument.isClosing
                && !closing.owner.imageDocument.acceptsEdits && !gone(closing.native.image),
               "actual window close stops edits while a counted selection read keeps its native image alive")
        try pointer(closing, .leftMouseUp, miss, elapsed: short)
        expect(closing.owner.imageDocument.pendingWork == pending,
               "late release during close admits no additional native work")
        closeHold.release.signal()
        expect(wait { gone(closing.native.image) && closing.owner.imageDocument.pendingWork == 0 },
               "closing image retires after the held read and deferred callbacks drain")
    }
}
