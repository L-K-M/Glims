import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    static func exerciseLabSelections(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        let expectedPrefix = Int(ProcessInfo.processInfo.environment["GLIMS_SMOKE_LAB_PREFIX"] ?? "196") ?? 196
        check(session.supportsLabSelections == (expectedPrefix >= 196), "Lab selection capability requires both explicit writers")
        func pixels(_ image: Int32) throws -> Data {
            let output = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 40, height: 32))
            return output.dataProvider!.data! as Data
        }
        func wait(_ ready: () -> Bool, _ label: String) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline { spin(0.01) }
            check(ready(), label)
            guard ready() else { throw NSError(domain: "LabSelectionSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        var options = EngineSession.SelectOptions()
        options.antialias = false
        let rectangle = CGRect(x: 4, y: 4, width: 10, height: 8)
        if !session.supportsLabSelections {
            let image = try session.newLabImage(width: 40, height: 32, component: .u8)
            defer { try? session.closeImage(image) }
            let document = try ImageDocument(session: session, image: image, name: "Older selection engine")
            check(!document.toolIsAvailable(.rectangleSelect) && !document.toolIsAvailable(.ellipseSelect)
                  && !document.toolIsAvailable(.lasso) && document.toolIsAvailable(.hand),
                  "older Lab producers keep selection tools disabled and navigation available")
            check(document.toolIsAvailable(.paintbrush) == session.supportsLabBrush,
                  "selection compatibility preserves the older producer's independent Brush capability")
            let before = try session.undoInfo(image)
            for action in [
                { try session.selectLab(.rectangle(rectangle), image: image, options: options) },
                { try session.selectLab(.all, image: image) }
            ] {
                do { try action(); check(false, "older Lab selection writer refuses before dereferencing a missing slot") }
                catch { check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                              "older Lab selection writer refuses before dereferencing a missing slot") }
            }
            check(try session.selectionBounds(image: image) == nil && session.undoInfo(image) == before,
                  "older-producer refusal preserves mask and history")
            return
        }

        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let image = try session.newLabImage(width: 40, height: 32, component: component)
            defer { try? session.closeImage(image) }
            let axes = try session.labAxes(image), white = try pixels(image)
            let before = try session.undoInfo(image)
            try session.selectLab(.rectangle(rectangle), image: image, options: options)
            check(try session.selectionBounds(image: image) == rectangle, "Lab rectangle uses the root selection mask")
            check(try !session.selectionOutline(image: image).isEmpty, "Lab rectangle exposes marching-ants geometry")
            check(try pixels(image) == white && session.labAxes(image) == axes, "mask selection preserves Lab display and typed axes")
            check(try session.undoInfo(image).undoCount == before.undoCount + 1, "Lab selection creates one native Undo")
            try session.fillLab(image, axis: axes.axes[0], value: 0, opacity: 1)
            let filled = try pixels(image), center = (7 * 40 + 7) * 4
            check(Array(filled[center..<(center + 3)]) == [0, 0, 0] && Array(filled[0..<4]) == Array(white[0..<4]),
                  "physical Fill obeys the selected rectangle and preserves the outside")
            try session.undo(image)
            check(try pixels(image) == white && session.selectionBounds(image: image) == rectangle,
                  "Undo of Fill keeps the prior Lab selection")
            try session.undo(image)
            check(try session.selectionBounds(image: image) == nil, "next Undo restores the original empty mask")
            try session.redo(image)
            check(try session.selectionBounds(image: image) == rectangle, "Redo restores the exact rectangular selection")
            try session.selectLab(.invert, image: image)
            try session.fillLab(image, axis: axes.axes[0], value: 0, opacity: 1)
            let inverse = try pixels(image)
            check(Array(inverse[center..<(center + 4)]) == Array(white[center..<(center + 4)])
                  && Array(inverse[0..<3]) == [0, 0, 0], "Invert selects the outside without changing the Lab sample meaning")
            try session.undo(image)
            try session.selectLab(.none, image: image)
            check(try session.selectionBounds(image: image) == nil, "Lab None clears the root mask")
            try session.selectLab(.all, image: image)
            check(try session.selectionBounds(image: image) == CGRect(x: 0, y: 0, width: 40, height: 32),
                  "Lab All selects the image extent")
            try session.selectLab(.rectangle(rectangle), image: image, options: options)
            try session.selectLab(.invert, image: image)
            check(try session.selectionBounds(image: image) == CGRect(x: 0, y: 0, width: 40, height: 32),
                  "All then shape then Invert recomputes native full-mask state")
            let saved = work.appendingPathComponent("lab-selection-\(component.rawValue).xcf")
            let outline = try session.selectionOutline(image: image)
            try session.save(image, to: saved.path)
            let reopened = try session.openImage(path: saved.path)
            defer { try? session.closeImage(reopened) }
            check(try session.selectionOutline(image: reopened) == outline && pixels(reopened) == white
                  && session.labAxes(reopened).axes.map(\.uuid) == axes.axes.map(\.uuid),
                  "XCF preserves Lab selection geometry, display and durable axes")
        }

        let image = try session.newLabImage(width: 40, height: 32, component: .float)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Lab selection queue") }
        catch { try? session.closeImage(image); throw error }
        documents.items.append(document)
        defer {
            document.onUserCommand = nil
            document.cancelLabBrushStroke()
            var closed = false
            document.closeImageWhenDrained { closed = true }
            do { try wait({ closed }, "Lab selection document drains and releases native image") }
            catch { check(false, "Lab selection cleanup timeout") }
            documents.items.removeAll { $0 === document }
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        let white = try pixels(image), history = try session.undoInfo(image)
        document.select(.rectangle(rectangle), options: options)
        document.select(.invert)
        document.select(.none)
        try wait({ document.pendingWork == 0 }, "queued shape, Invert and None drain in order")
        check(errors.isEmpty && document.selectionBounds == nil && document.undoInfo.undoCount == history.undoCount + 3,
              "typed document selection requests reconcile one history step each")
        check(try pixels(image) == white, "queued Lab selections preserve displayed Lab pixels")

        let refusalHistory = try session.undoInfo(image)
        document.select(.fromAlpha)
        check(errors.count == 1 && document.pendingWork == 0 && document.undoInfo == refusalHistory,
              "unqualified Lab From Alpha refuses before queue admission")
        errors.removeAll()
        let axis = try session.labAxes(image).axes[0]
        document.setLabBrushDraft("0", for: axis)
        var brush = EngineSession.Brush(); brush.size = 8; brush.hardness = 1
        let point = EngineSession.StrokePoint(x: 8.5, y: 8.5, timeMilliseconds: 1)
        document.beginStroke(at: point, brush: brush)
        document.select(.all)
        check(errors.count == 1 && document.strokeIsActive, "selection refuses during an accepted queued brush gesture")
        try wait({ document.pendingWork == 0 }, "live brush reaches the engine after selection refusal")
        check(try pixels(image) != white && session.selectionBounds(image: image) == nil,
              "refused selection keeps the original brush handle and mask usable")
        document.cancelLabBrushStroke()
        try wait({ document.pendingWork == 0 }, "brush cancellation still drains after refused selection")
        check(try pixels(image) == white && session.undoInfo(image).undoCount == refusalHistory.undoCount,
              "cancel after selection refusal restores the full Lab gesture")
        errors.removeAll()

        var observerCalls = 0
        document.onUserCommand = {
            observerCalls += 1
            document.onUserCommand = nil
            document.beginStroke(at: point, brush: brush)
        }
        document.select(.rectangle(rectangle), options: options)
        check(observerCalls == 1 && document.strokeIsActive && errors.count == 1,
              "selection rechecks a reentrant observer's accepted stroke")
        document.cancelLabBrushStroke()
        try wait({ document.pendingWork == 0 }, "reentrant stroke cancellation drains")
        check(try session.selectionBounds(image: image) == nil && pixels(image) == white,
              "reentrant selection refusal preserves mask and Lab pixels")
        errors.removeAll()
        document.select(.ellipse(rectangle), options: options)
        try wait({ document.pendingWork == 0 }, "next Lab ellipse succeeds after the refusal")
        check(errors.isEmpty && document.selectionBounds == rectangle, "Lab selection workflow remains ready after cancellation")
    }
}
