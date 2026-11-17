import AppKit
import CGlimsEngine
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// Image ▸ Duplicate: the sheet offers "As" and Merged Layers Only
    /// (hidden without slot 241, dimmed for one layer); the copy opens as
    /// a new document under the chosen name, blank names fall back to
    /// "<name> copy", and Merged Layers Only makes one "Merged Layers"
    /// layer with the visible composite and an empty history.
    static func exerciseImageDuplicate(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }

        // The form.
        let form = DuplicateImageForm(name: "Art copy", offersMerged: true, layerCount: 3)
        let unchecked = !form.mergedLayersOnly
        form.merged.state = .on
        check(form.name.stringValue == "Art copy" && form.offersMerged && unchecked && form.mergedLayersOnly,
              "Duplicate offers a name and Merged Layers Only")
        let single = DuplicateImageForm(name: "One copy", offersMerged: true, layerCount: 1)
        single.merged.state = .on
        check(single.offersMerged && !single.merged.isEnabled && !single.mergedLayersOnly,
              "Merged Layers Only is dimmed for a single-layer image")
        let old = DuplicateImageForm(name: "Old copy", offersMerged: false, layerCount: 3)
        old.merged.state = .on
        check(!old.offersMerged && !old.mergedLayersOnly, "Merged Layers Only is hidden where it cannot run")

        // A white background, a half-opaque red layer and a hidden blue one.
        let image = try session.newImage(width: 24, height: 16)
        let source: ImageDocument
        do { source = try ImageDocument(session: session, image: image, name: "Art") }
        catch { try? session.closeImage(image); throw error }
        documents.items.append(source)
        var opened: [ImageDocument] = []
        defer {
            for document in opened + [source] {
                NSApp.windows
                    .first { ($0.windowController as? DocumentWindowController)?.imageDocument === document }?
                    .orderOut(nil)
                var closed = false; document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
                documents.items.removeAll { $0 === document }
            }
            PaletteCenter.shared.closeAll()
        }
        if let red = try session.layerCommand(.new, image: image) {
            try session.fill(image: image, at: .zero, mode: .selection, color: .red)
            try session.changeLayer(red, image: image, EngineSession.LayerChange(opacity: 0.5))
        }
        if let blue = try session.layerCommand(.new, image: image) {
            try session.fill(image: image, at: .zero, mode: .selection, color: .blue)
            try session.changeLayer(blue, image: image, EngineSession.LayerChange(isVisible: false))
        }
        try source.reload()
        let composite = pixel(session, image, x: 5, y: 5)
        let sourceLayers = try session.layers(image).count
        check(source.duplicateName == "Art copy" && sourceLayers == 3,
              "Duplicate suggests \"Art copy\" for a three-layer source")

        var errors: [String] = []
        let previousError = source.onError
        source.onError = { errors.append($0) }
        defer { source.onError = previousError }

        guard session.supportsImageDuplicateMerged else {
            var requests: [(String, Bool)] = []
            source.duplicateHandler = { _, name, merged in requests.append((name, merged)) }
            source.duplicate(as: "Flat", mergedLayersOnly: true)
            source.duplicate(as: "  ", mergedLayersOnly: false)
            source.duplicateHandler = nil
            check(!source.canDuplicateMergedLayers && requests.count == 1 && requests[0] == ("Art copy", false)
                    && errors.count == 1,
                  "an older adapter refuses Merged Layers Only and still duplicates (\(requests), \(errors))")
            var refused = false
            do { _ = try session.duplicateImageMerged(image, layerName: "Merged Layers") }
            catch { refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) }
            check(refused, "an older adapter's session refuses a merged duplicate as unsupported")
            return
        }

        let app = AppController()
        source.duplicateHandler = { [weak app] document, name, merged in
            app?.snapshot(document, as: name, mergedLayersOnly: merged)
        }
        defer { source.duplicateHandler = nil }
        check(source.canDuplicateMergedLayers, "Merged Layers Only is offered for an ordinary layered image")

        source.duplicate(as: "Flat", mergedLayersOnly: true)
        wait { app.documents.count == 1 }
        let flat = app.documents.first?.imageDocument
        if let flat { opened.append(flat); documents.items.append(flat) }
        if let flat {
            wait { flat.pendingWork == 0 && !EngineActivity.shared.isBusy }
            let names = flat.layers.map(\.name)
            let merged = pixel(session, flat.image, x: 5, y: 5)
            let clean = flat.undoInfo.undoCount == 0 && flat.fileState.nativeURL == nil
            check(flat.name == "Flat" && names == [ImageDocument.mergedLayerName] && clean
                    && composite != nil && merged == composite,
                  "Merged Layers Only opens \"Flat\" with one \"Merged Layers\" layer of the visible composite "
                  + "(\(names), \(String(describing: merged)) vs \(String(describing: composite)))")
        } else {
            check(false, "Merged Layers Only opens a new document (\(errors))")
        }

        source.duplicate(as: " ", mergedLayersOnly: false)
        wait { app.documents.count == 2 }
        let copy = app.documents.count == 2 ? app.documents[1].imageDocument : nil
        if let copy { opened.append(copy); documents.items.append(copy) }
        let copyName = copy?.name, copyLayers = copy?.layers.count, copyUndo = copy?.undoInfo.undoCount
        check(copyName == "Art copy" && copyLayers == 3 && copyUndo == 0,
              "a blank name duplicates every layer as \"Art copy\"")
        let keptLayers = try session.layers(image).count
        check(keptLayers == 3 && errors.isEmpty,
              "the source keeps its layers (\(errors))")
        for document in [flat, copy].compactMap({ $0 }) { document.longQueue.sync {} }
        spin()
    }
}
