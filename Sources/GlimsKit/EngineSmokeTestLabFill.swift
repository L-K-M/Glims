import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Native transport and document ownership, without windows or dialogs.
    static func exerciseLabFill(_ session: EngineSession, work: URL) throws {
        let prefix = Int(ProcessInfo.processInfo.environment["GLIMS_SMOKE_LAB_PREFIX"] ?? "192") ?? 192
        check(session.supportsLabFill == (prefix >= 192), "Lab fill has an independent optional capability")
        let image = try session.newLabImage(width: 8, height: 4, component: .u8)
        defer { try? session.closeImage(image) }
        let first = try session.labAxes(image).axes[0]
        if prefix < 192 {
            do { try session.fillLab(image, axis: first, value: 50, opacity: 1)
                check(false, "old producer refuses Lab fill without dereferencing its missing slot")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                      "old producer refuses Lab fill without dereferencing its missing slot")
            }
            return
        }
        func pixels(_ id: Int32) throws -> Data {
            let rendered = try session.render(id, scale: 1, area: CGRect(x: 0, y: 0, width: 8, height: 4))
            return rendered.dataProvider!.data! as Data
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let id = try session.newLabImage(width: 8, height: 4, component: component)
            defer { try? session.closeImage(id) }
            let initial = try session.labAxes(id), white = try pixels(id)
            let history = try session.undoInfo(id)
            try session.fillLab(id, axis: initial.axes[0], value: 0, opacity: 1)
            let black = try pixels(id), filled = try session.undoInfo(id)
            check(black != white && filled.undoCount == history.undoCount + 1,
                  "physical Lightness fill changes the preview with one Undo")
            try session.undo(id)
            check(try pixels(id) == white, "Undo restores the original Lab preview")
            try session.redo(id)
            check(try pixels(id) == black, "Redo restores the filled Lab preview")
            try session.fillLab(id, axis: initial.axes[0], value: 100, opacity: 1)
            check(try pixels(id) == white, "physical Lightness endpoint restores white")
            let noOpBefore = try session.undoInfo(id)
            try session.fillLab(id, axis: initial.axes[0], value: 0, opacity: 0)
            check(try pixels(id) == white && session.undoInfo(id).undoCount == noOpBefore.undoCount,
                  "zero-opacity Lab fill preserves pixels and history")
            try session.channelCommand(.select, channel: initial.axes[1].id, image: id)
            let selected = try session.labAxes(id)
            check(selected.axes.map(\.isSelected) == [false, true, false],
                  "explicit selection chooses the a axis without changing its identity")
            try session.fillLab(id, axis: selected.axes[1], value: 20, opacity: 1)
            let tinted = try pixels(id)
            check(tinted != white, "physical chroma fill changes the Lab composite")
            do { try session.fillLab(id, axis: initial.axes[0], value: 50, opacity: 1)
                check(false, "a stale selection cannot retarget a captured Lab fill")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "a stale selection cannot retarget a captured Lab fill")
            }
            let path = work.appendingPathComponent("lab-fill-\(component.rawValue).xcf").path
            try session.save(id, to: path)
            let reopened = try session.openImage(path: path)
            defer { try? session.closeImage(reopened) }
            check(try pixels(reopened) == tinted, "XCF reopen preserves the edited Lab preview")
            let restored = try session.labAxes(reopened)
            check(restored.axes.map(\.uuid) == initial.axes.map(\.uuid),
                  "Lab fill and XCF preserve all three durable axis identities")
            let beforeRefusal = try session.undoInfo(reopened)
            do { try session.fillLab(reopened, axis: selected.axes[1], value: 0, opacity: 1)
                check(false, "source handles cannot fill a separately reopened document")
            } catch {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "source handles cannot fill a separately reopened document")
            }
            check(try pixels(reopened) == tinted && session.undoInfo(reopened).undoCount == beforeRefusal.undoCount,
                  "cross-document refusal preserves pixels and Undo")
        }
        let ordinary = try session.newImage(width: 8, height: 4)
        defer { try? session.closeImage(ordinary) }
        do { try session.fillLab(ordinary, axis: first, value: 50, opacity: 1)
            check(false, "ordinary images refuse physical Lab fills")
        } catch {
            check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                  "ordinary images refuse physical Lab fills")
        }
        try exerciseLabDocumentFill(session, work: work)
    }

    private static func exerciseLabDocumentFill(_ session: EngineSession, work: URL) throws {
        func wait(_ ready: () -> Bool, _ label: String) {
            let end = Date().addingTimeInterval(15)
            while !ready() && Date() < end { spin(0.01) }
            check(ready(), label)
        }
        let id = try session.newLabImage(width: 8, height: 4, component: .u16)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: id, name: "Lab workflow") }
        catch { try? session.closeImage(id); throw error }
        defer {
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait({ closed }, "Lab document workflow drains and closes its native image")
        }
        check(document.colorInfo.mode == .lab && document.selectedLabAxis?.role == .lightness,
              "Lab document caches a typed initial Lightness target")
        guard let axes = document.labAxes else { return }
        var selected: Result<Void, Error>?
        check(document.selectLabAxis(axes.axes[1]) { selected = $0 }, "document accepts a captured Lab axis selection")
        wait({ selected != nil && document.pendingWork == 0 && !document.targetCommandIsPending },
             "Lab selection acknowledgement drains before another edit")
        try selected?.get()
        check(document.selectedLabAxis?.role == .a && document.activeDrawable == nil && document.channels.isEmpty,
              "Lab selection never becomes an ordinary paint target")
        let before = try session.undoInfo(id)
        check(!document.hasUnsavedChanges, "close-admission witness begins with a clean Lab document")
        var firstIdleDirty: Bool?, queuedCloseDecision = false
        document.onStateChange = {
            if EngineActivity.shared.isBusy && !queuedCloseDecision {
                queuedCloseDecision = true
                // A window close requested by a busy observer installs this
                // idle action before the worker's later cache reconciliation.
                EngineActivity.shared.whenIdle { firstIdleDirty = document.hasUnsavedChanges }
            }
        }
        var filled: Result<Void, Error>?
        check(document.fillLabAxis(axes.axes[1], value: 20, opacity: 1) { filled = $0 },
              "document admits physical Lab fill")
        wait({ filled != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy },
             "Lab fill acknowledgement drains and releases engine activity")
        try filled?.get()
        document.onStateChange = nil
        check(queuedCloseDecision && firstIdleDirty == true,
              "a close queued at Fill admission sees the accepted edit before cache reconciliation")
        check(document.hasUnsavedChanges && document.undoInfo.undoCount == before.undoCount + 1,
              "Lab document publishes dirty state and one Undo after fill")
        check(!document.fillLabAxis(axes.axes[0], value: 50, opacity: 1),
              "document refuses an obsolete Lab sheet target")
        document.undo()
        wait({ document.pendingWork == 0 && !document.targetCommandIsPending }, "Lab document Undo drains")
        check(document.undoInfo.redoCount == 1, "Lab document exposes Redo after Undo")
        document.redo()
        wait({ document.pendingWork == 0 && !document.targetCommandIsPending }, "Lab document Redo drains")
        let url = work.appendingPathComponent("lab-document-saved.xcf")
        var saved = false, saveError: Error?
        document.save(to: url) { saveError = $0; saved = true }
        wait({ saved && document.pendingWork == 0 }, "Lab document Save drains")
        if let saveError { throw saveError }
        document.noteSaved(to: url)
        check(!document.hasUnsavedChanges && document.fileState.nativeURL == url,
              "successful Lab Save owns its file and clears dirty state")
        document.noteRecovered()
        try document.reload()
        check(document.hasUnsavedChanges && document.fileState.nativeURL == nil && document.fileState.revertSource == nil,
              "a recovered clean Lab image requires a new Save destination")
        try document.startRecording()
        check(document.recorder.isRecording, "Lab document admits recording")
        try document.stopRecording()
        do { try document.startReplay(); check(false, "Lab document refuses an empty recording replay") }
        catch {
            check(!document.recorder.isRecording && !document.recorder.isReplaying,
                  "Lab document refuses an empty recording replay")
        }
    }
}
