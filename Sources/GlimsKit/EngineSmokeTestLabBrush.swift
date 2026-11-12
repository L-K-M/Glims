import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    static func exerciseLabBrush(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        let prefix = Int(ProcessInfo.processInfo.environment["GLIMS_SMOKE_LAB_PREFIX"] ?? "194") ?? 194
        check(session.supportsLabBrush == (prefix >= 194), "Lab Brush requires its complete optional begin/cancel contract")
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 40, height: 32))
            return rendered.dataProvider!.data! as Data
        }
        func sample(_ x: Double, _ y: Double, _ time: UInt32) -> EngineSession.StrokeSampleV2 {
            .init(point: .init(x: x, y: y, timeMilliseconds: time),
                  rotationTurns: nil, tangentialPressure: nil)
        }
        var brush = EngineSession.Brush()
        brush.size = 12; brush.hardness = 1; brush.opacity = 1
        brush.red = 1; brush.green = 0; brush.blue = 1
        let first = sample(12.5, 12.5, 1), next = sample(25.5, 12.5, 30)
        if !session.supportsLabBrush {
            let image = try session.newLabImage(width: 40, height: 32, component: .u8)
            defer { try? session.closeImage(image) }
            let axis = try session.labAxes(image).axes[0]
            do {
                _ = try session.beginLabStroke(image: image, axis: axis, value: 0, brush: brush, first: first)
                check(false, "legacy producer refuses Lab Brush before a missing slot can be called")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                      "legacy producer refuses Lab Brush before a missing slot can be called")
            }
            let document = try ImageDocument(session: session, image: image, name: "Older Lab engine")
            check(!document.toolIsAvailable(.paintbrush) && document.toolIsAvailable(.hand)
                  && document.toolIsAvailable(.zoom),
                  "older producer retains Lab navigation while Brush remains unavailable")
            return
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let image = try session.newLabImage(width: 40, height: 32, component: component)
            defer { try? session.closeImage(image) }
            let axis = try session.labAxes(image).axes[0], white = try pixels(image)
            let before = try session.undoInfo(image)
            let stroke = try session.beginLabStroke(image: image, axis: axis, value: 0, brush: brush, first: first)
            try session.continueTabletStroke(stroke, points: [next])
            check(try pixels(image) != white, "typed Lab brush publishes a live physical preview")
            check(try session.undoInfo(image).undoCount == before.undoCount, "live Lab stroke has no committed Undo")
            let refusedPath = work.appendingPathComponent("live-lab-\(component.rawValue).xcf").path
            do {
                try session.save(image, to: refusedPath)
                check(false, "Save refuses tentative Lab stroke pixels")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_BUSY.rawValue),
                      "Save refuses tentative Lab stroke pixels")
            }
            check(!FileManager.default.fileExists(atPath: refusedPath), "refused live Save creates no file")
            try session.endStroke(stroke)
            let painted = try pixels(image)
            let center = (12 * 40 + 12) * 4
            check(Array(painted[center..<(center + 3)]) == [0, 0, 0],
                  "physical L zero paints black despite a magenta RGB foreground")
            check(Array(painted[0..<4]) == Array(white[0..<4]), "brush preserves an untouched corner")
            check(try session.undoInfo(image).undoCount == before.undoCount + 1, "completed Lab stroke publishes one Undo")
            try session.undo(image)
            check(try pixels(image) == white, "Lab brush Undo restores the exact displayed baseline")
            try session.redo(image)
            check(try pixels(image) == painted, "Lab brush Redo restores the exact displayed stroke")
            let history = try session.undoInfo(image)
            let cancelled = try session.beginLabStroke(image: image, axis: axis, value: 100, brush: brush, first: first)
            try session.cancelLabStroke(cancelled)
            check(try pixels(image) == painted && session.undoInfo(image).undoCount == history.undoCount,
                  "explicit Lab cancel restores pixels without adding Undo")
            var invalid = brush; invalid.size = 0.5
            do {
                _ = try session.beginLabStroke(image: image, axis: axis, value: 0, brush: invalid, first: first)
                check(false, "subpixel brush size refuses rather than inheriting a larger native default")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "subpixel brush size refuses rather than inheriting a larger native default")
            }
            let path = work.appendingPathComponent("painted-lab-\(component.rawValue).xcf").path
            try session.save(image, to: path)
            let reopened = try session.openImage(path: path)
            defer { try? session.closeImage(reopened) }
            check(try pixels(reopened) == painted, "painted Lab XCF reopens with exact preview")
            check(try session.labAxes(reopened).axes[0].uuid == axis.uuid, "Lab brush preserves durable axis identity")
        }

        func wait(_ ready: () -> Bool, _ label: String) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline { spin(0.01) }
            check(ready(), label)
            guard ready() else { throw NSError(domain: "LabBrushSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        let image = try session.newLabImage(width: 40, height: 32, component: .float)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Lab brush queue") }
        catch { try? session.closeImage(image); throw error }
        // Receive the same engine events as an app-owned document; otherwise
        // the fixture's cached Undo state never sees completed paint events.
        documents.items.append(document)
        defer {
            document.onUserCommand = nil
            document.endStroke()
            var closed = false
            document.closeImageWhenDrained { closed = true }
            do { try wait({ closed }, "Lab brush document drains and releases its image") }
            catch { check(false, "Lab brush cleanup timeout") }
            documents.items.removeAll { $0 === document }
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        let axis = try session.labAxes(image).axes[0]
        let white = try pixels(image)
        let original = try session.undoInfo(image)
        document.setLabBrushDraft("25oops", for: axis)
        document.beginStroke(at: first.point, brush: brush)
        check(!document.strokeIsActive && document.pendingWork == 0 && errors.count == 1,
              "invalid complete physical draft refuses before admitting a queued gesture")
        errors.removeAll()
        document.setLabBrushDraft("0", for: axis)
        document.beginStroke(at: first.point, brush: brush)
        check(document.strokeIsActive && document.labBrushStrokeIsActive && document.hasUnsavedChanges,
              "accepted Lab gesture retains an unsaved hold before native dirty reconciliation")
        document.setLabBrushDraft("100", for: axis)
        document.continueStroke([next.point])
        document.endStroke()
        try wait({ document.pendingWork == 0 }, "queued Lab begin/continue/end drain in order")
        let captured = try pixels(image)
        check(captured != white && document.undoInfo.undoCount == original.undoCount + 1,
              "captured physical draft paints one stroke after the visible draft changes")
        let endCenter = (12 * 40 + 25) * 4
        check(Array(captured[endCenter..<(endCenter + 3)]) == [0, 0, 0],
              "continuation keeps the original physical value")
        document.undo()
        try wait({ document.pendingWork == 0 }, "document Undo drains")
        check(try pixels(image) == white, "document Undo restores the Lab baseline")

        document.setLabBrushDraft("0", for: axis)
        let beforeCancel = try session.undoInfo(image)
        document.beginStroke(at: first.point, brush: brush)
        document.continueStroke([next.point])
        document.cancelLabBrushStroke()
        try wait({ document.pendingWork == 0 }, "queued Lab Cancel follows pending begin and dabs")
        check(try pixels(image) == white && session.undoInfo(image).undoCount == beforeCancel.undoCount &&
                  session.undoInfo(image).redoCount == beforeCancel.redoCount,
              "queued Cancel preserves exact existing history and displayed pixels")
        check(!document.strokeIsActive && !document.labBrushStrokeIsActive && !document.hasUnsavedChanges,
              "cancelled clean Lab gesture releases activity and unsaved holds")

        // Admission observers can accept another gesture on the same stack.
        var observerCalls = 0
        document.onUserCommand = {
            observerCalls += 1
            document.onUserCommand = nil
            document.beginStroke(at: first.point, brush: brush)
        }
        document.beginStroke(at: next.point, brush: brush)
        document.endStroke()
        try wait({ document.pendingWork == 0 }, "reentrant Lab admission drains")
        check(observerCalls == 1 && errors.isEmpty, "reentrant admission queues only one native Lab begin")
        check(try session.undoInfo(image).undoCount == beforeCancel.undoCount + 1,
              "reentrant admission preserves the accepted stroke handle and one Undo")
        document.undo()
        try wait({ document.pendingWork == 0 }, "reentrant Lab stroke Undo drains")

        document.beginStroke(at: first.point, brush: brush)
        try wait({ document.pendingWork == 0 }, "live Lab gesture begin reaches the native engine")
        let axes = try session.labAxes(image)
        try session.channelCommand(.select, channel: axes.axes[1].id, image: image)
        document.continueStroke([next.point])
        document.endStroke()
        try wait({ document.pendingWork == 0 }, "stale-target continuation cancels and drains")
        check(errors.count == 1 && !document.strokeIsActive && !document.labBrushStrokeIsActive,
              "stale selected axis reports one refusal and leaves no active gesture")
        check(try pixels(image) == white && session.undoInfo(image).undoCount == beforeCancel.undoCount,
              "stale-target failure restores the complete stroke without Undo")
        errors.removeAll()
        try document.reload()
        let selected = try session.labAxes(image).axes[1]
        document.setLabBrushDraft("-20", for: selected)
        document.beginStroke(at: first.point, brush: brush)
        document.endStroke()
        try wait({ document.pendingWork == 0 }, "next selected-axis stroke works after cancellation")
        check(errors.isEmpty && document.undoInfo.undoCount == beforeCancel.undoCount + 1,
              "cancellation leaves the Lab editor ready for the next stroke")
    }
}
