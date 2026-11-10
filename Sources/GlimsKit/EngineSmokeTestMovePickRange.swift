import AppKit

private struct MovePickRangeBuffer: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
}

private struct MovePickRangeContent: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let channels: [EngineSession.Channel]
    let selectedChannels: [Int32]
    let floating: EngineSession.FloatingState
    let composite: MovePickRangeBuffer
    let drawables: [MovePickRangeBuffer]
    let locks: [EngineSession.LayerLockState]
    let masks: [EngineSession.MaskState]
    let selection: MovePickRangeBuffer
    let guides: [EngineSession.Guide]
}

private struct MovePickRangeSnapshot: Equatable {
    let content: MovePickRangeContent
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

@MainActor
extension EngineSmokeTest {
    /// A separate range regression; the original Move Pick acceptance fixture
    /// remains frozen. The reference uses a tiny drawable at a large offset,
    /// never a giant image or the frontend's proposed geometry policy.
    static func exerciseMovePickRange(_ session: EngineSession, work: URL,
                                      documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1; check(value, "Move pick range: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MovePickRangeFixture", code: 1,
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
        let priorTool = ToolState.shared.current
        var priorMode: String?
        let options = ToolOptionsPaletteController()
        let panel = NSPanel(contentRect: CGRect(x: 20, y: 30, width: 280, height: 210),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        func mode() -> NSPopUpButton? {
            all(options.view, NSPopUpButton.self).first {
                $0.identifier?.rawValue == "move-target-mode" || $0.accessibilityLabel() == "Move target"
                    || $0.itemTitles == ["Current Layer", "Pick Layer or Guide"]
            }
        }
        func chooseMode(_ title: String) throws {
            guard let control = mode(), control.itemTitles.contains(title) else {
                throw NSError(domain: "MovePickRangeFixture", code: 2)
            }
            control.selectItem(withTitle: title)
            try require(control.sendAction(control.action, to: control.target), "Move mode action is connected")
            try require(mode()?.selectedItem?.title == title, "Move mode action reconciles the control")
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            if let priorMode {
                ToolState.shared.select(.move)
                try? chooseMode(priorMode)
            }
            for owner in owners { owner.window?.close() }
            expect(wait { owners.allSatisfy { gone($0.imageDocument.image) && $0.imageDocument.pendingWork == 0 } },
                   "all owned windows/renderers/native images drain")
            for image in loose { try? session.closeImage(image) }
            expect(loose.allSatisfy { gone($0) }, "all independent native reference images close")
            panel.close()
            expect(owners.allSatisfy { $0.window?.isVisible != true && $0.window?.attachedSheet == nil }
                   && !panel.isVisible && panel.attachedSheet == nil, "no owned window or dialog remains")
            documents.items.removeAll { doc in owners.contains { $0.imageDocument === doc } }
            ToolState.shared.select(priorTool)
            print("     move-pick-range checks: \(count)")
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "counted work drains")
        }
        func buffer(_ image: CGImage?) throws -> MovePickRangeBuffer {
            guard let image, let bytes = image.dataProvider?.data as Data? else {
                throw NSError(domain: "MovePickRangeFixture", code: 3)
            }
            return .init(width: image.width, height: image.height, pixels: bytes)
        }
        func snapshot(_ image: Int32, normalized: Bool = false) throws -> MovePickRangeSnapshot {
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
            var pixels: [MovePickRangeBuffer] = [], locks: [EngineSession.LayerLockState] = [], masks: [EngineSession.MaskState] = []
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
            return MovePickRangeSnapshot(content: .init(info: info, layers: normalizedRows,
                selected: try session.selectedLayers(image).map { id($0) }, channels: channels,
                selectedChannels: try session.selectedItems(.channel, image: image),
                floating: .init(floating: id(floating.floating), target: id(floating.target), targetKind: floating.targetKind),
                composite: try buffer(session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))),
                drawables: pixels, locks: locks, masks: masks, selection: coverage, guides: guides), undo: undo, history: history)
        }
        var baseBytes: [UInt8] = []
        for y in 0..<96 {
            for x in 0..<128 {
                baseBytes += [UInt8((x * 7 + y * 11) % 256), UInt8((x * 17 + y * 3) % 256),
                              UInt8((x + y * 23 + 19) % 256), 255]
            }
        }
        var topBytes: [UInt8] = []
        for y in 0..<12 {
            for x in 0..<12 {
                topBytes += [UInt8(160 + (x * 3 + y * 5) % 96), UInt8((x * 13 + y * 7) % 150),
                             UInt8(20 + (x * 5 + y * 11) % 160), 255]
            }
        }
        let base = ClipboardImage(width: 128, height: 96, pixels: Data(baseBytes), origin: .zero)
        let payload = ClipboardImage(width: 12, height: 12, pixels: Data(topBytes), origin: CGPoint(x: 24, y: 24))
        var select = EngineSession.SelectOptions(); select.antialias = false
        func image() throws -> (image: Int32, bottom: Int32, top: Int32) {
            let value = try session.newImage(pixels: base); loose.append(value)
            guard let bottom = try session.layers(value).first?.id else {
                throw NSError(domain: "MovePickRangeFixture", code: 3)
            }
            try session.select(.rectangle(CGRect(x: 18, y: 18, width: 24, height: 24)), image: value, options: select)
            let top = try session.pastePixels(value, pixels: payload, at: payload.origin)
            try require(try session.layers(value).first(where: { $0.id == top })?.bounds
                        == CGRect(x: 24, y: 24, width: 12, height: 12), "literal small drawable placement")
            try session.selectLayer(bottom, image: value)
            return (value, bottom, top)
        }
        func scene(_ name: String) throws -> (owner: DocumentWindowController, top: Int32) {
            let value = try image()
            let doc = try ImageDocument(session: session, image: value.image, name: name)
            let owner = DocumentWindowController(document: doc)
            owners.append(owner); documents.items.append(doc); loose.removeAll { $0 == value.image }
            owner.showWindow(nil); owner.window?.contentView?.layoutSubtreeIfNeeded()
            owner.canvas.snapTo = SnapToViewState()
            try drain(doc)
            return (owner, value.top)
        }
        func front(_ owner: DocumentWindowController) throws {
            guard let window = owner.window else { throw NSError(domain: "MovePickRangeFixture", code: 4) }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeMain()
            try require(wait { NSApp.keyWindow === window && NSApp.mainWindow === window }, "actual key/main focus settles")
        }
        func mouse(_ owner: DocumentWindowController, _ type: NSEvent.EventType, _ point: CGPoint) throws {
            guard let window = owner.window else { throw NSError(domain: "MovePickRangeFixture", code: 5) }
            let location = owner.canvas.convert(CGPoint(x: point.x * owner.canvas.scale, y: point.y * owner.canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "MovePickRangeFixture", code: 6)
            }
            switch type {
            case .leftMouseDown: owner.canvas.mouseDown(with: event)
            case .leftMouseDragged: owner.canvas.mouseDragged(with: event)
            case .leftMouseUp: owner.canvas.mouseUp(with: event)
            default: throw NSError(domain: "MovePickRangeFixture", code: 7)
            }
        }

