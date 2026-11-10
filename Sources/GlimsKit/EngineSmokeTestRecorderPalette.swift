import AppKit
import RigiUI

private struct RecorderPaletteNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let undo: EngineSession.UndoInfo
}

@MainActor
extension EngineSmokeTest {
    /// Actual Recorder controls and menu wiring. A controller-only fixture
    /// supplies the front document explicitly; Root separately checks enabled
    /// app-level menus in a real interactive single-engine launch.
    static func exerciseRecorderPalette(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder palette: \(message)")
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw NSError(domain: "RecorderPaletteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func snapshot(_ image: Int32) throws -> RecorderPaletteNativeState {
            let info = try session.info(image)
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "RecorderPaletteFixture", code: 2)
            }
            return RecorderPaletteNativeState(info: info, pixels: pixels,
                selection: try session.selectionBounds(image: image), outline: try session.selectionOutline(image: image),
                undo: try session.undoInfo(image))
        }
        var bytes: [UInt8] = []
        for y in 0..<19 { for x in 0..<27 {
            bytes += [UInt8((x * 17 + y * 7) % 256), UInt8((x * 3 + y * 23) % 256),
                      UInt8((x * x + y * 11 + 31) % 256), 255]
        } }
        let pixels = ClipboardImage(width: 27, height: 19, pixels: Data(bytes), origin: .zero)
        let imageA = try session.newImage(pixels: pixels)
        let imageB = try session.newImage(pixels: pixels)
        let reference = try session.newImage(pixels: pixels)
        let a = try ImageDocument(session: session, image: imageA, name: "Recorder Palette A")
        let b = try ImageDocument(session: session, image: imageB, name: "Recorder Palette B")
        documents.items += [a, b]
        let owner = AppController()
        let paletteKinds = AppController.defaultPaletteLayout.flatMap(\.kinds)
        let previouslyPresented = Set(paletteKinds.filter {
            PaletteCenter.shared.registeredPalette(for: $0)?.isPresented == true
        })
        defer {
            for kind in paletteKinds where !previouslyPresented.contains(kind) {
                PaletteCenter.shared.registeredPalette(for: kind)?.close()
            }
        }
        // Smoke mode may have no AppKit main window. Match the interactive
        // owner's real document fallback instead of inventing a target.
        owner.open(b)
        owner.open(a)
        try require(owner.documents.count == 2, "the real application owner did not adopt both fixture documents")
        let windowB = owner.documents[0], windowA = owner.documents[1]
        windowA.window?.makeKeyAndOrderFront(nil)
        var current: ImageDocument? = a
        let palette = RecorderPaletteController(currentDocument: { current })
        let host = NSPanel(contentRect: NSRect(origin: .zero, size: RecorderPaletteController.definition.contentSize),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        host.title = "Recorder Controls Fixture"
        host.isReleasedWhenClosed = false
        host.contentViewController = palette
        palette.retarget(to: a)
        host.orderFront(nil)
        host.contentView?.layoutSubtreeIfNeeded()
        defer {
            current = nil
            palette.retarget(to: nil)
            host.orderOut(nil); host.close()
            for controller in [windowA, windowB] {
                controller.previewPanel?.cancel()
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                _ = wait { stopped }
                if !controller.closeStarted { controller.window?.close() }
                _ = wait { (try? session.info(controller.imageDocument.image)) == nil }
            }
            expect(wait { a.pendingWork == 0 && b.pendingWork == 0
                && (try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil },
                "all document work, controls and native images close before engine shutdown")
            try? session.closeImage(reference)
            documents.items.removeAll { $0 === a || $0 === b }
            print("     recorder-palette checks: \(checks)")
        }
        let root = palette.view
        guard let table = views(root, NSTableView.self).first else {
            return expect(false, "the actual palette contains its recorded-command table")
        }
        func label(_ accessibility: String) -> NSTextField? {
            views(root, NSTextField.self).first { $0.accessibilityLabel() == accessibility }
        }
        func button(_ action: RecorderPaletteAction) -> NSButton? {
            views(root, NSButton.self).first { $0.accessibilityLabel() == "Recorder \(action.title)" }
        }
        func click(_ action: RecorderPaletteAction) { button(action)?.performClick(nil) }
        func rowTexts() -> [String] {
            (0..<table.numberOfRows).map { row in
                let rowView = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                return views(rowView, NSTextField.self).map(\.stringValue).joined(separator: " ")
            }
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !document.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "document did not drain: \(document.name)")
            palette.reload() // Mirrors registered palette retarget after a document-state change.
            spin(0.02)
        }
        func hold(_ document: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            document.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
            let ready = entered.wait(timeout: .now() + 3) == .success
            if !ready { release.signal() }
            try require(ready, "the bounded input hold did not start")
            return release
        }
        func menuItem(_ menu: NSMenu?, _ action: RecorderPaletteAction) -> NSMenuItem? {
            menu?.items.first { $0.tag == action.rawValue }
        }
        // Opening the real default palettes accepts counted thumbnail reads.
        // Wait for those jobs and target preparation, rather than assuming
        // the application is ready in the same turn as owner.open.
        let startupReady = wait {
            [a, b].allSatisfy { $0.pendingWork == 0 && !$0.targetCommandIsPending
                && !$0.strokeIsActive && $0.acceptsEdits }
                && !EngineActivity.shared.isBusy
                && RecorderPalettePresentation(document: a).canPerform(.record)
        }
        expect(startupReady, "startup palette reads and target preparation drain before Recorder ready-state assertions")
        if !startupReady {
            let reason = RecorderPalettePresentation(document: a).refusal(for: .record) ?? "none"
            throw NSError(domain: "RecorderPaletteFixture", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Recorder startup refused: \(reason); A pending=\(a.pendingWork), target=\(a.targetCommandIsPending), stroke=\(a.strokeIsActive), accepts=\(a.acceptsEdits); B pending=\(b.pendingWork), target=\(b.targetCommandIsPending), stroke=\(b.strokeIsActive), accepts=\(b.acceptsEdits); activity=\(EngineActivity.shared.label ?? "idle")"])
        }
        palette.reload()
        let titleMenu = palette.paletteMenu
        expect(RecorderPaletteAction.allCases.allSatisfy { button($0) != nil }, "all five real actions have distinct accessible buttons")
        expect(label("Supported Recorder actions")?.stringValue == RecorderPalettePresentation.coverage
                && label("Recorder replay behavior")?.stringValue.contains("Undo") == true,
               "supported selections/image-only coverage, same-image replay and Undo consequences are visible")
        expect(label("Recorder image")?.stringValue == a.name && table.numberOfRows == 0,
               "the initial view identifies A and shows its actual empty recording")
        expect(button(.record)?.isEnabled == true && button(.stop)?.isEnabled == false
                && button(.replay)?.isEnabled == false && button(.cancelReplay)?.isEnabled == false && button(.clear)?.isEnabled == false,
               "initial button gates honestly distinguish Record from unavailable commands")
        expect(RecorderPaletteAction.allCases.allSatisfy { action in
            menuItem(titleMenu, action).map { palette.validateMenuItem($0) == button(action)?.isEnabled } == true
        }, "actual title-menu admission agrees with all five buttons")
        let menu = NSApp.mainMenu
        let editRecorder = menu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Recorder")?.submenu
        let showRecorder = menu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Recorder")
        expect(showRecorder?.action == #selector(AppController.showRecorder(_:))
                && editRecorder?.items.map(\.title) == RecorderPaletteAction.allCases.map(\.title),
               "the real Window entry and Edit submenu expose Recorder and every action")
        expect(RecorderPaletteAction.allCases.allSatisfy { action in
            menuItem(editRecorder, action)?.action == #selector(AppController.recorderCommand(_:))
        }, "Edit actions preserve distinct tags through the real application route")
        if let menu {
            let shortcuts = MenuShortcutBridge.collect(from: menu)
            expect(RecorderPaletteAction.allCases.allSatisfy { shortcuts.byID["recorderCommand:#\($0.rawValue)"] != nil }
                    && shortcuts.errors.isEmpty, "shortcut discovery collects every static tagged Recorder command")
        } else { expect(false, "the real menu exists for shortcut discovery") }
        expect(showRecorder.map { !owner.validateMenuItem($0) } == true
                && RecorderPaletteAction.allCases.allSatisfy { action in
                    menuItem(editRecorder, action).map { !owner.validateMenuItem($0) } == true
                }, "a nonrunning application honestly refuses real Window/Edit Recorder menu admission")
        let initial = try snapshot(imageA), untouchedB = try snapshot(imageB)
        if let showRecorder, let action = showRecorder.action { _ = NSApp.sendAction(action, to: owner, from: showRecorder) }
        expect(PaletteCenter.shared.registeredPalette(for: RecorderPaletteController.definition.kind)?.isPresented == true,
               "the real Window action registers and presents the Recorder palette")
        if let item = menuItem(editRecorder, .record), let action = item.action { _ = NSApp.sendAction(action, to: owner, from: item) }
        expect(a.recorder.isRecording && !b.recorder.isRecording, "the actual Edit Record route resolves front document A")
        if let item = menuItem(editRecorder, .stop), let action = item.action { _ = NSApp.sendAction(action, to: owner, from: item) }
        palette.reload()
        expect(!a.recorder.isRecording && (try? snapshot(imageA)) == initial,
               "the actual Edit Stop route stops recording without editing the image")

        guard let registeredRecorder = PaletteCenter.shared.registeredPalette(for: RecorderPaletteController.definition.kind),
              let anchor = button(.record), anchor.window?.isVisible == true,
              let recordItem = menuItem(editRecorder, .record), let recordAction = recordItem.action,
              let stopItem = menuItem(editRecorder, .stop), let stopAction = stopItem.action else {
            throw NSError(domain: "RecorderPaletteFixture", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The registered Recorder palette, owned visible anchor and real Edit actions must exist."])
        }
        let rowsBeforeTransition = RecorderPalettePresentation(document: a).rows
        let statusBeforeTransition = a.replayStatus
        let menuTagsBeforeTransition = editRecorder?.items.map(\.tag)
        let startedAsPanel = registeredRecorder.presentation == .panel
        // Present raises an already open panel. Close it first: Rigi retains
        // its panel content, but now genuinely invokes the factory for an
        // attached form, which must have a distinct view controller.
        registeredRecorder.close()
        try require(wait { !registeredRecorder.isPresented }, "Recorder panel did not close before attached presentation")
        registeredRecorder.present(from: anchor)
        let presentedAsPopover = wait { registeredRecorder.presentation == .popover }
        registeredRecorder.showPanel()
        let returnedToPanel = wait { registeredRecorder.presentation == .panel }
        try require(wait { a.pendingWork == 0 && b.pendingWork == 0 && !EngineActivity.shared.isBusy },
                    "Recorder presentation changes did not drain accepted document reads")
        _ = NSApp.sendAction(recordAction, to: owner, from: recordItem)
        let globalRecordReachedA = a.recorder.isRecording && !b.recorder.isRecording
        _ = NSApp.sendAction(stopAction, to: owner, from: stopItem)
        let recorderStatePreserved = !a.recorder.isRecording && a.recorder.pendingCount == 0
            && RecorderPalettePresentation(document: a).rows == rowsBeforeTransition
            && a.replayStatus == statusBeforeTransition && b.recorder.records.isEmpty
        let nativeStatePreserved = try snapshot(imageA) == initial && snapshot(imageB) == untouchedB
        expect(startedAsPanel && presentedAsPopover && returnedToPanel && globalRecordReachedA
                && owner.frontDocument === a && recorderStatePreserved && nativeStatePreserved
                && editRecorder?.items.map(\.tag) == menuTagsBeforeTransition,
               "the registered Recorder supports separate attached/panel forms and retains global Edit routing without changing either image or its recording")

        var legacyNotifications = 0, observerNotifications = 0, oneShotNotifications = 0
        var stateNotifications = 0, errors: [String] = []
        let previousState = a.onStateChange
        a.onStateChange = { stateNotifications += 1; previousState?() }
        a.onError = { errors.append($0) }
        a.onRecorderChange = { legacyNotifications += 1 }
        let observer = a.addRecorderObserver { observerNotifications += 1 }
        var oneShot: UUID?
        oneShot = a.addRecorderObserver {
            oneShotNotifications += 1
            if let oneShot { a.removeRecorderObserver(oneShot) }
        }
        defer { a.removeRecorderObserver(observer); if let oneShot { a.removeRecorderObserver(oneShot) } }
        let gate = try hold(a)
        defer { gate.signal() }
        click(.record)
        a.select(.all)
        a.transformImage(.flipHorizontal)
        expect(a.recorder.isRecording && a.recorder.pendingCount == 2 && a.pendingWork == 2
                && table.numberOfRows == 0 && label("Recorder pending commands")?.stringValue.contains("2") == true,
               "real Record shows the exact pending count without publishing unsettled rows")
        expect(button(.stop)?.isEnabled == true && button(.replay)?.isEnabled == false
                && button(.clear)?.isEnabled == false,
               "Stop remains available to fence accepted work while Replay and Clear refuse pending capture")
        click(.stop)
        expect(!a.recorder.isRecording && a.recorder.pendingCount == 2 && a.pendingWork == 2,
               "the real Stop button fences accepted commands without discarding or draining them synchronously")
        current = b; windowB.window?.makeKeyAndOrderFront(nil); palette.retarget(to: b)
        expect(table.numberOfRows == 0 && label("Recorder image")?.stringValue == b.name,
               "retarget to B immediately replaces A's pending presentation with B's recording")
        gate.signal()
        try drain(a)
        expect(table.numberOfRows == 0 && label("Recorder image")?.stringValue == b.name,
               "late A settlements cannot overwrite B's rows after its observer token is removed")
        expect(legacyNotifications == 6 && observerNotifications == 6 && oneShotNotifications == 1,
               "existing callback and removable observers keep exact notification timing under reentrant removal")
        let stateBefore = stateNotifications
        a.onStateChange?(); a.onError?("Recorder handler sentinel")
        expect(stateNotifications == stateBefore + 1 && errors == ["Recorder handler sentinel"],
               "palette observation never replaces the original image-state or error handlers")
        errors.removeAll()
        current = nil; palette.retarget(to: nil)
        expect(RecorderPaletteAction.allCases.allSatisfy { button($0)?.isEnabled == false }
                && table.numberOfRows == 0 && label("Recorder image")?.stringValue == "No image",
               "retarget to no document clears rows and disables every command")
        current = a; windowA.window?.makeKeyAndOrderFront(nil); palette.retarget(to: a)
        let expectedRows = ["1. Recorded: Select All", "2. Recorded: Flip Image Horizontally"]
        expect(rowTexts() == expectedRows, "settled commands appear in exact native acceptance order with explicit success text")
        expect(button(.replay)?.isEnabled == true && button(.stop)?.isEnabled == false,
               "returning to settled A offers Replay rather than an active recording")
        try session.select(.all, image: reference)
        try session.transformImage(reference, .flipHorizontal)
        expect(try snapshot(imageA) == snapshot(reference) && snapshot(imageB) == untouchedB,
               "recorded controls preserve the independent native result and leave B unchanged")
        click(.replay)
        try require(wait { a.pendingWork == 0 && !a.recorder.isReplaying && !EngineActivity.shared.isBusy },
                    "replay and its accepted thumbnail reads did not drain")
        expect(a.acceptsEdits && RecorderPalettePresentation(document: a).canPerform(.record)
                && RecorderPalettePresentation(document: a).canPerform(.replay)
                && button(.record)?.isEnabled == true && button(.replay)?.isEnabled == true,
               "settled replay automatically re-enables Record and Replay after all accepted reads drain, without reload or retarget")
        // Refresh only after the readiness assertion so an initial failure
        // cannot cascade through the remaining independent workflow checks.
        try drain(a)
        try session.select(.all, image: reference)
        try session.transformImage(reference, .flipHorizontal)
        expect(a.replayStatus == .finished(total: 2) && label("Recorder status")?.stringValue == "Replayed 2 commands.",
               "the real Replay button reaches an explicit two-command success status")
        expect(try snapshot(imageA) == snapshot(reference) && rowTexts() == expectedRows,
               "UI replay matches independent direct native calls and preserves the recorded rows")

        let replayGate = try hold(a)
        defer { replayGate.signal() }
        let beforeCancelledReplay = try snapshot(imageA)
        click(.replay)
        expect(a.recorder.isReplaying && a.pendingWork == 1 && button(.cancelReplay)?.isEnabled == true,
               "accepted replay work remains counted while Cancel Replay is available")
        click(.cancelReplay)
        expect(a.replayStatus == .cancelled(index: 0) && a.pendingWork == 1
                && label("Recorder status")?.stringValue.contains("already running may finish") == true,
               "actual Cancel Replay stops later scheduling and honestly describes accepted work")
        replayGate.signal()
        try drain(a)
        try session.select(.all, image: reference)
        expect(try snapshot(imageA) == snapshot(reference)
                && a.replayStatus == .cancelled(index: 0), "the accepted replay step drains once without restarting cancelled later steps")
        expect(try snapshot(imageA).pixels == beforeCancelledReplay.pixels && a.pendingWork == 0,
               "cancellation preserves pixels when the sole accepted command changes selection only")

        click(.record)
        let beforeFailure = try snapshot(imageA)
        a.scale(toWidth: 0, height: 19)
        click(.stop)
        try drain(a)
        expect(rowTexts().count == 1 && rowTexts().first?.contains("1. Failed:") == true
                && rowTexts().first?.contains("524288") == true && button(.replay)?.isEnabled == false,
               "a real native capture failure has visible failure text and cannot become a replayable partial recording")
        expect(errors == ["The new size must be between 1 and 524288 pixels."] && (try? snapshot(imageA)) == beforeFailure,
               "failure retains the original error channel and every native pixel/selection/history fact")
        click(.clear)
        expect(table.numberOfRows == 0 && (try? snapshot(imageA)) == beforeFailure,
               "the actual Clear button removes the failed log without editing the image")
        errors.removeAll()
        click(.record); a.select(.fromAlpha); click(.stop); try drain(a)
        let replacement = try session.pastePixels(imageA, pixels: pixels, at: .zero)
        try session.selectItems([replacement], kind: .layer, image: imageA)
        try a.reload()
        try drain(a) // The new target's visible layer row accepts another counted thumbnail read.
        let beforeRefusedReplay = try snapshot(imageA)
        click(.replay); try drain(a)
        if case .failed(let index, let reason) = a.replayStatus {
            expect(index == 0 && reason.contains("target")
                    && label("Recorder status")?.stringValue.contains("Replay failed at command 1:") == true,
                   "target refusal shows the exact failed replay command index and reason")
        } else { expect(false, "changed target refuses replay with indexed failure status") }
        expect((try? snapshot(imageA)) == beforeRefusedReplay,
               "target-refused replay queues no edit and preserves exact native state")
        let retainedAStatus = a.replayStatus
        current = b; windowB.window?.makeKeyAndOrderFront(nil)
        click(.record) // The visible controls still belong to A until this stale click is refused.
        expect(!b.recorder.isRecording && b.recorder.records.isEmpty && a.replayStatus == retainedAStatus
                && label("Recorder image")?.stringValue == b.name
                && label("Recorder status")?.stringValue.contains("active image changed") == true,
               "a stale A button retargets and refuses instead of recording into B without a fresh click")
        expect(try snapshot(imageA) == beforeRefusedReplay && snapshot(imageB) == untouchedB,
               "stale-target refusal preserves both documents' native states")
        click(.record); b.select(.all); click(.stop); try drain(b)
        expect(rowTexts() == ["1. Recorded: Select All"] && a.replayStatus == retainedAStatus,
               "a second explicit click records B only and displays B's command")

        var probe: RecorderPaletteController? = RecorderPaletteController(currentDocument: { current })
        probe?.retarget(to: b)
        weak var releasedProbe = probe
        probe = nil; spin(0.03)
        expect(releasedProbe == nil, "a secondary palette observer does not retain its controller")
        let closeGate = try hold(b)
        defer { closeGate.signal() }
        click(.record); b.scale(toWidth: 23, height: 17)
        windowB.window?.close()
        try require(wait { b.isClosing }, "closing window did not stop document admission")
        palette.reload()
        expect(RecorderPaletteAction.allCases.allSatisfy { button($0)?.isEnabled == false }
                && b.pendingWork == 1 && (try? session.info(imageB)) != nil,
               "closing disables every control while accepted native work remains counted and alive")
        closeGate.signal()
        try require(wait { b.pendingWork == 0 && (try? session.info(imageB)) == nil }, "accepted closing work did not drain")
        expect(b.recorder.records.count == 1 && b.recorder.pendingCount == 0,
               "accepted capture still settles before native close and leaves no reservation behind")
        current = nil; palette.retarget(to: nil)
        expect(table.numberOfRows == 0 && RecorderPaletteAction.allCases.allSatisfy { button($0)?.isEnabled == false },
               "final retarget removes the closed document and its observer from the visible palette")
    }
}
