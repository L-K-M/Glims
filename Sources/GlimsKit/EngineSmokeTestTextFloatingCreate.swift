import AppKit

private struct TextFloatingBuffer: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
}

private struct TextFloatingContent: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let channels: [EngineSession.Channel]
    let selectedChannels: [Int32]
    let floating: EngineSession.FloatingState
    let composite: TextFloatingBuffer
    let drawables: [TextFloatingBuffer]
    let selection: TextFloatingBuffer
    let selectionBounds: CGRect?
    let selectionOutline: [EngineSession.Segment]
    let text: [String]
    let settings: [EngineSession.TextSettings]
}

private struct TextFloatingSnapshot: Equatable {
    let content: TextFloatingContent
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

/// A queue hold, not an engine lock. Expiry is an explicit fixture failure.
private final class TextFloatingInputGate: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didExpire = false
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return didExpire }
    func block() {
        ready.signal()
        if release.wait(timeout: .now() + 30) != .success {
            lock.lock(); didExpire = true; lock.unlock()
        }
    }
}

@MainActor
extension EngineSmokeTest {
    /// Existing frontend APIs only. The missing compound create must produce
    /// behavior RED, not a compile failure or a constant-false placeholder.
    static func exerciseTextFloatingCreate(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            check(condition, "text floating: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "TextFloatingFixture", code: 1,
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
        var owners: [DocumentWindowController] = []
        var looseImages: [Int32] = []
        var gates: [TextFloatingInputGate] = []
        var completed = false
        let priorTool = ToolState.shared.current
        let priorText = ToolState.shared.textSettings
        let priorForeground = ToolState.shared.foreground
        let priorBackground = ToolState.shared.background
        let board = NSPasteboard.withUniqueName()
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            gates.forEach { $0.release.signal() }
            // Close admission before changing global tools, whose observers
            // normally apply open text. Every window follows the actual close path.
            for owner in owners { owner.window?.close() }
            let closed = wait { owners.allSatisfy { gone($0.imageDocument.image) && $0.imageDocument.pendingWork == 0 } }
            expect(closed, "all owned windows drain render/input work and native images before shutdown")
            expect(owners.allSatisfy { $0.window?.isVisible != true && $0.window?.attachedSheet == nil },
                   "owned windows leave no visible window or sheet")
            expect(gates.allSatisfy { !$0.expired }, "no queue hold expired as a substitute for release")
            for image in looseImages { try? session.closeImage(image) }
            expect(looseImages.allSatisfy { gone($0) }, "all independent reference images close before engine shutdown")
            documents.items.removeAll { doc in owners.contains { $0.imageDocument === doc } }
            ToolState.shared.textSettings = priorText
            ToolState.shared.foreground = priorForeground
            ToolState.shared.background = priorBackground
            ToolState.shared.select(priorTool)
            board.releaseGlobally()
            expect(completed, "every acceptance group reached its real assertions")
            print("     text-floating-create checks: \(count)")
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy },
                        "accepted document work did not drain")
        }
        func hold(_ document: ImageDocument) throws -> TextFloatingInputGate {
            try drain(document)
            let gate = TextFloatingInputGate(); gates.append(gate)
            document.inputQueue.async { gate.block() }
            // Latch once: a successful semaphore wait consumes its signal.
            var ready = false
            try require(wait {
                if !ready { ready = gate.ready.wait(timeout: .now()) == .success }
                return ready
            }, "input queue hold did not start")
            return gate
        }
        func buffer(_ image: CGImage?) throws -> TextFloatingBuffer {
            guard let image, let bytes = image.dataProvider?.data as Data? else {
                throw NSError(domain: "TextFloatingFixture", code: 2)
            }
            return TextFloatingBuffer(width: image.width, height: image.height, pixels: bytes)
        }
        func snapshot(_ image: Int32, normalized: Bool = false) throws -> TextFloatingSnapshot {
            let info = try session.info(image)
            let rows = try session.layers(image)
            let channels = try session.channels(image)
            // All created scenes have ordinary layers and no masks/channels;
            // broader target-kind/geometry proof remains in native170.
            try require(channels.isEmpty && rows.allSatisfy { !$0.hasMask && $0.kind != .group },
                        "unexpected shape in the ordinary-layer frontend oracle")
            let ids = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, Int32($0.offset + 1)) })
            func id(_ value: Int32) -> Int32 { normalized && value != 0 ? (ids[value] ?? -1) : value }
            let layers = rows.map {
                EngineSession.Layer(id: id($0.id), parent: id($0.parent), depth: $0.depth, kind: $0.kind,
                    name: $0.name, mode: $0.mode, isVisible: $0.isVisible, hasMask: $0.hasMask,
                    isSelected: $0.isSelected, opacity: $0.opacity, bounds: $0.bounds, filterCount: $0.filterCount)
            }
            var drawables: [TextFloatingBuffer] = [], strings: [String] = [], styles: [EngineSession.TextSettings] = []
            for row in rows {
                let bytes = try buffer(session.drawableThumbnail(row.id, image: image, maxSize: 256))
                try require(bytes.width == Int(row.bounds.width) && bytes.height == Int(row.bounds.height),
                            "drawable oracle was scaled instead of read at full resolution")
                drawables.append(bytes)
                if row.kind == .text {
                    let text = try session.textLayer(image: image, layer: row.id)
                    strings.append(text.text); styles.append(text.settings)
                }
            }
            let undo = try session.undoInfo(image), history = try session.history(image)
            // Save the full selection only in an owned duplicate. Never add a
            // channel/Undo to the image under test just to inspect its mask.
            let probe = try session.duplicateImage(image)
            defer { try? session.closeImage(probe) }
            let mask = try session.channelFromSelection(probe, name: "Text selection oracle")
            let selection = try buffer(session.drawableThumbnail(mask, image: probe, maxSize: 256))
            try require(selection.width == info.width && selection.height == info.height,
                        "selection oracle was not full resolution")
            try require(try session.undoInfo(image) == undo && session.history(image) == history,
                        "the selection probe changed original history")
            let floating = try session.floatingSelection(image)
            let content = TextFloatingContent(info: info, layers: layers,
                selected: try session.selectedLayers(image).map { id($0) }, channels: channels,
                selectedChannels: try session.selectedItems(.channel, image: image),
                floating: .init(floating: id(floating.floating), target: id(floating.target), targetKind: floating.targetKind),
                composite: try buffer(session.render(image, scale: 1,
                    area: CGRect(x: 0, y: 0, width: info.width, height: info.height))),
                drawables: drawables, selection: selection,
                selectionBounds: try session.selectionBounds(image: image),
                selectionOutline: try session.selectionOutline(image: image), text: strings, settings: styles)
            return TextFloatingSnapshot(content: content, undo: undo, history: history)
        }
        let width = 128, height = 96
        var seedBytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                seedBytes += [UInt8((x * 13 + y * 5) % 256), UInt8((x * 3 + y * 17) % 256),
                              UInt8((x * x + y * 7 + 29) % 256), UInt8(80 + (x * 7 + y * 11) % 176)]
            }
        }
        let seed = ClipboardImage(width: width, height: height, pixels: Data(seedBytes), origin: .zero)
        var payloadBytes: [UInt8] = []
        for i in 0..<80 {
            let red = UInt8(230 - i % 91)
            let green = UInt8((i * 19) % 256)
            let blue = UInt8(20 + i % 201)
            let alpha: UInt8 = i % 7 == 0 ? 0 : 190
            payloadBytes.append(contentsOf: [red, green, blue, alpha])
        }
        let payload = ClipboardImage(width: 10, height: 8,
            pixels: Data(payloadBytes), origin: CGPoint(x: 9, y: 11))
        try payload.write(to: board)
        var selectOptions = EngineSession.SelectOptions(); selectOptions.antialias = false
        func seedImage() throws -> Int32 {
            let image = try session.newImage(pixels: seed); looseImages.append(image)
            try session.select(.rectangle(CGRect(x: 8, y: 10, width: 24, height: 18)), image: image, options: selectOptions)
            return image
        }
        func owner(_ name: String, floating: Bool = false) throws -> DocumentWindowController {
            let image = try seedImage()
            let doc = try ImageDocument(session: session, image: image, name: name)
            let controller = DocumentWindowController(document: doc)
            owners.append(controller); documents.items.append(doc)
            looseImages.removeAll { $0 == image }
            controller.showWindow(nil); controller.window?.contentView?.layoutSubtreeIfNeeded()
            try drain(doc)
            if floating {
                controller.pasteIntoImage(from: board)
                try drain(doc)
                try require(try session.floatingSelection(image).isActive && doc.floatingState.isActive,
                            "actual Paste Into did not create/reconcile the floating fixture")
            }
            return controller
        }
        func front(_ controller: DocumentWindowController) throws -> NSWindow {
            guard let window = controller.window else { throw NSError(domain: "TextFloatingFixture", code: 3) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); window.makeMain()
            try require(wait { NSApp.keyWindow === window && NSApp.mainWindow === window }, "actual key/main window was not established")
            return window
        }
        let fonts = try session.fonts()
        guard let font = fonts.first(where: { !$0.isEmpty && $0.utf8.count < 128 }) else {
            throw NSError(domain: "TextFloatingFixture", code: 4)
        }
        var style = EngineSession.TextSettings()
        style.font = font; style.size = 18
        style.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.75)
        style.justify = .center; style.lineSpacing = 2; style.letterSpacing = 0.5
        ToolState.shared.textSettings = style; ToolState.shared.foreground = style.color
        ToolState.shared.select(.text)
        let origin = CGPoint(x: 51, y: 39)
        let words = "Captured A\nText"
        func press(_ controller: DocumentWindowController, at point: CGPoint = CGPoint(x: 51, y: 39)) throws {
            guard let window = controller.window else { throw NSError(domain: "TextFloatingFixture", code: 5) }
            let location = controller.canvas.convert(CGPoint(x: point.x * controller.canvas.scale,
                                                             y: point.y * controller.canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "TextFloatingFixture", code: 6)
            }
            controller.canvas.mouseDown(with: event)
        }
        func begin(_ controller: DocumentWindowController, text: String = "Captured A\nText") throws -> TextEditorOverlay {
            let window = try front(controller)
            try press(controller)
            guard let editor = controller.canvas.tools.textEditor else {
                throw NSError(domain: "TextFloatingFixture", code: 7)
            }
            try require(window.firstResponder === editor, "actual Text editor did not acquire focus")
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return editor
        }
        expect(NSApp.isRunning, "the fixture owns a running, launched AppKit host")

        // 1–2: Actual Paste Into, view-only typing and independent old-API reference.
        let a = try owner("Captured text A", floating: true)
        let docA = a.imageDocument
        let reference = try seedImage()
        guard let targetR = try session.layers(reference).first?.id else {
            throw NSError(domain: "TextFloatingFixture", code: 12)
        }
        _ = try session.pasteInto(reference, target: targetR, pixels: payload)
        expect(try snapshot(docA.image, normalized: true).content == snapshot(reference, normalized: true).content,
               "actual Paste Into fixture equals an independently seeded native floating image")
        let beforeA = try snapshot(docA.image)
        let beforeSelect = beforeA
        ToolState.shared.select(.text)
        expect(try snapshot(docA.image) == beforeSelect, "choosing Text alone leaves the floating image and history unchanged")
        let editorA = try begin(a)
        expect(a.window?.firstResponder === editorA && editorA.textLayer == nil, "a real Text press opens a new editor with keyboard focus")
        expect(try snapshot(docA.image) == beforeA, "typing changes no float, full drawable/composite/selection bytes or history")
        let expected = try session.floatingSelection(reference)
        let referenceUndo = try session.undoInfo(reference)
        _ = try session.floatingCommand(.anchor, image: reference, expected: expected.floating)
        _ = try session.addTextLayer(image: reference, text: words, settings: style, at: origin)
        expect(try session.undoInfo(reference).undoCount == referenceUndo.undoCount + 2,
               "the independent legacy anchor plus text reference really has two native commands")
        editorA.cancelOperation(nil) // Existing Escape semantics explicitly APPLY.
        try drain(docA)
        expect(a.canvas.tools.textEditor == nil && a.window?.firstResponder === a.canvas, "Escape applies and dismisses the original editor")
        expect(try !session.floatingSelection(docA.image).isActive && session.layers(docA.image).first?.kind == .text,
               "Escape Apply consumes the captured float and inserts editable text")
        let appliedA = try snapshot(docA.image)
        expect(try snapshot(docA.image, normalized: true).content == snapshot(reference, normalized: true).content,
               "all full-resolution drawable, composite, selection, tree and text facts match the independent reference")
        expect(appliedA.undo.undoCount == beforeA.undo.undoCount + 1 && appliedA.undo.nextUndo == "Add Text Layer",
               "the compound frontend creation is exactly one named Text Undo")
        docA.undo(); try drain(docA)
        expect(try snapshot(docA.image).content == beforeA.content, "one Undo restores the exact original float, IDs, targets, tree and bytes")
        docA.redo(); try drain(docA)
        expect(try snapshot(docA.image).content == appliedA.content, "one Redo restores the exact compound result")

        // 3: Captured ownership while another real document becomes key/main.
        let cross = try owner("A owner", floating: true), b = try owner("B front", floating: true)
        let crossBefore = try snapshot(cross.imageDocument.image)
        let crossEditor = try begin(cross, text: "Only A")
        let windowB = try front(b)
        let beforeB = try snapshot(b.imageDocument.image)
        expect(NSApp.keyWindow === windowB && NSApp.mainWindow === windowB, "B is genuinely key/main while A's editor is retained")
        crossEditor.onFinish?(); try drain(cross.imageDocument)
        expect(try !session.floatingSelection(cross.imageDocument.image).isActive && session.undoInfo(cross.imageDocument.image).undoCount == crossBefore.undo.undoCount + 1,
               "A's retained Apply consumes only A's captured float")
        expect(try snapshot(b.imageDocument.image) == beforeB, "B's entire native state and history stay unchanged")
        let newer = try begin(cross, text: "Newer") // Same origin may edit the existing text; identity still matters.
        try drain(cross.imageDocument) // An existing-layer pick must settle before the no-work snapshot.
        let beforeStale = try snapshot(cross.imageDocument.image)
        crossEditor.onFinish?()
        expect(cross.canvas.tools.textEditor === newer && cross.window?.firstResponder === newer,
               "a retained old overlay callback cannot finish the newer editor")
        expect(try snapshot(cross.imageDocument.image) == beforeStale, "a stale overlay callback queues no native edit")
        newer.string = newer.originalText
        cross.canvas.tools.finishTextEditing(); try drain(cross.imageDocument)

        // 4: Empty and cleared new editors are the no-submit path, not Escape cancellation.
        let empty = try owner("Empty no submit", floating: true)
        let beforeEmpty = try snapshot(empty.imageDocument.image)
        let emptyEditor = try begin(empty, text: "")
        emptyEditor.cancelOperation(nil); try drain(empty.imageDocument)
        expect(try snapshot(empty.imageDocument.image) == beforeEmpty, "empty new editor finish submits nothing and preserves the float")
        let cleared = try begin(empty, text: "Clear me")
        cleared.string = ""; cleared.cancelOperation(nil); try drain(empty.imageDocument)
        expect(try snapshot(empty.imageDocument.image) == beforeEmpty, "cleared new editor finish preserves complete floating state and history")

        // 5: This is a font validation failure, not a claimed layout-NULL case.
        let invalid = try owner("Invalid font", floating: true)
        let invalidEditor = try begin(invalid, text: "Invalid font")
        let beforeInvalid = try snapshot(invalid.imageDocument.image)
        var errors: [String] = []
        let priorError = invalid.imageDocument.onError
        invalid.imageDocument.onError = { message in priorError?(message); errors.append(message) }
        ToolState.shared.textSettings.font = "Glims missing font 72B6C6CD"
        invalidEditor.cancelOperation(nil); try drain(invalid.imageDocument)
        ToolState.shared.textSettings = style
        expect(errors == ["The font is not installed."], "invalid font reaches the actual native validation error exactly once")
        expect(try snapshot(invalid.imageDocument.image) == beforeInvalid, "validation failure preserves float, all bytes, tree and complete history")
        invalid.imageDocument.onError = priorError

        // 6: Queue an old expectation, then introduce a different actual state.
        for active in [true, false] {
            let stale = try owner(active ? "Stale active" : "Stale inactive", floating: active)
            let doc = stale.imageDocument
            let staleEditor = try begin(stale, text: "Must refuse")
            let originalState = try session.floatingSelection(doc.image)
            let gate = try hold(doc)
            var staleErrors: [String] = []
            let oldError = doc.onError
            doc.onError = { message in oldError?(message); staleErrors.append(message) }
            staleEditor.cancelOperation(nil)
            expect(doc.targetCommandIsPending, "\(active ? "active" : "inactive") captured create is counted before native execution")
            if active { _ = try session.floatingCommand(.discard, image: doc.image, expected: originalState.floating) }
            guard let target = try session.layers(doc.image).first?.id else { throw NSError(domain: "TextFloatingFixture", code: 8) }
            let replacement = try session.pasteInto(doc.image, target: target, pixels: payload)
            let intervened = try snapshot(doc.image)
            gate.release.signal(); try drain(doc)
            expect(!gate.expired, "\(active ? "active" : "inactive") queue intervention used explicit release")
            expect(!staleErrors.isEmpty && staleErrors.contains(where: { $0.contains("captured floating selection") }),
                   "\(active ? "active" : "inactive") stale expectation reports actual mismatch, never fallback")
            expect(try snapshot(doc.image) == intervened && session.floatingSelection(doc.image).floating == replacement,
                   "\(active ? "active" : "inactive") stale create leaves the replacement float and all post-intervention state unchanged")
            expect(doc.floatingState == intervened.content.floating, "refusal reconciles the captured document's actual floating cache")
            doc.onError = oldError
        }

        // 7: Finishing one floating editor and clicking again cannot capture its stale cache.
        let pending = try owner("Pending next editor", floating: true)
        let pendingDoc = pending.imageDocument
        let previousEditor = try begin(pending, text: "First")
        let pendingBefore = try session.undoInfo(pendingDoc.image)
        let pendingGate = try hold(pendingDoc)
        previousEditor.cancelOperation(nil)
        expect(pendingDoc.targetCommandIsPending, "the first Apply is already accepted while its target is unresolved")
        guard let pendingWindow = pending.window else { throw NSError(domain: "TextFloatingFixture", code: 13) }
        try press(pending, at: CGPoint(x: 110, y: 83))
        expect(pending.canvas.tools.textEditor == nil && pending.statusBar.message == ImageDocument.DocumentError.busy.localizedDescription,
               "new-editor start refuses the pending target with the existing busy reason")
        pendingGate.release.signal(); try drain(pendingDoc)
        expect(try !session.floatingSelection(pendingDoc.image).isActive && session.undoInfo(pendingDoc.image).undoCount == pendingBefore.undoCount + 1,
               "the preceding floating Apply still completes exactly once")
        try press(pending, at: CGPoint(x: 110, y: 83))
        expect(pending.canvas.tools.textEditor != nil && pendingWindow.firstResponder === pending.canvas.tools.textEditor,
               "after reconciliation a new click opens a focused editor with inactive capture")
        pending.canvas.tools.textEditor?.insertText("Next", replacementRange: NSRange(location: NSNotFound, length: 0))
        pending.canvas.tools.finishTextEditing(); try drain(pendingDoc)
        expect(try session.undoInfo(pendingDoc.image).undoCount == pendingBefore.undoCount + 2,
               "the reconciled inactive editor creates one ordinary Text Undo")

        // 8: Existing Text behavior and closure are distinct from cancellation.
        let ordinary = try owner("Existing text")
        let ordinaryEditor = try begin(ordinary, text: "Ordinary")
        let ordinaryUndo = try session.undoInfo(ordinary.imageDocument.image)
        ordinaryEditor.cancelOperation(nil); try drain(ordinary.imageDocument)
        guard let textRow = try session.layers(ordinary.imageDocument.image).first(where: { $0.kind == .text }) else {
            throw NSError(domain: "TextFloatingFixture", code: 9)
        }
        expect(try session.textLayer(image: ordinary.imageDocument.image, layer: textRow.id).text == "Ordinary" && session.undoInfo(ordinary.imageDocument.image).undoCount == ordinaryUndo.undoCount + 1,
               "ordinary inactive creation keeps Escape Apply and one Undo")
        _ = try front(ordinary)
        try press(ordinary, at: textRow.bounds.origin)
        guard let editing = ordinary.canvas.tools.textEditor else { throw NSError(domain: "TextFloatingFixture", code: 10) }
        expect(editing.textLayer == textRow.id, "the existing-layer branch still edits its actual Text layer")
        try drain(ordinary.imageDocument)
        let beforeEdit = try session.undoInfo(ordinary.imageDocument.image)
        let beforeEditCount = try session.layers(ordinary.imageDocument.image).count
        editing.string = "Changed"; editing.cancelOperation(nil); try drain(ordinary.imageDocument)
        expect(try session.textLayer(image: ordinary.imageDocument.image, layer: textRow.id).text == "Changed"
                && session.layers(ordinary.imageDocument.image).count == beforeEditCount
                && session.undoInfo(ordinary.imageDocument.image).undoCount == beforeEdit.undoCount + 1,
               "existing content changes on the same Text layer as one Undo")
        _ = try front(ordinary); try press(ordinary, at: textRow.bounds.origin)
        guard let deleting = ordinary.canvas.tools.textEditor else { throw NSError(domain: "TextFloatingFixture", code: 11) }
        try drain(ordinary.imageDocument)
        let beforeDelete = try session.undoInfo(ordinary.imageDocument.image)
        deleting.string = ""; deleting.cancelOperation(nil); try drain(ordinary.imageDocument)
        expect(try !session.layers(ordinary.imageDocument.image).contains(where: { $0.id == textRow.id })
                && session.undoInfo(ordinary.imageDocument.image).undoCount == beforeDelete.undoCount + 1,
               "applying an empty existing editor keeps one undoable deletion")

        let closing = try owner("Accepted close", floating: true)
        let closeDoc = closing.imageDocument
        let closingEditor = try begin(closing, text: "Close after acceptance")
        let closeUndo = try session.undoInfo(closeDoc.image)
        let closeGate = try hold(closeDoc)
        closingEditor.cancelOperation(nil)
        expect(closeDoc.targetCommandIsPending && closeDoc.pendingWork > 0, "creation is accepted and counted before actual window close")
        var observedBeforeNativeClose = false
        let priorState = closeDoc.onStateChange
        closeDoc.onStateChange = {
            priorState?()
            if closeDoc.isClosing, let undo = try? session.undoInfo(closeDoc.image),
               let floating = try? session.floatingSelection(closeDoc.image),
               let layers = try? session.layers(closeDoc.image) {
                observedBeforeNativeClose = undo.undoCount == closeUndo.undoCount + 1 && !floating.isActive && layers.contains { $0.kind == .text }
            }
        }
        closing.window?.close()
        expect(closeDoc.isClosing && !closeDoc.acceptsEdits && !gone(closeDoc.image), "actual close stops admission while accepted text keeps the native image alive")
        closeGate.release.signal()
        expect(wait { gone(closeDoc.image) && closeDoc.pendingWork == 0 }, "accepted creation drains before native image destruction")
        expect(observedBeforeNativeClose, "before native destruction the accepted compound text has really completed once")
        closeDoc.onStateChange = priorState
        let closedCount = closeDoc.pendingWork
        closingEditor.onFinish?()
        expect(closeDoc.pendingWork == closedCount && gone(closeDoc.image), "late retained callback after actual close queues no work")
        let unsubmitted = try owner("Unsubmitted close", floating: true)
        let unsubmittedEditor = try begin(unsubmitted, text: "No late create")
        unsubmitted.window?.close()
        try require(wait { gone(unsubmitted.imageDocument.image) }, "unsubmitted window did not close")
        unsubmittedEditor.onFinish?()
        expect(unsubmitted.imageDocument.pendingWork == 0 && gone(unsubmitted.imageDocument.image), "direct close of an open editor refuses its late Apply without native work")
        completed = true
    }
}
