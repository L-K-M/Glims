import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInkEdits(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "ink-edits: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "InkEditsSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool, timeout: TimeInterval = 15, _ message: String) throws {
            let limit = Date().addingTimeInterval(timeout)
            while !condition() && Date() < limit { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            EngineSmokeTestHost.pumpEvents()
            try require(condition(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Image work did not drain")
        }
        func render(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "InkEditsSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing rendered pixels"])
            }
            return data
        }
        func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
        func field(_ label: String, in root: NSView) throws -> NSTextField {
            let fields = descendants(of: root).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == label }
            try require(fields.count == 1, "Exactly one field '\(label)' exists")
            return fields[0]
        }
        func button(_ title: String, in root: NSView) throws -> NSButton {
            let buttons = descendants(of: root).compactMap { $0 as? NSButton }.filter { $0.title == title }
            try require(buttons.count == 1, "Exactly one button '\(title)' exists")
            return buttons[0]
        }
        func setDraft(_ field: NSTextField, _ text: String, in window: NSWindow) throws {
            window.makeFirstResponder(field)
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Field editor is active for '\(field.accessibilityLabel() ?? "?")'")
            if let editor = field.currentEditor() as? NSTextView { editor.string = text }
            field.stringValue = text
        }
        func hasOpenSheet(_ window: NSWindow?) -> Bool { window?.attachedSheet != nil }
        func saveSheetArtifact(_ view: NSView, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            do {
                try require(!directory.isEmpty, "Artifact directory is not empty")
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "InkEditsSmoke", code: 8,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot capture sheet content"])
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw NSError(domain: "InkEditsSmoke", code: 9,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot encode sheet PNG"])
                }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
                expect(true, "saved actual sheet artifact \(name)")
            } catch {
                expect(false, "sheet artifact \(name): \(error)")
                throw error
            }
        }

        var controllers: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var oldErrorHandlers: [(ImageDocument, ((String) -> Void)?)] = []
        var unexpectedErrors: [String] = []
        var bareDocuments: [ImageDocument] = []

        defer {
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            for document in bareDocuments {
                document.onRecorderChange = nil
                if !document.isClosing { document.closeImageWhenDrained() }
            }
            let owned = controllers.map(\.imageDocument) + bareDocuments
            do { try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil } },
                          timeout: 20, "Owned ink-edit documents close") }
            catch { expect(false, "cleanup drains all owned documents: \(error)") }
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "cleanup leaves no owned sheet")
            expect(unexpectedErrors.isEmpty, "fixture and cleanup produce no unexpected document errors")
            for (document, handler) in oldErrorHandlers { document.onError = handler }
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            nativeOnly.forEach { try? session.closeImage($0) }
        }

        func attach(_ id: Int32, name: String) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: id, name: name)
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            oldErrorHandlers.append((document, document.onError))
            document.onError = { unexpectedErrors.append($0) }
            controllers.append(controller)
            nativeOnly.removeAll { $0 == id }
            documents.items.append(document)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            return controller
        }

        guard let cmykProfile = NSColorSpace.genericCMYK.iccProfileData, let menuRoot = NSApp.mainMenu else {
            throw NSError(domain: "InkEditsSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing CMYK profile or app menu"])
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        NativeFilterMenus.install(operations, in: menuRoot)
        func menuItem(_ operation: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if (item.representedObject as? NativeFilterCommand)?.operation.name == operation { return item }
                if let submenu = item.submenu, let found = menuItem(operation, in: submenu) { return found }
            }
            return nil
        }
        func menuItem(action: Selector, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let submenu = item.submenu, let found = menuItem(action: action, in: submenu) { return found }
            }
            return nil
        }
        guard let linear = menuItem("gegl:invert-linear", in: menuRoot), let linearAction = linear.action,
              let gamma = menuItem("gegl:invert-gamma", in: menuRoot) else {
            throw NSError(domain: "InkEditsSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing actual linear/perceptual Invert menu items"])
        }
        // The native catalog deliberately excludes Gaussian Blur: MainMenu
        // installs its dedicated selector instead of a NativeFilterCommand.
        guard let blur = menuItem(action: #selector(DocumentWindowController.gaussianBlur(_:)), in: menuRoot) else {
            throw NSError(domain: "InkEditsSmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing dedicated Gaussian Blur menu item"])
        }
        func unsupportedRow(_ document: ImageDocument) -> Bool {
            guard document.recorder.records.count == 1,
                  case .failure(let reason) = document.recorder.records[0].resolution else { return false }
            return reason.contains("Ink-channel") && reason.contains("Recorder")
        }
        func newImage(_ mode: EngineSession.ColorMode, _ component: EngineSession.ColorComponent) throws -> Int32 {
            if mode == .cmyk {
                return try session.newCmykImage(width: 32, height: 24, component: component, profileICC: cmykProfile)
            }
            return try session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
        }
        let cases: [(String, EngineSession.ColorMode, EngineSession.ColorComponent)] = [
            ("CMYK u8", .cmyk, .u8), ("CMYK u16", .cmyk, .u16), ("CMYK float", .cmyk, .float),
            ("Multichannel u8", .multichannel, .u8), ("Multichannel u16", .multichannel, .u16), ("Multichannel float", .multichannel, .float)
        ]

        for (name, mode, component) in cases {
            let image = try newImage(mode, component)
            nativeOnly.append(image)
            let controller = try attach(image, name: name)
            let document = controller.imageDocument
            let window = try { () throws -> NSWindow in try require(controller.window != nil, "\(name): window exists"); return controller.window! }()
            try require(document.channels.count >= 2, "\(name): has selectable ink channels")
            guard let originalChannel = document.activeChannel,
                  let otherChannel = document.channels.first(where: { $0.id != originalChannel && !$0.isQuickMask })?.id else {
                throw NSError(domain: "InkEditsSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing original or alternate ink channel"])
            }
            let originalPixels = try render(image)
            let originalHistory = document.undoInfo.undoCount

            controller.fill(nil)
            try wait({ hasOpenSheet(window) }, "\(name): Fill opens attached sheet")
            let sheet = try { () throws -> NSWindow in try require(window.attachedSheet != nil, "\(name): sheet attached"); return window.attachedSheet! }()
            let content = try { () throws -> NSView in try require(sheet.contentView != nil, "\(name): sheet content exists"); return sheet.contentView! }()
            let amount = try field("Ink amount, percent", in: content)
            let opacity = try field("Fill opacity, percent", in: content)
            let message = try field("Fill validation message", in: content)
            let ink = try button("Ink", in: content)
            let paper = try button("Paper", in: content)
            let fill = try button("Fill", in: content)
            let cancel = try button("Cancel", in: content)
            if mode == .cmyk && component == .u8 {
                try saveSheetArtifact(content, name: "ink-fill-cmyk-u8-initial.png")
            }

            if component == .u8 { try document.startRecording() }
            for (badAmount, badOpacity) in [("NaN", "100"), ("101", "100"), ("100", "101")] {
                try setDraft(amount, badAmount, in: sheet)
                try setDraft(opacity, badOpacity, in: sheet)
                fill.performClick(nil)
                try wait({ hasOpenSheet(window) && !message.stringValue.isEmpty }, "\(name): invalid fill rejected")
                expect(try render(image) == originalPixels, "\(name): invalid fill preserves pixels")
                expect(document.undoInfo.undoCount == originalHistory, "\(name): invalid fill preserves history")
                expect(document.pendingWork == 0 && !EngineActivity.shared.isBusy, "\(name): invalid fill queues no work")
                if mode == .cmyk && component == .u8 && badAmount == "NaN" {
                    try saveSheetArtifact(content, name: "ink-fill-cmyk-u8-invalid.png")
                }
            }
            paper.performClick(nil); expect(amount.stringValue == "0", "\(name): Paper preset sets 0% ink")
            ink.performClick(nil); expect(amount.stringValue == "100", "\(name): Ink preset sets 100% ink")

            document.selectChannel(otherChannel)
            try drain(document)
            try setDraft(amount, "50", in: sheet); try setDraft(opacity, "100", in: sheet)
            fill.performClick(nil)
            try wait({ hasOpenSheet(window) && message.stringValue.contains("original ink channel") }, "\(name): captured target change reports its reason and keeps sheet open")
            expect(try render(image) == originalPixels, "\(name): retarget refusal preserves pixels")
            expect(document.undoInfo.undoCount == originalHistory, "\(name): retarget refusal preserves history")
            expect(document.recorder.pendingCount == 0, "\(name): retarget refusal leaves no reservation")
            document.selectChannel(originalChannel)
            try drain(document)
            cancel.performClick(nil)
            try wait({ !hasOpenSheet(window) }, "\(name): Cancel closes sheet")
            expect(try render(image) == originalPixels, "\(name): cancel preserves pixels")
            expect(document.undoInfo.undoCount == originalHistory, "\(name): cancel preserves history")
            if component == .u8 {
                var refusals: [String] = [], refusalCompletions = 0
                let handler = document.onError
                document.onError = { refusals.append($0) }
                let accepted = document.editInk(.clear, channel: otherChannel) { result in
                    if case .failure = result { refusalCompletions += 1 }
                }
                document.onError = handler
                expect(!accepted && refusalCompletions == 1 && refusals.count == 1,
                       "\(name): wrong explicit target refuses before admission")
                expect(document.recorder.pendingCount == 0 && document.recorder.records.isEmpty, "\(name): cancellations/admission refusals add no Recorder rows")
                try document.stopRecording()
            }

            controller.fill(nil)
            try wait({ hasOpenSheet(window) }, "\(name): Fill reopens for valid edit")
            let sheet2 = window.attachedSheet!
            let content2 = sheet2.contentView!
            try setDraft(try field("Ink amount, percent", in: content2), "50", in: sheet2)
            try setDraft(try field("Fill opacity, percent", in: content2), "100", in: sheet2)
            let fill2 = try button("Fill", in: content2)
            fill2.performClick(nil)
            try wait({ !hasOpenSheet(window) }, "\(name): valid Fill closes sheet")
            try drain(document)
            let filled = try render(image)
            expect(filled != originalPixels, "\(name): 50% ink fill visibly changes pixels")
            expect(document.undoInfo.undoCount == originalHistory + 1, "\(name): valid Fill creates exactly one Undo")

            document.undo(); try drain(document)
            expect(try render(image) == originalPixels, "\(name): Undo restores original pixels after Fill")
            document.redo(); try drain(document)
            expect(try render(image) == filled, "\(name): Redo restores filled pixels")

            if component == .u8 { controller.clearPixels(nil) } else { controller.deleteBackward(nil) }
            try drain(document)
            expect(try render(image) == originalPixels, "\(name): clear/delete returns to original paper")
            expect(document.undoInfo.undoCount == originalHistory + 2, "\(name): clear/delete adds one Undo")

            expect(controller.validateMenuItem(linear), "\(name): linear invert enabled for ink channel")
            expect(!controller.validateMenuItem(gamma), "\(name): gamma invert disabled for ink channel")
            expect(!controller.validateMenuItem(blur), "\(name): blur disabled for ink channel")
            let beforeLinear = try render(image)
            expect(NSApp.sendAction(linearAction, to: controller, from: linear), "\(name): actual linear Invert action is delivered")
            try drain(document)
            let afterLinear = try render(image)
            expect(afterLinear != beforeLinear, "\(name): linear invert changes pixels without panel")
            expect(!hasOpenSheet(window) && controller.previewPanel == nil, "\(name): linear invert opens no panel")
            expect(document.undoInfo.undoCount == originalHistory + 3, "\(name): linear invert adds one Undo")
            document.undo(); try drain(document)
            expect(try render(image) == beforeLinear, "\(name): Undo restores before linear invert")
            document.redo(); try drain(document)
            expect(try render(image) == afterLinear, "\(name): Redo restores linear invert")

            if component == .u8 {
                // Two separate admission seams: after reservation and at the first
                // busy-state notification, before perform() returns to its caller.
                for stopOnBusy in [false, true] {
                    let pixelsBefore = try render(image), undoBefore = document.undoInfo.undoCount
                    let oldRecorder = document.onRecorderChange, oldState = document.onStateChange
                    var stopped = false, stopErrors: [String] = []
                    try document.startRecording()
                    func stopAtBoundary(_ ready: Bool) {
                        guard ready, !stopped else { return }
                        stopped = true
                        expect(document.pendingWork >= 1, "\(name): accepted edit owns a work count at Stop")
                        do { try document.stopRecording() } catch { stopErrors.append(String(describing: error)) }
                    }
                    document.onRecorderChange = { oldRecorder?(); if !stopOnBusy { stopAtBoundary(document.recorder.pendingCount == 1) } }
                    document.onStateChange = { oldState?(); if stopOnBusy { stopAtBoundary(EngineActivity.shared.isBusy) } }
                    defer { document.onRecorderChange = oldRecorder; document.onStateChange = oldState }
                    let settings = EngineSession.InkEdit(operation: .fill, intensity: stopOnBusy ? 0.75 : 0.25, opacity: 1)
                    let accepted = document.editInk(settings, channel: originalChannel)
                    expect(accepted && stopped, "\(name): Stop observes the \(stopOnBusy ? "busy" : "reservation") admission boundary")
                    try drain(document)
                    document.onRecorderChange = oldRecorder; document.onStateChange = oldState
                    expect(stopErrors.isEmpty && !document.recorder.isRecording && document.recorder.pendingCount == 0,
                           "\(name): Stop settles without reservation or callback errors")
                    expect(unsupportedRow(document), "\(name): accepted ink edit retains exactly one explicit unsupported Recorder row")
                    expect(try render(image) != pixelsBefore && document.undoInfo.undoCount == undoBefore + 1,
                           "\(name): accepted edit still changes pixels with one Undo after Stop")
                }

                // Restart at the same busy observer boundary. The already
                // accepted old edit must never acquire a row in the new epoch.
                let epochPixelsBefore = try render(image), epochUndoBefore = document.undoInfo.undoCount
                let epochState = document.onStateChange
                var restarted = false, restartErrors: [String] = []
                try document.startRecording()
                document.onStateChange = {
                    epochState?()
                    guard EngineActivity.shared.isBusy, !restarted else { return }
                    restarted = true
                    expect(document.pendingWork >= 1, "\(name): old edit owns counted work before Stop/Start")
                    do { try document.stopRecording(); try document.startRecording() }
                    catch { restartErrors.append(String(describing: error)) }
                }
                defer { document.onStateChange = epochState }
                let oldEpochAccepted = document.editInk(.init(operation: .fill, intensity: 0.5, opacity: 1), channel: originalChannel)
                expect(oldEpochAccepted && restarted, "\(name): busy observer starts a new recording epoch during accepted work")
                try drain(document)
                document.onStateChange = epochState
                expect(restartErrors.isEmpty && document.recorder.isRecording, "\(name): Stop/Start leaves the new epoch recording")
                expect(document.recorder.pendingCount == 0 && document.recorder.records.isEmpty,
                       "\(name): old accepted edit never appears in the new recording epoch")
                expect(try render(image) != epochPixelsBefore && document.undoInfo.undoCount == epochUndoBefore + 1,
                       "\(name): old edit still completes once despite the recording restart")
                let newEpochAccepted = document.editInk(.init(operation: .fill, intensity: 0.125, opacity: 1), channel: originalChannel)
                expect(newEpochAccepted, "\(name): new epoch accepts its own subsequent edit")
                if document.recorder.isRecording { try document.stopRecording() }
                try drain(document)
                expect(document.recorder.pendingCount == 0 && unsupportedRow(document),
                       "\(name): new epoch contains only its own explicit unsupported row")

                // Separate bare ImageDocument accepted edit -> Close drain.
                let bareImage = try newImage(mode, .u8)
                nativeOnly.append(bareImage)
                let bare = try ImageDocument(session: session, image: bareImage, name: "\(name) bare")
                nativeOnly.removeAll { $0 == bareImage }
                bareDocuments.append(bare)
                guard let bareChannel = bare.activeChannel else { throw NSError(domain: "InkEditsSmoke", code: 6) }
                let bareBefore = try render(bareImage), bareUndo = bare.undoInfo.undoCount
                var beforeClosePixels: Data?, beforeCloseUndo: Int?
                var bareErrors: [String] = []
                var closeRequests = 0
                var closeCompletions = 0
                var originalCompletions = 0
                var originalFailures = 0
                bare.onError = { bareErrors.append($0) }
                try bare.startRecording()
                let oldBareChange = bare.onRecorderChange
                bare.onRecorderChange = { [weak bare] in
                    guard let bare, closeRequests == 0, bare.recorder.pendingCount == 1 else { return }
                    closeRequests += 1
                    bare.closeImageWhenDrained { closeCompletions += 1 }
                }
                let bareAccepted = bare.editInk(.invert, channel: bareChannel) { result in
                    originalCompletions += 1
                    if case .failure = result { originalFailures += 1 }
                    else {
                        beforeClosePixels = try? render(bareImage)
                        beforeCloseUndo = (try? session.undoInfo(bareImage))?.undoCount
                    }
                }
                expect(bareAccepted, "\(name): bare edit accepted before close drain")
                expect(bare.isClosing && bare.pendingWork >= 1, "\(name): accepted bare edit holds close/pending work")
                try wait({ closeCompletions == 1 }, "\(name): bare close drains")
                bare.onRecorderChange = oldBareChange
                expect(closeRequests == 1 && closeCompletions == 1, "\(name): bare close callback runs exactly once")
                expect(originalCompletions == 1 && originalFailures == 0, "\(name): original bare completion succeeds exactly once")
                expect(beforeClosePixels != nil && beforeClosePixels != bareBefore && beforeCloseUndo == bareUndo + 1,
                       "\(name): accepted edit is readable before close with changed pixels and one Undo")
                expect(bareErrors.isEmpty, "\(name): accepted edit and close produce no live errors")
                var refusalCompletions = 0
                let secondAccepted = bare.editInk(.clear, channel: bareChannel) { result in
                    if case .failure = result { refusalCompletions += 1 }
                }
                expect(!secondAccepted && refusalCompletions == 1 && bareErrors.count == 1,
                       "\(name): post-close edit refuses once without native work")
                expect(unsupportedRow(bare), "\(name): Close preserves one unsupported row and refusal adds none")
                expect((try? session.info(bareImage)) == nil, "\(name): bare native handle absent after close")
                expect(bare.pendingWork == 0 && bare.recorder.pendingCount == 0, "\(name): bare close leaves zero pending work/reservations")
                bare.onError = nil

            }
            controller.closeDiscardingChanges()
            try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil }, "\(name): window and native image close")
        }
    }
}