        ToolState.shared.select(.move)
        _ = options.view
        let range = try scene("Move Pick native coordinate range")
        let document = range.owner.imageDocument
        options.retarget(to: document); panel.contentView = options.view; panel.orderFront(nil)
        expect(NSApp.isRunning, "fixture has a normally launched AppKit host")
        expect(mode() != nil, "actual Move target control is available")
        guard let initial = mode() else {
            print("     range behaviors NOT RUN: required existing Move mode is absent")
            return
        }
        priorMode = initial.selectedItem?.title
        try chooseMode("Pick Layer or Guide")
        let before = try snapshot(document.image)
        expect(before.content.info.width == 128 && before.content.info.height == 96
               && before.content.layers.first(where: { $0.id == range.top })?.bounds
                    == CGRect(x: 24, y: 24, width: 12, height: 12),
               "literal 128×96 image has a 12×12 drawable; large offsets require no large allocation")

        // The reference is a separate native image, and receives a literal
        // translation directly. No proposed frontend helper computes expected facts.
        let reference = try image()
        try session.selectLayer(reference.top, image: reference.image)
        let referenceBefore = try snapshot(reference.image)
        try session.moveLayer(reference.top, image: reference.image, by: CGSize(width: 600_000, height: 0))
        let expected = try snapshot(reference.image, normalized: true)
        expect(try session.layers(reference.image).first(where: { $0.id == reference.top })?.bounds
                    == CGRect(x: 600_024, y: 24, width: 12, height: 12)
               && expected.content.info.width == 128 && expected.content.info.height == 96
               && expected.undo.undoCount == referenceBefore.undo.undoCount + 1,
               "direct native +600000 translation succeeds at literal offset 600024 with one Undo")

