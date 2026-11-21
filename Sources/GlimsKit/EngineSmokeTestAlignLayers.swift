import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Layer ▸ Align and Layer ▸ Distribute: six Photoshop-named items
    /// each; Align needs two selected layers (or one and a selection),
    /// Distribute three; Align Left moves the selected layers' content to
    /// the active layer's left edge in one undo step. Adapters without
    /// slot 243 keep both submenus disabled.
    static func exerciseAlignLayers(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }

        let layerMenu = MainMenu.make().items.first { $0.title == "Layer" }?.submenu
        let titles = ["Align", "Distribute"].map { name in
            layerMenu?.items.first { $0.title == name }?.submenu?.items.map(\.title) ?? []
        }
        let expected = ["Top Edges", "Vertical Centers", "Bottom Edges",
                        "Left Edges", "Horizontal Centers", "Right Edges"]
        check(titles == [expected, expected], "Layer ▸ Align and Distribute list Photoshop's six edges and centers (\(titles))")

        // Three canvas-sized layers with content at x 5, 20 and 45.
        let image = try session.newImage(width: 60, height: 40)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Align") }
        catch { try? session.closeImage(image); throw error }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        func settle() {
            document.inputQueue.sync {}
            spin()
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        }
        var ids: [Int32] = []
        for (index, left) in [5, 20, 45].enumerated() {
            guard let layer = try session.layerCommand(.new, image: image) else { continue }
            try session.select(.rectangle(CGRect(x: left, y: 2 + 10 * index, width: 10, height: 6)), image: image,
                               options: EngineSession.SelectOptions(antialias: false))
            try session.fill(image: image, at: .zero, mode: .selection, color: .red)
            ids.append(layer)
        }
        try session.select(.none, image: image)
        func item(_ alignment: EngineSession.LayerAlignment) -> NSMenuItem {
            let entry = NSMenuItem(title: alignment.title,
                                   action: #selector(DocumentWindowController.alignLayersFromMenu(_:)), keyEquivalent: "")
            entry.tag = Int(alignment.rawValue)
            return entry
        }
        func x(_ layer: Int32) -> CGFloat? { document.layers.first { $0.id == layer }?.bounds.minX }

        guard session.supportsAlignLayers else {
            try session.selectLayers(ids, image: image)
            try document.reload()
            check(!controller.validateMenuItem(item(.alignLeft)) && !controller.validateMenuItem(item(.distributeLeft)),
                  "an older adapter keeps Align and Distribute disabled")
            var refused = false
            do { try session.alignLayers(ids, image: image, reference: ids[0], .alignLeft) }
            catch { refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) }
            check(refused, "an older adapter's session refuses Align as unsupported")
            return
        }
        guard ids.count == 3 else { return check(false, "three layers for Align (\(ids))") }

        try session.selectLayers([ids[0]], image: image)
        try document.reload()
        check(!controller.validateMenuItem(item(.alignLeft)), "Align needs two layers without a selection")
        try session.selectLayers([ids[0], ids[1]], image: image)
        try document.reload()
        check(controller.validateMenuItem(item(.alignLeft)) && !controller.validateMenuItem(item(.distributeLeft)),
              "two selected layers can align but not distribute")
        try session.selectLayers(ids, image: image)
        try document.reload()
        let active = document.activeLayer
        check(controller.validateMenuItem(item(.distributeLeft)), "three selected layers can distribute")

        let undoBefore = document.undoInfo.undoCount
        controller.alignLayersFromMenu(item(.alignLeft))
        settle()
        let shifted = ids.map { x($0) ?? .nan }
        // The active layer is the reference and stays put.
        let reference = ids.firstIndex { $0 == active }.map { [5, 20, 45][$0] } ?? 5
        let expectedShift = [5, 20, 45].map { CGFloat(reference - $0) }
        check(shifted == expectedShift && document.undoInfo.undoCount == undoBefore + 1,
              "Align Left moves the content to the active layer's left edge in one step (\(shifted) vs \(expectedShift))")
        document.undo()
        settle()
        check(ids.allSatisfy { x($0) == 0 }, "Undo restores the layers")

        controller.alignLayersFromMenu(item(.distributeHorizontalCenter))
        settle()
        check(x(ids[0]) == 0 && x(ids[1]) == 5 && x(ids[2]) == 0 && document.undoInfo.undoCount == undoBefore + 1,
              "Distribute Horizontal Centers moves only the middle layer (\(String(describing: x(ids[1]))))")
        document.undo()
        settle()

        try session.select(.rectangle(CGRect(x: 0, y: 0, width: 58, height: 40)), image: image,
                           options: EngineSession.SelectOptions(antialias: false))
        try session.selectLayers([ids[2]], image: image)
        try document.reload()
        document.refreshSelection()
        check(controller.validateMenuItem(item(.alignRight)), "one layer can align to a selection")
        controller.alignLayersFromMenu(item(.alignRight))
        settle()
        check(x(ids[2]) == 3 && x(ids[0]) == 0, "Align Right with a selection aligns to its right edge (\(String(describing: x(ids[2]))))")

        let group = try session.createGroup(image: image, index: 0, name: "Reference group")
        try session.reparentLayer(ids[1], image: image, toParent: group, index: 0)
        try session.selectLayers([ids[1], group, ids[2]], image: image)
        try document.reload()
        check(document.activeLayer == ids[1] && controller.validateMenuItem(item(.alignRight)),
              "a selected group containing the active layer can align to a pixel selection")
        try session.select(.none, image: image)
        document.refreshSelection()
        check(!controller.validateMenuItem(item(.alignRight)),
              "a selected group containing the reference disables layer-relative Align")
    }
}
