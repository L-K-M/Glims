import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// Actual palette field editing plus explicit Rigi phase callbacks. These
    /// callbacks test tracking/commit ownership, not hardware mouse or VoiceOver.
    static func exerciseLayerOpacity(_ session: EngineSession, documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1; check(value, "layer opacity: \(message)")
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func views<T: NSView>(_ root: NSView, as type: T.Type) -> [T] {
            let own = (root as? T).map { [$0] } ?? []
            return own + root.subviews.flatMap { views($0, as: type) }
        }
        func pixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> ClipboardImage {
            ClipboardImage(width: 8, height: 8, pixels: Data((0..<64).flatMap { _ in [red, green, blue, 255] }), origin: .zero)
        }
        let imageA = try session.newImage(pixels: pixels(255, 0, 0))
        let imageB = try session.newImage(pixels: pixels(0, 0, 255))
        let a = try ImageDocument(session: session, image: imageA, name: "Opacity A")
        let b = try ImageDocument(session: session, image: imageB, name: "Opacity B")
        documents.items += [a, b]
        let owner = DocumentWindowController(document: a), front = DocumentWindowController(document: b)
        owner.showWindow(nil); front.showWindow(nil)
        let palette = LayersPaletteController()
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: LayersPaletteController.definition.contentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = palette.view
        window.orderFront(nil)
        var errorsA: [String] = [], errorsB: [String] = []
        let oldErrorA = a.onError, oldErrorB = b.onError
        a.onError = { errorsA.append($0) }; b.onError = { errorsB.append($0) }
        func settle(_ document: ImageDocument) {
            expect(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "accepted work drains")
            spin()
        }
        defer {
            window.makeFirstResponder(nil)
            palette.retarget(to: nil)
            window.close()
            for controller in [owner, front] {
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                expect(wait { stopped }, "canvas stops before image destruction")
            }
            for document in [a, b] where !document.isClosing {
                var closed = false; document.closeImageWhenDrained { closed = true }
                expect(wait { closed }, "fixture image closes after all accepted work")
            }
            owner.window?.close(); front.window?.close()
            a.onError = oldErrorA; b.onError = oldErrorB
            documents.items.removeAll { $0 === a || $0 === b }
            expect((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                   "both native images are gone before smoke engine shutdown")
            print("     layer-opacity checks: \(count)")
        }
        guard let row = views(palette.view, as: ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
              let field = views(row, as: NSTextField.self).first(where: { $0.isEditable }),
              let slider = views(row, as: NSSlider.self).first,
              let layerA = a.activeLayer, let layerB = b.activeLayer else {
            expect(false, "the Layers palette contains its accessible opacity slider and field (baseline RED)")
            return
        }
        expect(!row.isHidden && !row.isEnabled && !field.isEnabled && !slider.isEnabled,
               "no-document opacity stays visible and disabled")
        palette.view.layoutSubtreeIfNeeded()
        let units = views(row, as: NSTextField.self).filter { !$0.isEditable && $0.stringValue == "%" }
        expect(palette.view.bounds.contains(field.convert(field.bounds, to: palette.view))
                && palette.view.bounds.contains(slider.convert(slider.bounds, to: palette.view))
                && units.count == 1 && units.allSatisfy { palette.view.bounds.contains($0.convert($0.bounds, to: palette.view)) },
               "the slider, field and percent unit fit the palette's prepared size")
        func nativeOpacity(_ image: Int32, _ layer: Int32) throws -> Double {
            guard let value = try session.layers(image).first(where: { $0.id == layer })?.opacity else {
                throw ImageDocument.DocumentError.busy
            }
            return value
        }
        func commitField(_ text: String) {
            field.stringValue = text
            _ = field.sendAction(field.action, to: field.target)
        }
        func phase(_ value: Double, _ phase: ClassicValueSlider.Phase) {
            row.value = value
            row.onChange?(value, phase)
        }
        palette.retarget(to: a); settle(a); palette.reload()
        expect(row.isEnabled && field.accessibilityLabel() == "Layer opacity value" && row.value == 100,
               "one cached layer enables the labelled percentage field and slider")
        let rawA = try session.copyPixels(imageA, merged: false).pixels
        let rawB = try session.copyPixels(imageB, merged: false).pixels
        let historyB = try session.undoInfo(imageB)
        let initialUndo = try session.undoInfo(imageA)
        commitField("100.0"); settle(a)
        expect(try session.undoInfo(imageA) == initialUndo && nativeOpacity(imageA, layerA) == 1,
               "an identical field commit adds no native history")
        commitField("50"); settle(a); palette.reload()
        let half = try session.copyPixels(imageA, merged: true).pixels
        expect(try nativeOpacity(imageA, layerA) == 0.5 && session.undoInfo(imageA).undoCount == initialUndo.undoCount + 1,
               "the actual field commits literal native 50 percent as one Undo")
        expect(half.count == 256 && stride(from: 0, to: half.count, by: 4).allSatisfy {
            half[$0] == 255 && half[$0 + 1] == 0 && half[$0 + 2] == 0 && abs(Int(half[$0 + 3]) - 128) <= 1
        }, "independent red pixels retain their color with half composite alpha")
        expect(try session.copyPixels(imageA, merged: false).pixels == rawA
                && session.copyPixels(imageB, merged: false).pixels == rawB && session.undoInfo(imageB) == historyB,
               "opacity changes no stored target pixel or other document fact")
        let dragUndo = try session.undoInfo(imageA)
        phase(20, .tracking); phase(30, .tracking); palette.reload()
        expect(try row.value == 30 && nativeOpacity(imageA, layerA) == 0.5 && session.undoInfo(imageA) == dragUndo,
               "tracking stays local and survives a same-target reload without native writes")
        phase(40, .committed); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.4 && session.undoInfo(imageA).undoCount == dragUndo.undoCount + 1,
               "one committed phase adds exactly one native Undo")
        a.undo(); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.5 && session.copyPixels(imageA, merged: true).pixels == half,
               "one Undo restores the exact earlier native opacity and composite")
        a.redo(); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.4 && row.value == 40,
               "one Redo restores the committed opacity and cached control")

        // Rigi's old-internal81 / exact dirty81.00 / external92 regression.
        try session.changeLayer(layerA, image: imageA, .init(opacity: 0.81)); try a.reload(); palette.reload()
        expect(window.makeFirstResponder(field) && field.currentEditor() != nil, "the actual opacity field starts editing")
        if let editor = field.currentEditor() {
            editor.string = "81.00"; editor.selectedRange = NSRange(location: 1, length: 3)
            try session.changeLayer(layerA, image: imageA, .init(opacity: 0.92)); try a.reload(); palette.reload()
            let beforeEnd = try session.undoInfo(imageA)
            expect(editor.string == "81.00" && editor.selectedRange == NSRange(location: 1, length: 3)
                    && field.currentEditor() === editor && window.firstResponder === editor && row.value == 92,
                   "external cache updates preserve exact dirty text, selection and focus while advancing Rigi baseline")
            window.makeFirstResponder(nil); settle(a); palette.reload()
            expect(try nativeOpacity(imageA, layerA) == 0.81 && session.undoInfo(imageA).undoCount == beforeEnd.undoCount + 1,
                   "explicit end commits 81 over external 92 even when it equals the old control baseline")
        }
        expect(window.makeFirstResponder(field) && field.currentEditor() != nil, "the field starts a partial or invalid draft")
        if let editor = field.currentEditor() {
            editor.string = "81."
            try session.changeLayer(layerA, image: imageA, .init(opacity: 0.87)); try a.reload(); palette.reload()
            expect(editor.string == "81." && field.currentEditor() === editor, "partial numeric formatting survives reload")
            editor.string = "-"
            try session.changeLayer(layerA, image: imageA, .init(opacity: 0.89)); try a.reload(); palette.reload()
            let beforeEnd = try session.undoInfo(imageA)
            expect(editor.string == "-" && window.firstResponder === editor, "invalid draft survives an external cache update")
            window.makeFirstResponder(nil); settle(a); palette.reload()
            expect(try nativeOpacity(imageA, layerA) == 0.89 && session.undoInfo(imageA) == beforeEnd && row.value == 89,
                   "ending invalid input restores authoritative opacity without an edit")
        }
        expect(window.makeFirstResponder(field) && field.currentEditor() != nil, "the captured A field starts before retarget")
        if let editor = field.currentEditor() { editor.string = "62.5" }
        front.window?.makeKeyAndOrderFront(nil)
        palette.retarget(to: b); settle(a); settle(b); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.625 && nativeOpacity(imageB, layerB) == 1 && row.value == 100,
               "retarget finishes the old field on A and displays B without writing B")
        palette.retarget(to: a); settle(a); palette.reload()
        let capturedUndo = try session.undoInfo(imageA)
        phase(35, .tracking); palette.retarget(to: b)
        expect(row.value == 35, "retarget does not overwrite an active tracking value")
        phase(45, .committed); settle(a); settle(b); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.45 && nativeOpacity(imageB, layerB) == 1
                && row.value == 100 && session.undoInfo(imageA).undoCount == capturedUndo.undoCount + 1,
               "release uses captured A while B is shown; late completion preserves B's value")

        palette.retarget(to: a); settle(a); palette.reload()
        let group = try session.createGroup(image: imageA, index: 0, name: "Opacity group")
        try session.selectLayers([group], image: imageA); try a.reload(); palette.reload()
        expect(row.isEnabled, "a real native group is an opacity property target")
        commitField("60"); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, group) == 0.6 && session.layers(imageA).first(where: { $0.id == group })?.kind == .group,
               "group opacity changes without rasterizing its structure")
        var textSettings = EngineSession.TextSettings(); textSettings.size = 8
        let text = try session.addTextLayer(image: imageA, text: "Opacity", settings: textSettings, at: .zero)
        try session.selectLayers([text], image: imageA); try a.reload(); palette.reload()
        expect(row.isEnabled, "an editable text layer retains its native opacity property")
        commitField("65"); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, text) == 0.65 && session.textLayer(image: imageA, layer: text).text == "Opacity",
               "text opacity does not replace its retained source")
        try session.selectLayers([layerA], image: imageA)
        let mask = try session.addLayerMask(layerA, image: imageA, source: .white, edit: true)
        try a.reload(); palette.reload()
        expect(a.activeDrawable == mask && row.isEnabled, "a parent opacity row remains available while its mask is the paint target")
        commitField("55"); settle(a); palette.reload()
        expect(try nativeOpacity(imageA, layerA) == 0.55 && session.layerMask(layerA, image: imageA).editing
                && a.activeDrawable == mask, "opacity edits the captured parent and preserves actual mask targeting")
        let channel = try session.channelFromSelection(imageA, name: "Opacity channel target")
        try a.reload(); palette.reload()
        expect(a.activeDrawable == channel && a.isChannelTargetActive, "a real saved channel is the active paint target")
        if a.selectedLayerIDs == [layerA] {
            expect(row.isEnabled, "a remembered single-layer property stays available during channel editing")
            commitField("64"); settle(a); palette.reload()
            expect(try nativeOpacity(imageA, layerA) == 0.64, "channel editing does not silently redirect parent opacity")
        } else {
            expect(!row.isEnabled, "without one cached selected layer the channel context disables opacity")
        }
        expect(a.activeDrawable == channel && a.isChannelTargetActive,
               "parent opacity does not replace the actual channel paint target")
        palette.retarget(to: b); settle(b); palette.reload()

        let extra = try session.layerCommand(.new, image: imageB)
        try b.reload()
        guard let extra else { return expect(false, "multi-selection fixture has a second real layer") }
        b.selectLayers([layerB, extra]); settle(b); palette.reload()
        let multipleUndo = try session.undoInfo(imageB)
        expect(!row.isEnabled && !field.isEnabled && !slider.isEnabled, "multiple cached layers disable the visible opacity row")
        row.onChange?(10, .committed); settle(b)
        expect(try session.undoInfo(imageB) == multipleUndo && nativeOpacity(imageB, layerB) == 1,
               "disabled multi-selection cannot edit only its primary")
        b.selectLayers([layerB]); settle(b); palette.reload()
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Layer opacity busy fixture", work: {
            ready.signal(); _ = release.wait(timeout: .now() + 20)
        }, completion: {})
        var started = false
        let deadline = Date().addingTimeInterval(10)
        while !started && Date() < deadline { started = ready.wait(timeout: .now()) == .success; if !started { spin(0.005) } }
        palette.reload()
        expect(held && started && !row.isEnabled && !field.isEnabled && !slider.isEnabled,
               "busy admission disables the row using cached state without waiting on the engine")
        release.signal(); expect(wait { !EngineActivity.shared.isBusy }, "the busy fixture releases")
        settle(b); palette.reload()
        expect(row.isEnabled, "idle reconciliation restores the same control")
        try session.setLayerLocks(layerB, image: imageB, mask: [.pixels, .alpha], values: [.pixels, .alpha])
        try b.reload(); palette.reload()
        expect(row.isEnabled, "pixel and alpha locks do not invent an opacity restriction")
        commitField("75"); settle(b); palette.reload()
        expect(try nativeOpacity(imageB, layerB) == 0.75, "native opacity remains editable on locked layer pixels")

        // A deleted native layer behind an intentionally stale cache makes the
        // accepted explicit property write fail. No newly selected layer may
        // receive that failed request instead.
        try session.setLayerLocks(layerB, image: imageB, mask: [.pixels, .alpha], values: [])
        _ = try session.layerCommand(.delete, image: imageB, layer: layerB)
        let afterDelete = try session.undoInfo(imageB), failuresBefore = errorsB.count
        commitField("55"); settle(b); palette.reload()
        expect(errorsB.count == failuresBefore + 1, "a stale explicit native target reports one real failure")
        expect(try session.undoInfo(imageB) == afterDelete && nativeOpacity(imageB, extra) == 1 && row.value == 100,
               "failure resets to authoritative cache without editing the replacement layer or history")

        var stopped = false; front.canvas.stopRendering { stopped = true }
        expect(wait { stopped }, "B canvas stops before the counted close case")
        let inputReady = DispatchSemaphore(value: 0), inputRelease = DispatchSemaphore(value: 0)
        b.run(effect: .readsPixels) { _, _ in inputReady.signal(); _ = inputRelease.wait(timeout: .now() + 20) }
        var inputStarted = false
        let inputDeadline = Date().addingTimeInterval(10)
        while !inputStarted && Date() < inputDeadline {
            inputStarted = inputReady.wait(timeout: .now()) == .success
            if !inputStarted { spin(0.005) }
        }
        commitField("70")
        var closed = false
        b.closeImageWhenDrained { closed = true }
        palette.reload()
        expect(inputStarted && b.pendingWork > 0 && !closed && !row.isEnabled,
               "close disables the row and waits for already accepted input and its reconciliation")
        let pendingAtClose = b.pendingWork
        row.onChange?(20, .committed)
        expect(b.pendingWork == pendingAtClose, "a late committed callback cannot enqueue new opacity after close admission")
        inputRelease.signal()
        expect(wait { closed && b.pendingWork == 0 }, "accepted opacity work and close both drain")
        expect((try? session.info(imageB)) == nil, "counted close destroys B only after accepted work finishes")
        expect(errorsA.isEmpty && errorsB.count == failuresBefore + 1, "only the deliberately stale native target reported an error")
    }
}
