import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBatchFit(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 32, height: 24)
        var unmanaged = [image]
        defer { for id in unmanaged { try? session.closeImage(id) } }
        for color in [NSColor.red, .green, .blue] {
            _ = try session.layerCommand(.new, image: image)
            try session.fill(image: image, at: .zero, mode: .selection, color: color)
        }
        let original = try session.layers(image).map(\.id)
        guard original.count >= 3 else { return check(false, "batch Fit fixture has three colored layers") }
        let captured = [original[1], original[0]], untouched = original[2]
        try session.moveLayer(original[0], image: image, by: CGSize(width: 4, height: 3))
        try session.moveLayer(original[1], image: image, by: CGSize(width: -5, height: -2))
        func bounds() throws -> [Int32: CGRect] {
            Dictionary(uniqueKeysWithValues: try session.layers(image).map { ($0.id, $0.bounds) })
        }
        func tree() throws -> [[Int32]] { try session.layers(image).map { [$0.id, $0.parent, Int32($0.depth)] } }
        func payloads() throws -> [Int32: Data] {
            let selection = try session.selectedLayers(image)
            do {
                var bytes: [Int32: Data] = [:]
                for id in captured { try session.selectLayer(id, image: image); bytes[id] = try session.copyPixels(image, merged: false).pixels }
                try session.selectLayers(selection, image: image)
                return bytes
            } catch { try? session.selectLayers(selection, image: image); throw error }
        }
        try session.selectLayers(captured, image: image)
        let beforeBounds = try bounds(), beforeTree = try tree(), beforePixels = try payloads()
        let beforeComposite = try session.copyPixels(image, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        func solid(_ data: Data?, _ rgba: [UInt8]) -> Bool {
            let bytes = Array(data ?? Data())
            return !bytes.isEmpty && bytes.count.isMultiple(of: 4)
                && stride(from: 0, to: bytes.count, by: 4).allSatisfy { Array(bytes[$0..<($0 + 4)]) == rgba }
        }
        check(solid(beforePixels[captured[0]], [0, 255, 0, 255]) && solid(beforePixels[captured[1]], [0, 0, 255, 255]),
              "independent source payloads contain the fixture's opaque green and blue pixels")
        let doc = try ImageDocument(session: session, image: image, name: "Fit A")
        let otherImage = try session.newImage(width: 12, height: 12); unmanaged.append(otherImage)
        let other = try ImageDocument(session: session, image: otherImage, name: "Fit B")
        let otherTree = try session.layers(otherImage), otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let controller = DocumentWindowController(document: doc), front = DocumentWindowController(document: other)
        let palette = LayersPaletteController()
        let host = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 240, height: 220),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        var gates: [DispatchSemaphore] = [], closed: Set<ObjectIdentifier> = []
        let save = FileManager.default.temporaryDirectory.appendingPathComponent("glims-batch-fit-\(UUID()).xcf")
        func waitFor(_ message: String, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline { if condition() { return true }; spin(0.01) }
            check(false, "Timed out: \(message)"); return false
        }
        func settle() -> Bool {
            guard waitFor("batch Fit accepted work drains", { doc.pendingWork == 0 && !EngineActivity.shared.isBusy }) else { return false }
            spin(); return true
        }
        func heldInput() -> DispatchSemaphore? {
            let gate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
            gates.append(gate)
            doc.inputQueue.async { started.signal(); gate.wait() }
            guard waitFor("input worker reaches indefinite barrier", { started.wait(timeout: .now()) == .success }) else { return nil }
            return gate
        }
        func succeeded(_ result: Result<Void, Error>?) -> Bool {
            guard let result else { return false }; if case .success = result { return true }; return false
        }
        func failed(_ result: Result<Void, Error>?) -> Bool {
            guard let result else { return false }; if case .failure = result { return true }; return false
        }
        defer {
            gates.forEach { $0.signal() }
            palette.retarget(to: nil); host.close()
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }
                _ = waitFor("owned canvas stops before image cleanup", { stopped })
            }
            for d in [doc, other] {
                let key = ObjectIdentifier(d)
                if !d.isClosing { d.closeImageWhenDrained { closed.insert(key) } }
                _ = waitFor("owned document closes after deferred work", { closed.contains(key) })
            }
            controller.window?.close(); front.window?.close(); spin()
            documents.items.removeAll { $0 === doc || $0 === other }
            try? FileManager.default.removeItem(at: save)
        }
        unmanaged.removeAll(); documents.items += [doc, other]
        controller.showWindow(nil); front.showWindow(nil)
        palette.retarget(to: doc); host.contentView = palette.view; host.orderFront(nil)
        let item = NSApp.mainMenu?.item(withTitle: "Layer")?.submenu?.items.first {
            $0.action == #selector(DocumentWindowController.layerToImageSize(_:))
        }
        let paletteItem = palette.paletteMenu?.items.first {
            $0.tag == Int(EngineSession.LayerCommand.fitToImage.rawValue) && $0.action != nil
        }
        guard let item, let paletteItem else { return check(false, "actual Layer and palette menus expose Fit") }
        check(try session.selectedLayers(image) == captured && captured != Array(original.prefix(2))
              && captured.allSatisfy { beforeBounds[$0]?.origin != .zero }, "fixture has native ordered off-canvas sources unlike tree order")
        check(controller.validateMenuItem(item) && palette.validateMenuItem(paletteItem)
              && item.title == "Layers to Image Size" && paletteItem.title == item.title,
              "actual main and retargeted palette menus admit plural Fit from cached state")
        front.window?.makeKeyAndOrderFront(nil)
        _ = NSApp.sendAction(#selector(DocumentWindowController.layerToImageSize(_:)), to: controller, from: item)
        guard settle() else { return }
        let fitted = CGRect(x: 0, y: 0, width: 32, height: 24), fitBounds = try bounds()
        let fitTree = try tree(), fitSelection = try session.selectedLayers(image)
        check(captured.allSatisfy { fitBounds[$0] == fitted } && fitBounds[untouched] == beforeBounds[untouched]
              && fitTree == beforeTree && fitSelection == captured,
              "main-menu Fit resizes both captured layers without tree or ordered-selection changes")
        check(try session.copyPixels(image, merged: true).pixels == beforeComposite
              && session.undoInfo(image).undoCount == baseline + 1, "Fit preserves in-canvas composite and adds one Undo")
        check(try session.layers(otherImage) == otherTree && session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "captured A changes while frontmost B stays unchanged")
        let fittedPixels = try payloads()
        doc.undo(); guard settle() else { return }
        check(try bounds() == beforeBounds && tree() == beforeTree && session.selectedLayers(image) == captured
              && session.undoInfo(image).undoCount == baseline,
              "one Undo restores exact source offsets, tree and native ordered selection")
        check(try payloads() == beforePixels && session.copyPixels(image, merged: true).pixels == beforeComposite,
              "Undo restores independent raw source pixels and composite")
        doc.redo(); guard settle() else { return }
        check(try bounds() == fitBounds && tree() == beforeTree && session.selectedLayers(image) == captured
              && session.undoInfo(image).undoCount == baseline + 1,
              "Redo restores exact fitted bounds and ordered native selection")
        check(try payloads() == fittedPixels && session.copyPixels(image, merged: true).pixels == beforeComposite,
              "Redo restores exact fitted source payloads and in-canvas composite")
        try session.save(image, to: save.path); try doc.reload()
        let clean = try session.info(image), noOpDepth = try session.undoInfo(image).undoCount
        var noOp: Result<Void, Error>?, noOpCount = 0
        doc.fitSelectedLayers { noOp = $0; noOpCount += 1 }; guard settle() else { return }
        let noOpInfo = try session.info(image), noOpHistory = try session.undoInfo(image)
        check(!clean.isDirty && succeeded(noOp) && noOpCount == 1 && !noOpInfo.isDirty
              && noOpHistory.undoCount == noOpDepth, "second all-no-op Fit preserves a clean savepoint and history")
        doc.undo(); guard settle() else { return }; palette.retarget(to: doc)
        front.window?.makeKeyAndOrderFront(nil)
        if let action = paletteItem.action { _ = NSApp.sendAction(action, to: palette, from: paletteItem) }
        guard settle() else { return }
        check(try bounds() == fitBounds && session.selectedLayers(image) == captured
              && session.copyPixels(image, merged: true).pixels == beforeComposite,
              "actual palette Fit action targets its retargeted document, preserving selection and composite")
        doc.undo(); guard settle() else { return }
        guard let selectionGate = heldInput() else { return }
        var selectedResult: Result<Void, Error>?, selectedCount = 0
        doc.fitSelectedLayers { selectedResult = $0; selectedCount += 1 }
        try session.selectLayers([untouched], image: image)
        selectionGate.signal(); guard settle() else { return }
        let selectedBounds = try bounds(), newerSelection = try session.selectedLayers(image), selectedTree = try tree()
        check(succeeded(selectedResult) && selectedCount == 1 && captured.allSatisfy { selectedBounds[$0] == fitted }
              && newerSelection == [untouched] && selectedTree == beforeTree,
              "accepted Fit uses captured ids after a native pick and preserves the newer native selection")
        doc.undo(); guard settle() else { return }; doc.selectLayers(captured); guard settle() else { return }
        guard let lockGate = heldInput() else { return }
        var locked: Result<Void, Error>?, lockCount = 0
        doc.fitSelectedLayers { locked = $0; lockCount += 1 }
        try session.setLayerLocks(captured[1], image: image, mask: [.pixels], values: [.pixels])
        let lockDepth = try session.undoInfo(image).undoCount
        lockGate.signal(); guard settle() else { return }
        let refusedBounds = try bounds(), refusedDepth = try session.undoInfo(image).undoCount
        let refusedComposite = try session.copyPixels(image, merged: true).pixels
        check(failed(locked) && lockCount == 1 && refusedBounds == beforeBounds
              && refusedDepth == lockDepth && refusedComposite == beforeComposite,
              "late second-source lock rejects the whole batch without changing its first member or history")
        palette.retarget(to: doc); let reason = doc.fitSelectedLayersRefusal()
        check(reason != nil && !controller.validateMenuItem(item) && !palette.validateMenuItem(paletteItem)
              && item.toolTip == reason && paletteItem.toolTip == reason,
              "cached main and palette lock refusals share the exact actionable reason")
        try session.setLayerLocks(captured[1], image: image, mask: [.pixels], values: []); try doc.reload()
        guard let pendingGate = heldInput() else { return }
        doc.layerCommand(.new)
        var pending: Result<Void, Error>?, pendingCount = 0
        doc.fitSelectedLayers { pending = $0; pendingCount += 1 }
        palette.retarget(to: doc)
        check(doc.targetCommandIsPending && failed(pending) && pendingCount == 1
              && !controller.validateMenuItem(item) && !palette.validateMenuItem(paletteItem),
              "queued New Layer disables both Fit menus and direct stale-target admission")
        pendingGate.signal(); guard settle() else { return }
        let pendingBounds = try bounds()
        check(doc.layers.count == original.count + 1 && captured.allSatisfy { pendingBounds[$0] == beforeBounds[$0] },
              "refused pending Fit leaves only New Layer and preserves the captured source offset")
        doc.undo(); guard settle() else { return }; doc.selectLayers(captured); guard settle() else { return }
        guard let inputGate = heldInput() else { return }
        var result: Result<Void, Error>?, completionCount = 0, idle = false
        doc.fitSelectedLayers { result = $0; completionCount += 1 }
        let exclusiveGate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0); gates.append(exclusiveGate)
        let accepted = EngineActivity.shared.perform(label: "Fit deferred completion", work: {
            started.signal(); exclusiveGate.wait()
        }, completion: { idle = true })
        inputGate.signal()
        guard accepted, waitFor("exclusive worker reaches indefinite barrier", { started.wait(timeout: .now()) == .success }) else {
            return check(false, "exclusive Fit completion fixture was admitted")
        }
        check(result == nil && doc.pendingWork > 0, "accepted Fit stays counted while its idle-delivery callback is deferred")
        var stopped = false; controller.canvas.stopRendering { stopped = true }
        guard waitFor("closing canvas stops", { stopped }) else { return }
        doc.closeImageWhenDrained { closed.insert(ObjectIdentifier(doc)) }
        check(!closed.contains(ObjectIdentifier(doc)), "close waits for Fit's accepted completion stage")
        exclusiveGate.signal()
        guard waitFor("Fit completion and native image destruction", { idle && closed.contains(ObjectIdentifier(doc)) }) else { return }
        check(succeeded(result) && completionCount == 1 && doc.pendingWork == 0,
              "accepted Fit completes exactly once and drains before close finishes")
        do { _ = try session.info(image); check(false, "closed Fit image must be NOT_FOUND") }
        catch { check((error as? EngineSession.EngineError)?.isNotFound == true, "captured Fit image is natively NOT_FOUND after close") }
    }
}
