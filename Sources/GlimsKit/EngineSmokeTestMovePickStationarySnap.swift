import AppKit

private struct MovePickStationaryBuffer: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
}

private struct MovePickStationaryContent: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let drawables: [MovePickStationaryBuffer]
    let merged: MovePickStationaryBuffer
    let guides: [EngineSession.Guide]
}

private struct MovePickStationarySnapshot {
    let content: MovePickStationaryContent
    let selected: [Int32]
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

@MainActor
extension EngineSmokeTest {
    /// A stationary Pick press may change only the transient target. A
    /// separate, fresh drag proves the nearby guide still snaps motion.
    static func exerciseMovePickStationarySnap(_ session: EngineSession, work: URL,
                                              documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1; check(value, "Move Pick stationary snap: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MovePickStationarySnap", code: 1,
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
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        let state = ToolState.shared
        let priorTool = state.current, priorMode = state.moveTargetMode
        var owners: [DocumentWindowController] = []
        var loose: [Int32] = []
        defer {
            for owner in owners { owner.window?.close() }
            expect(wait { owners.allSatisfy { gone($0.imageDocument.image) && $0.imageDocument.pendingWork == 0 } },
                   "all owned windows, renderers and native images drain")
            for image in loose { try? session.closeImage(image) }
            expect(loose.allSatisfy { gone($0) }, "the independent native reference closes")
            expect(owners.allSatisfy { $0.window?.isVisible != true && $0.window?.attachedSheet == nil },
                   "no owned window or dialog remains")
            documents.items.removeAll { doc in owners.contains { $0.imageDocument === doc } }
            state.setMoveTargetMode(priorMode)
            state.select(priorTool)
            print("     move-pick-stationary-snap checks: \(count)")
        }
        func drain(_ owner: DocumentWindowController) throws {
            try require(wait { owner.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy
                && !owner.canvas.tools.hasPendingInteraction }, "accepted Pick input did not finish and drain")
        }
        func bytes(_ image: CGImage?) throws -> MovePickStationaryBuffer {
            guard let image, let pixels = image.dataProvider?.data as Data? else {
                throw NSError(domain: "MovePickStationarySnap", code: 2)
            }
            return .init(width: image.width, height: image.height, pixels: pixels)
        }
        func snapshot(_ image: Int32, normalized: Bool = false) throws -> MovePickStationarySnapshot {
            let info = try session.info(image), layers = try session.layers(image)
            let ids = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, Int32($0.offset + 1)) })
            func id(_ value: Int32) -> Int32 { normalized && value != 0 ? (ids[value] ?? -1) : value }
            let rows = layers.map {
                // Selection is checked separately, because a stationary
                // opacity hit intentionally replaces the selected layer.
                EngineSession.Layer(id: id($0.id), parent: id($0.parent), depth: $0.depth, kind: $0.kind,
                    name: $0.name, mode: $0.mode, isVisible: $0.isVisible, hasMask: $0.hasMask,
                    isSelected: false, opacity: $0.opacity, bounds: $0.bounds, filterCount: $0.filterCount)
            }
            var drawables: [MovePickStationaryBuffer] = []
            for row in layers {
                let raw = try bytes(session.drawableThumbnail(row.id, image: image, maxSize: 128))
                try require(row.kind == .pixel && row.filterCount == 0 && !row.hasMask
                    && raw.width == Int(row.bounds.width) && raw.height == Int(row.bounds.height),
                    "raw drawable reads must be full resolution with no filters or masks")
                drawables.append(raw)
            }
            let guides = try session.guides(image).enumerated().map {
                EngineSession.Guide(id: normalized ? Int32($0.offset + 1) : $0.element.id,
                                    orientation: $0.element.orientation, position: $0.element.position)
            }
            return .init(content: .init(info: info, layers: rows, drawables: drawables,
                merged: try bytes(session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 128, height: 96))),
                guides: guides), selected: try session.selectedLayers(image).map { id($0) },
                undo: try session.undoInfo(image), history: try session.history(image))
        }
        var baseBytes: [UInt8] = [], topBytes: [UInt8] = []
        for y in 0..<96 {
            for x in 0..<128 {
                baseBytes += [UInt8((x * 7 + y * 11) % 256), UInt8((x * 17 + y * 3) % 256),
                              UInt8((x + y * 23 + 19) % 256), 255]
            }
        }
        for y in 0..<40 {
            for x in 0..<40 {
                topBytes += [UInt8(160 + (x * 3 + y * 5) % 96), UInt8((x * 13 + y * 7) % 150),
                             UInt8(20 + (x * 5 + y * 11) % 160), 255]
            }
        }
        let base = ClipboardImage(width: 128, height: 96, pixels: Data(baseBytes), origin: .zero)
        let topPixels = ClipboardImage(width: 40, height: 40, pixels: Data(topBytes), origin: CGPoint(x: 24, y: 24))
        typealias NativeScene = (image: Int32, bottom: Int32, top: Int32, guide: Int32, file: URL)
        func seed(_ name: String) throws -> NativeScene {
            let image = try session.newImage(pixels: base)
            loose.append(image)
            guard let bottom = try session.layers(image).first?.id else {
                throw NSError(domain: "MovePickStationarySnap", code: 3)
            }
            let top = try session.pastePixels(image, pixels: topPixels, at: topPixels.origin)
            let guide = try session.putGuide(.init(id: 0, orientation: .vertical, position: 26), image: image)
            try session.selectLayer(bottom, image: image)
            let file = work.appendingPathComponent("move-pick-stationary-\(name).xcf")
            try session.save(image, to: file.path)
            try require(try session.layers(image).first(where: { $0.id == top })?.bounds
                == CGRect(x: 24, y: 24, width: 40, height: 40), "literal native top placement changed")
            return (image, bottom, top, guide, file)
        }
        func open(_ scene: NativeScene, name: String) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: scene.image, name: name, openedFrom: scene.file)
            let owner = DocumentWindowController(document: document)
            owners.append(owner); documents.items.append(document); loose.removeAll { $0 == scene.image }
            owner.showWindow(nil)
            owner.zoom(to: 100)
            guard let window = owner.window else { throw NSError(domain: "MovePickStationarySnap", code: 4) }
            window.contentView?.layoutSubtreeIfNeeded()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeMain()
            try require(window.makeFirstResponder(owner.canvas), "the actual canvas must accept focus")
            try require(wait { NSApp.keyWindow === window && NSApp.mainWindow === window }, "actual window focus did not settle")
            var snap = SnapToViewState(); snap.guides = true
            owner.canvas.snapTo = snap
            try drain(owner)
            try require(owner.canvas.scale == 1, "the fixture requires literal one-view-point image pixels")
            return owner
        }
        func mouse(_ owner: DocumentWindowController, _ type: NSEvent.EventType, _ point: CGPoint) throws {
            guard let window = owner.window else { throw NSError(domain: "MovePickStationarySnap", code: 5) }
            let location = owner.canvas.convert(CGPoint(x: point.x * owner.canvas.scale, y: point.y * owner.canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "MovePickStationarySnap", code: 6)
            }
            switch type {
            case .leftMouseDown: owner.canvas.mouseDown(with: event)
            case .leftMouseDragged: owner.canvas.mouseDragged(with: event)
            case .leftMouseUp: owner.canvas.mouseUp(with: event)
            default: throw NSError(domain: "MovePickStationarySnap", code: 7)
            }
        }
        func picked(_ owner: DocumentWindowController, top: Int32) throws {
            try require(wait { owner.imageDocument.pendingWork == 0 && owner.imageDocument.activeLayer == top
                && (try? session.selectedLayers(owner.imageDocument.image)) == [top] }, "native opacity hit selection did not acknowledge")
        }
        state.select(.move)
        state.setMoveTargetMode(.pickLayerOrGuide)
        expect(NSApp.isRunning, "the fixture uses a launched AppKit host")
        let stationary = try seed("click")
        let click = try open(stationary, name: "Stationary picked layer near guide")
        let before = try snapshot(stationary.image)
        expect(!before.content.info.isDirty && !click.imageDocument.hasUnsavedChanges
            && before.selected == [stationary.bottom] && before.content.layers.count == 2
            && before.content.guides == [.init(id: stationary.guide, orientation: .vertical, position: 26)]
            && click.canvas.snapTo == SnapToViewState(guides: true),
            "a clean image starts with the bottom selected and a sole guide two pixels from the top left edge")
        let press = CGPoint(x: 50, y: 40) // Opaque top interior, 24px from the guide.
        try mouse(click, .leftMouseDown, press)
        try picked(click, top: stationary.top)
        expect(click.canvas.tools.hasPendingInteraction, "the acknowledged opacity hit owns an unreleased gesture")
        try mouse(click, .leftMouseUp, press)
        try drain(click)
        let clicked = try snapshot(stationary.image)
        expect(clicked.selected == [stationary.top] && click.imageDocument.activeLayer == stationary.top,
               "identical press and release genuinely pick the opaque top layer")
        expect(clicked.content == before.content && clicked.undo == before.undo && clicked.history == before.history
            && !click.imageDocument.info.isDirty && !click.imageDocument.hasUnsavedChanges,
            "a stationary picked click preserves exact bounds, raw/merged pixels, history and clean state without a Move Undo")

        // Fresh owners and a separately seeded native reference prevent a
        // failed stationary click from changing the positive drag oracle.
        let dragging = try seed("drag"), reference = try seed("reference")
        let drag = try open(dragging, name: "Real picked drag near guide")
        let dragBefore = try snapshot(dragging.image)
        expect(dragging.image != stationary.image && reference.image != dragging.image && reference.image != stationary.image
            && dragging.top != stationary.top && dragBefore.selected == [dragging.bottom]
            && !dragBefore.content.info.isDirty && !drag.imageDocument.hasUnsavedChanges,
            "the positive drag starts from a distinct clean image and fresh native layer identity")
        try session.selectLayer(reference.top, image: reference.image)
        let referenceBefore = try snapshot(reference.image)
        try session.moveLayer(reference.top, image: reference.image, by: CGSize(width: 2, height: 0))
        let expected = try snapshot(reference.image, normalized: true)
        expect(try session.layers(reference.image).first(where: { $0.id == reference.top })?.bounds
            == CGRect(x: 26, y: 24, width: 40, height: 40)
            && expected.undo.undoCount == referenceBefore.undo.undoCount + 1,
            "the independent native oracle translates exactly two pixels to literal guide x26 as one Undo")
        try mouse(drag, .leftMouseDown, press)
        try picked(drag, top: dragging.top)
        expect(drag.canvas.tools.hasPendingInteraction && drag.imageDocument.activeLayer == dragging.top,
               "the fresh positive press captures its actual top layer")
        let end = CGPoint(x: 51, y: 40)
        try mouse(drag, .leftMouseDragged, end)
        let held = try snapshot(dragging.image)
        expect(held.content == dragBefore.content && held.undo == dragBefore.undo && held.history == dragBefore.history,
               "the one-pixel real drag is only a preview before release")
        try mouse(drag, .leftMouseUp, end)
        try drain(drag)
        let moved = try snapshot(dragging.image), normalizedMoved = try snapshot(dragging.image, normalized: true)
        expect(moved.selected == [dragging.top] && moved.undo.undoCount == dragBefore.undo.undoCount + 1
            && moved.undo.redoCount == 0 && moved.content.info.isDirty,
            "a real one-pixel drag snaps the captured top and creates exactly one Move Undo")
        expect(normalizedMoved.content == expected.content,
               "real guide snapping matches independent literal native offset x26, raw bytes and merged projection")
        drag.imageDocument.undo(); try drain(drag)
        let undone = try snapshot(dragging.image)
        expect(undone.content == dragBefore.content && undone.selected == [dragging.top]
            && undone.undo.undoCount == dragBefore.undo.undoCount && undone.undo.redoCount == 1
            && !drag.imageDocument.hasUnsavedChanges,
            "one Undo restores the exact clean pre-drag image while retaining the transient picked target")
        drag.imageDocument.redo(); try drain(drag)
        let redone = try snapshot(dragging.image)
        expect(redone.content == moved.content && redone.selected == moved.selected && redone.undo == moved.undo,
               "one Redo restores exact snapped geometry, pixels, dirty state and one-Undo history")
    }
}