        try front(range.owner)
        let press = CGPoint(x: 26, y: 26), far = CGPoint(x: 600_026, y: 26)
        try mouse(range.owner, .leftMouseDown, press)
        try require(wait { (try? session.selectedLayers(document.image)) == [range.top]
                    && document.pendingWork == 0 }, "authentic press selection acknowledges before drag")
        let pressed = try snapshot(document.image)
        expect(pressed.content.selected == [range.top] && document.activeLayer == range.top,
               "actual press selected and acknowledged the captured opaque upper layer")
        expect(pressed.undo == before.undo && pressed.history == before.history
               && pressed.content.composite == before.content.composite && pressed.content.drawables == before.content.drawables,
               "press selection changes neither pixels nor native history")
        try mouse(range.owner, .leftMouseDragged, far)
        try drain(document)
        let dragged = try snapshot(document.image)
        expect(dragged.undo == pressed.undo && dragged.history == pressed.history
               && dragged.content.composite == pressed.content.composite && dragged.content.drawables == pressed.content.drawables,
               "far drag preview changes neither drawable bytes, composite nor native history")
        try mouse(range.owner, .leftMouseUp, far)
        try drain(document)
        let moved = try snapshot(document.image)
        let movedNormalized = try snapshot(document.image, normalized: true)
        let accepted = moved.content.layers.first(where: { $0.id == range.top })?.bounds
            == CGRect(x: 600_024, y: 24, width: 12, height: 12)
            && movedNormalized.content == expected.content
            && moved.undo.undoCount == pressed.undo.undoCount + 1
        expect(accepted, "valid Pick +600000 drag matches native offset 600024, full bytes/target/composite and one Undo (old 524288-cap RED)")
        if accepted {
            expect(moved.content.drawables == pressed.content.drawables,
                   "off-canvas movement retains exact small drawable bytes")
            document.undo(); try drain(document)
            let undone = try snapshot(document.image)
            expect(undone.content == pressed.content && undone.undo.undoCount == pressed.undo.undoCount
                   && undone.undo.redoCount == 1, "one Undo restores exact pre-move content and picked target")
            document.redo(); try drain(document)
            expect(try snapshot(document.image).content == moved.content
                   && session.undoInfo(document.image).undoCount == moved.undo.undoCount,
                   "one Redo restores the literal large-offset native result")
        } else {
            print("     three post-move byte/Undo/Redo checks NOT RUN: valid large-offset movement was refused")
        }

        // Refusal controls obtain an ownership token by the real counted
        // hit-query and selection acknowledgment APIs. Never forge ownership
        // and never call native movement with an unsafe numeric input.
        let refusal = try scene("Move Pick unsafe arithmetic refusal")
        let refusalDocument = refusal.owner.imageDocument
        let captured = refusalDocument.floatingState
        let revision = refusalDocument.moveTargetRevision
        var hitResult: Result<EngineSession.Layer?, Error>?
        refusalDocument.readMoveHit(at: press, expected: captured) { hitResult = $0 }
        try require(wait { hitResult != nil && refusalDocument.pendingWork == 0 }, "counted refusal hit query acknowledges")
        guard let result = hitResult, let row = try result.get() else {
            throw NSError(domain: "MovePickRangeFixture", code: 8)
        }
        var ownershipResult: Result<ImageDocument.MoveSelectionOwnership, Error>?
        refusalDocument.selectMoveHit(row, expected: captured, revision: revision) { ownershipResult = $0 }
        try require(wait { ownershipResult != nil && refusalDocument.pendingWork == 0 }, "real refusal target selection acknowledges")
        guard let ownershipResult else { throw NSError(domain: "MovePickRangeFixture", code: 9) }
        let owned = try ownershipResult.get()
        let selectedForRefusal = try session.selectedLayers(refusalDocument.image)
        expect(row.id == refusal.top && refusalDocument.ownsMoveSelection(owned)
               && selectedForRefusal == [refusal.top],
               "unsafe controls start with authentic current picked-layer ownership")
        let refusalBefore = try snapshot(refusalDocument.image)
        var errors: [String] = []
        let priorError = refusalDocument.onError
        refusalDocument.onError = { message in priorError?(message); errors.append(message) }
        defer { refusalDocument.onError = priorError }
        let invalid: [(String, CGSize)] = [
            ("positive rounded delta outside Int32", CGSize(width: Double(Int32.max) + 0.5, height: 0)),
            ("negative rounded delta outside Int32", CGSize(width: Double(Int32.min) - 0.75, height: 0)),
            ("valid delta but overflowing translated origin", CGSize(width: Double(Int32.max) - 17, height: 0)),
            ("valid origin but overflowing right endpoint", CGSize(width: Double(Int32.max) - 30, height: 0)),
            ("valid origin but overflowing bottom endpoint", CGSize(width: 0, height: Double(Int32.max) - 30)),
            ("NaN delta", CGSize(width: Double.nan, height: 0)),
            ("positive infinite delta", CGSize(width: Double.infinity, height: 0)),
            ("negative infinite delta", CGSize(width: 0, height: -Double.infinity)),
            ("finite unrepresentable delta", CGSize(width: Double.greatestFiniteMagnitude, height: 0))
        ]
        for (label, offset) in invalid {
            try require(refusalDocument.ownsMoveSelection(owned), "refusal control must retain authentic ownership")
            let errorsBefore = errors.count
            refusalDocument.movePickedLayer(row, expected: captured, ownership: owned, by: offset)
            let rejectedSynchronously = refusalDocument.pendingInput == 0 && refusalDocument.pendingWork == 0
            try drain(refusalDocument)
            let afterRefusal = try snapshot(refusalDocument.image)
            expect(rejectedSynchronously && errors.count == errorsBefore + 1
                   && refusalDocument.ownsMoveSelection(owned)
                   && afterRefusal == refusalBefore,
                   "\(label) refuses before native admission and preserves exact pixels/history/target")
        }
        _ = work
    }
}
