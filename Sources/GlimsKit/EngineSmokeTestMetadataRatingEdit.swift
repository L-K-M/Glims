import AppKit

private struct MetadataRatingEditSnapshot: Equatable {
    let rating: [String]
    let artist: [String]
    let pixels: Data
    let width: Int
    let height: Int
    let origin: CGPoint
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
    let layers: [EngineSession.Layer]
    let selection: [Int32]
    let isDirty: Bool

    init(_ session: EngineSession, image: Int32) throws {
        rating = try session.metadataValues(image, tag: "Xmp.xmp.Rating")
        artist = try session.metadataValues(image, tag: "Exif.Image.Artist")
        let copied = try session.copyPixels(image, merged: true)
        pixels = copied.pixels; width = copied.width; height = copied.height; origin = copied.origin
        undo = try session.undoInfo(image)
        history = try session.history(image)
        layers = try session.layers(image)
        selection = try session.selectedLayers(image)
        isDirty = try session.info(image).isDirty
    }

    func preservesImageAndArtist(from original: Self) -> Bool {
        pixels == original.pixels && width == original.width && height == original.height
            && origin == original.origin && layers == original.layers && selection == original.selection
            && artist == original.artist
    }
}

@MainActor
private struct MetadataRatingEditForm {
    let window: NSWindow
    let popup: NSPopUpButton
    let original: NSTextView
    let apply: NSButton
    let cancel: NSButton
    let message: NSTextField
}

@MainActor
extension EngineSmokeTest {
    /// A separate hosted case: the original missing-action baseline is kept
    /// unchanged. Only public AppKit controls and independent native reads are
    /// used here; no production controller or editor access is required.
    static func exerciseMetadataRatingEdit(_ session: EngineSession, work: URL,
                                          documents: DocumentList) throws {
        let tag = "Xmp.xmp.Rating"
        var owners: [DocumentWindowController] = []
        var ownedDocuments: [ImageDocument] = []
        var ownedWindows: [NSWindow] = []
        var unmanagedImages: [Int32] = []
        var gates: [DispatchSemaphore] = []
        var heldFilter: Int32?
        var scenarioCompleted = false
        func all<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all($0, type) }
        }
        func view<T: NSView>(_ window: NSWindow?, _ label: String, _ type: T.Type) -> T? {
            all(window?.contentView, type).first { $0.accessibilityLabel() == label }
        }
        func remember(_ window: NSWindow) {
            if !ownedWindows.contains(where: { $0 === window }) { ownedWindows.append(window) }
        }
        func waitFor(_ description: String, _ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(15)
            while Date() < end {
                if condition() { return true }
                EngineSmokeTestHost.pumpEvents()
            }
            print("rating focus active=\(NSApp.isActive) main=\(NSApp.mainWindow?.windowNumber ?? -1) key=\(NSApp.keyWindow?.windowNumber ?? -1)")
            check(false, "Timed out: \(description)")
            return false
        }
        func settle() -> Bool {
            waitFor("rating counted work drains", {
                ownedDocuments.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy
            })
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            if !scenarioCompleted { check(false, "rating edit scenario stopped before all acceptance checks completed") }
            // A failed condition must never strand a worker behind a barrier.
            gates.forEach { $0.signal() }
            if let filter = heldFilter { try? session.abortFilter(filter) }
            var stopped = Set<ObjectIdentifier>()
            for owner in owners {
                owner.imageDocument.beginClosing()
                if owner.window?.isVisible == true { owner.window?.close() }
                owner.canvas.stopRendering { stopped.insert(ObjectIdentifier(owner)) }
            }
            _ = waitFor("rating owned renderers drain", { stopped.count == owners.count })
            check(stopped.count == owners.count, "rating edit teardown drains every owned renderer")
            for document in ownedDocuments where !gone(document.image) { document.closeImageWhenDrained() }
            let closed = waitFor("rating owned native images close", {
                ownedDocuments.allSatisfy { gone($0.image) } && !EngineActivity.shared.isBusy
            })
            check(closed, "rating edit teardown closes every owned native image with exact NOT_FOUND")
            for image in unmanagedImages { try? session.closeImage(image) }
            EngineSmokeTestHost.pumpEvents(for: 0.03)
            check(ownedWindows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil },
                  "rating edit teardown leaves no owned window, sheet or dialog visible")
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
        }
        func seed(width: Int, height: Int, variant: Int, rating: [String], artist: String) throws -> (Int32, Data) {
            let image = try session.newImage(width: width, height: height)
            unmanagedImages.append(image)
            var bytes: [UInt8] = []
            for y in 0..<height {
                for x in 0..<width {
                    bytes.append(UInt8(20 + (x * 19 + y * 7 + variant) % 210))
                    bytes.append(UInt8(30 + (x * 3 + y * 23 + variant * 2) % 200))
                    bytes.append(UInt8(40 + (x * 11 + y * 5 + variant * 3) % 190))
                    bytes.append(255)
                }
            }
            let pixels = Data(bytes)
            _ = try session.pastePixels(image, pixels: ClipboardImage(width: width, height: height,
                pixels: pixels, origin: .zero), at: .zero)
            try session.editMetadata(image, tag: tag, .set, values: rating)
            try session.editMetadata(image, tag: "Exif.Image.Artist", .set, values: [artist])
            return (image, pixels)
        }
        let (imageA, pixelsA) = try seed(width: 32, height: 20, variant: 7,
                                        rating: ["2.5"], artist: "Rating A witness")
        let (imageB, pixelsB) = try seed(width: 19, height: 13, variant: 31,
                                        rating: ["4"], artist: "Rating B witness")
        let capable = try [imageA, imageB].allSatisfy { image in
            let info = try session.metadataTagInfo(image, tag: tag)
            return info.present && info.valueKind == .single && !info.supportsMultiple
                && info.typeName == "XmpText" && info.formatPolicy.contains(.supportsSet)
                && info.formatPolicy.contains(.supportsRemove)
        }
        check(capable, "both loaded native Rating descriptors explicitly admit scalar XmpText SET and REMOVE")
        guard capable else { return }
        let originalA = try MetadataRatingEditSnapshot(session, image: imageA)
        let originalB = try MetadataRatingEditSnapshot(session, image: imageB)
        check(try originalA.pixels == pixelsA && originalB.pixels == pixelsB && originalA.rating == ["2.5"]
              && originalB.rating == ["4"] && !session.floatingSelection(imageA).isActive,
              "independent asymmetric image bytes and fractional/A versus canonical/B metadata are native fixture facts")
        for (image, name) in [(imageA, "Rating Edit A"), (imageB, "Rating Edit B")] {
            let document = try ImageDocument(session: session, image: image, name: name)
            ownedDocuments.append(document); documents.items.append(document)
            unmanagedImages.removeAll { $0 == image }
            let owner = DocumentWindowController(document: document)
            owners.append(owner); owner.showWindow(nil)
            if let window = owner.window { remember(window) }
        }
        let ownerA = owners[0], ownerB = owners[1]
        let documentA = ownedDocuments[0], documentB = ownedDocuments[1]
        guard let item = NSApp.mainMenu?.item(withTitle: "Image")?.submenu?.items.first(where: {
            $0.action == #selector(DocumentWindowController.showMetadata(_:))
        }), let windowA = ownerA.window, let windowB = ownerB.window else {
            return check(false, "rating edit has actual installed Metadata menu and two owned windows")
        }
        NSApp.activate(ignoringOtherApps: true)
        windowA.makeMain(); windowA.makeKeyAndOrderFront(nil)
        guard waitFor("rating host actually activates A", {
            NSApp.isActive && NSApp.mainWindow === windowA && NSApp.keyWindow === windowA
        }), settle() else { return }
        check(NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching && NSApp.isActive,
              "rating edit runs after real AppKit launch with a running active event host")
        check(ownerA.validateMenuItem(item), "installed Image Metadata menu admits the captured A document")

        func metadataPanel(_ owner: DocumentWindowController) -> NSWindow? {
            guard let window = owner.window else { return nil }
            if window.attachedSheet == nil {
                NSApp.activate(ignoringOtherApps: true)
                window.makeMain(); window.makeKeyAndOrderFront(nil)
                _ = NSApp.sendAction(item.action!, to: owner, from: item)
            }
            guard waitFor("owned Metadata panel becomes visible", {
                window.attachedSheet?.isVisible == true
            }), let panel = window.attachedSheet,
                  view(panel, "Metadata domain", NSPopUpButton.self) != nil else {
                return nil
            }
            remember(panel)
            return panel
        }
        func prepareRating(_ owner: DocumentWindowController, values: [String]) -> NSWindow? {
            guard settle(), let panel = metadataPanel(owner),
                  let domain = view(panel, "Metadata domain", NSPopUpButton.self),
                  let table = view(panel, "Metadata tag list", NSTableView.self),
                  let raw = view(panel, "Selected metadata value editor", NSTextView.self),
                  let launch = view(panel, "Edit XMP rating", NSButton.self) else { return nil }
            if domain.titleOfSelectedItem != "XMP" {
                domain.selectItem(withTitle: "XMP")
                if let action = domain.action { _ = NSApp.sendAction(action, to: domain.target, from: domain) }
            }
            guard settle() else { return nil }
            func row() -> Int? {
                (0..<table.numberOfRows).first {
                    table.dataSource?.tableView?(table, objectValueFor: table.tableColumns.first, row: $0) as? String == tag
                }
            }
            if values.isEmpty {
                guard let name = view(panel, "New tag name", NSTextField.self),
                      let add = view(panel, "Add tag", NSButton.self) else { return nil }
                name.stringValue = tag
                add.performClick(nil)
            } else {
                guard waitFor("Rating appears in the native tag table", { row() != nil }), let index = row() else { return nil }
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            guard waitFor("Rating selection and current descriptor finish through ordinary notifications", {
                launch.isEnabled && !launch.isHiddenOrHasHiddenAncestor
                    && raw.string == (values.first ?? "") && owner.imageDocument.pendingWork == 0
            }) else { return nil }
            return panel
        }
        func form(in panel: NSWindow) -> MetadataRatingEditForm? {
            guard let window = panel.attachedSheet,
                  let popup = view(window, "XMP rating value", NSPopUpButton.self),
                  let original = view(window, "Original XMP rating value", NSTextView.self),
                  let apply = view(window, "Apply XMP rating", NSButton.self),
                  let cancel = view(window, "Cancel XMP rating", NSButton.self),
                  let message = view(window, "XMP rating error", NSTextField.self) else { return nil }
            remember(window)
            return MetadataRatingEditForm(window: window, popup: popup, original: original,
                                          apply: apply, cancel: cancel, message: message)
        }
        func openForm(_ owner: DocumentWindowController, values: [String]) -> MetadataRatingEditForm? {
            guard let panel = prepareRating(owner, values: values), let window = owner.window,
                  let launch = view(panel, "Edit XMP rating", NSButton.self) else { return nil }
            NSApp.activate(ignoringOtherApps: true)
            window.makeMain(); panel.makeKeyAndOrderFront(nil)
            launch.performClick(nil)
            guard waitFor("typed Rating sheet is actually visible and key", {
                panel.attachedSheet?.isVisible == true && NSApp.keyWindow === panel.attachedSheet
            }), let result = form(in: panel) else { return nil }
            guard waitFor("typed Rating descriptor read settles", {
                owner.imageDocument.pendingWork == 0 && result.message.stringValue != "Reading…"
            }) else { return nil }
            return result
        }
        func choose(_ form: MetadataRatingEditForm, title: String) -> Bool {
            guard form.popup.itemTitles.contains(title), let action = form.popup.action else {
                check(false, "actual Rating popup exposes \(title)")
                return false
            }
            form.popup.selectItem(withTitle: title)
            return NSApp.sendAction(action, to: form.popup.target, from: form.popup)
        }
        func dismissed(_ form: MetadataRatingEditForm) -> Bool {
            waitFor("typed Rating form closes without late revival", {
                !form.window.isVisible && form.window.sheetParent == nil
            }) && settle()
        }
        func apply(_ form: MetadataRatingEditForm) -> Bool {
            guard waitFor("actual typed Rating Apply becomes enabled", { form.apply.isEnabled }) else { return false }
            form.apply.performClick(nil)
            return dismissed(form)
        }
        func setThroughDocument(_ values: [String], tag explicitTag: String = "Xmp.xmp.Rating") -> Bool {
            var outcome: Result<Void, Error>?
            documentA.editMetadata(explicitTag, .set, values: values) { outcome = $0 }
            guard waitFor("accepted document metadata edit completes", { outcome != nil }), settle() else { return false }
            if case .failure(let error)? = outcome {
                check(false, "document fixture edit refused: \(error)")
                return false
            }
            return true
        }

        guard let unknown = openForm(ownerA, values: ["2.5"]),
              let metadataA = windowA.attachedSheet else { return check(false, "actual Rating action opens its typed form") }
        check(unknown.window.sheetParent === metadataA && metadataA.sheetParent === windowA,
              "installed Rating action owns the actual nested form in captured A")
        check(unknown.original.string == "2.5" && unknown.popup.titleOfSelectedItem == "Choose a value",
              "fractional original stays exact with no implicit star or absence choice")
        let titles = ["Choose a value", "Not specified", "Unrated (0)", "Rejected (-1)",
                      "1 star", "2 stars", "3 stars", "4 stars", "5 stars"]
        check(unknown.popup.itemTitles == titles && !unknown.apply.isEnabled,
              "actual Rating popup has exactly the eight literal choices and unknown Apply is disabled")
        unknown.cancel.performClick(nil)
        guard dismissed(unknown) else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == originalA
              && MetadataRatingEditSnapshot(session, image: imageB) == originalB,
              "actual unknown Cancel preserves complete A/B native metadata, pixels, history and selection")
        check(documentA.pendingWork == 0 && metadataA.attachedSheet == nil && !unknown.window.isVisible,
              "unknown Cancel drains its read and leaves no typed form or accepted write")

        // Independent wire/title table; no production rating enum is an oracle.
        let choices: [(String, [String])] = [
            ("Not specified", []), ("Unrated (0)", ["0"]), ("Rejected (-1)", ["-1"]),
            ("1 star", ["1"]), ("2 stars", ["2"]), ("3 stars", ["3"]),
            ("4 stars", ["4"]), ("5 stars", ["5"])
        ]
        var current = ["2.5"]
        for (title, values) in choices {
            let before = try MetadataRatingEditSnapshot(session, image: imageA)
            guard let editor = openForm(ownerA, values: current), choose(editor, title: title), apply(editor) else { return }
            let after = try MetadataRatingEditSnapshot(session, image: imageA)
            check(after.rating == values && after.preservesImageAndArtist(from: originalA),
                  "actual \(title) choice stores its exact independent wire array and preserves image/unrelated metadata")
            check(after.undo.undoCount == before.undo.undoCount + 1 && after.undo.redoCount == 0
                  && after.history.rows.count == before.history.rows.count + 1,
                  "actual \(title) change creates exactly one native Undo")
            current = values
        }

        guard setThroughDocument([""]), let empty = openForm(ownerA, values: [""]) else { return }
        let beforeEmptyCancel = try MetadataRatingEditSnapshot(session, image: imageA)
        check(try empty.original.string.isEmpty && empty.popup.titleOfSelectedItem == "Choose a value"
              && !empty.apply.isEnabled && session.metadataTagInfo(imageA, tag: tag).present,
              "a present empty singleton stays distinct from absence and explicit zero in the real form")
        empty.cancel.performClick(nil)
        guard dismissed(empty) else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == beforeEmptyCancel,
              "Cancel preserves a present empty singleton byte-for-byte without history")

        guard let captured = openForm(ownerA, values: [""]), choose(captured, title: "3 stars") else { return }
        windowB.makeMain(); windowB.makeKeyAndOrderFront(nil)
        guard waitFor("B actually becomes main and key while A owns Rating", {
            NSApp.isActive && NSApp.mainWindow === windowB && NSApp.keyWindow === windowB
        }) else { return }
        check(NSApp.mainWindow === windowB && NSApp.keyWindow === windowB && captured.window.isVisible
              && captured.window.sheetParent === metadataA,
              "real launched AppKit makes B frontmost while A retains its captured Rating form")
        guard apply(captured) else { return }
        let afterCaptured = try MetadataRatingEditSnapshot(session, image: imageA)
        check(try afterCaptured.rating == ["3"] && afterCaptured.preservesImageAndArtist(from: originalA)
              && MetadataRatingEditSnapshot(session, image: imageB) == originalB,
              "Apply after genuine B focus changes only captured A and leaves B values/pixels/history identical")
        check(afterCaptured.undo.undoCount == beforeEmptyCancel.undo.undoCount + 1,
              "captured A Apply adds one native Undo despite front B")
        documentA.undo(); guard settle() else { return }
        let undone = try MetadataRatingEditSnapshot(session, image: imageA)
        check(undone.rating == [""] && undone.preservesImageAndArtist(from: originalA)
              && undone.undo.redoCount == 1,
              "counted document Undo restores the exact present empty value without manual reload")
        documentA.redo(); guard settle() else { return }
        check(try session.metadataValues(imageA, tag: tag) == ["3"] && session.undoInfo(imageA).redoCount == 0,
              "counted document Redo restores the exact captured rating through normal state notifications")

        let beforeNoop = try MetadataRatingEditSnapshot(session, image: imageA)
        guard let unchanged = openForm(ownerA, values: ["3"]), apply(unchanged) else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == beforeNoop,
              "identical typed SET is a complete native metadata/history no-op")
        guard let removal = openForm(ownerA, values: ["3"]), choose(removal, title: "Not specified"), apply(removal) else { return }
        let absent = try MetadataRatingEditSnapshot(session, image: imageA)
        check(try absent.rating.isEmpty && absent.undo.undoCount == beforeNoop.undo.undoCount + 1
              && !session.metadataTagInfo(imageA, tag: tag).present,
              "explicit Not specified removes the tag rather than storing zero and creates one Undo")
        guard let absentForm = openForm(ownerA, values: []) else { return }
        check(absentForm.popup.titleOfSelectedItem == "Not specified" && absentForm.original.string == "No value"
              && absentForm.apply.isEnabled,
              "the public absent-tag Add action opens actual absence without first storing an empty value")
        guard apply(absentForm) else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == absent,
              "typed REMOVE of an absent tag is a complete native history no-op")
        guard let zero = openForm(ownerA, values: []), choose(zero, title: "Unrated (0)"), apply(zero) else { return }
        check(try session.metadataValues(imageA, tag: tag) == ["0"] && session.metadataTagInfo(imageA, tag: tag).present
              && session.undoInfo(imageA).undoCount == absent.undo.undoCount + 1,
              "explicit Unrated stores present zero with one Undo after absence")
        let saved = work.appendingPathComponent("metadata-rating-edit.xcf")
        var saveComplete = false
        var saveError: Error?
        documentA.save(to: saved) { saveError = $0; saveComplete = true }
        guard waitFor("counted Rating XCF save completes", { saveComplete }), settle() else { return }
        let savedSize = (try? saved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        check(saveError == nil && savedSize > 0,
              "captured A saves a real XCF through its counted document service")
        let reopened = try session.openImage(path: saved.path)
        unmanagedImages.append(reopened)
        let restored = try MetadataRatingEditSnapshot(session, image: reopened)
        check(restored.rating == ["0"] && restored.artist == originalA.artist && restored.pixels == pixelsA
              && restored.width == originalA.width && restored.height == originalA.height,
              "independent XCF reopen preserves exact zero, unrelated metadata and asymmetric pixels")
        try session.closeImage(reopened); unmanagedImages.removeAll { $0 == reopened }

        guard let stale = openForm(ownerA, values: ["0"]), choose(stale, title: "2 stars") else { return }
        let version = documentA.stateVersion
        guard setThroughDocument(["Changed elsewhere"], tag: "Exif.Image.Artist") else { return }
        guard waitFor("normal document notifications invalidate the stale Rating form", {
            stale.message.stringValue.contains("document changed") && !stale.apply.isEnabled
        }) else { return }
        check(documentA.stateVersion != version && stale.popup.titleOfSelectedItem == "2 stars"
              && stale.message.stringValue.contains("document changed"),
              "ordinary document notifications refuse stale Apply while preserving its selected draft")
        let staleBefore = try MetadataRatingEditSnapshot(session, image: imageA)
        stale.apply.performClick(nil)
        guard settle() else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == staleBefore && staleBefore.rating == ["0"],
              "stale Apply cannot overwrite exact rating or add native history")
        stale.cancel.performClick(nil); guard dismissed(stale) else { return }

        guard let busy = openForm(ownerA, values: ["0"]), choose(busy, title: "1 star"),
              let drawable = documentA.activeLayer else { return }
        let busyBefore = try MetadataRatingEditSnapshot(session, image: imageA)
        heldFilter = try session.beginFilter(image: imageA, drawable: drawable, operation: "gegl:gaussian-blur")
        busy.apply.performClick(nil)
        guard waitFor("native BUSY reports a persistent Rating error", {
            !busy.message.stringValue.isEmpty && busy.message.stringValue != "Reading…"
                && busy.message.stringValue != "Applying…" && documentA.pendingWork == 0
        }) else { return }
        check(try busy.window.isVisible && busy.popup.titleOfSelectedItem == "1 star"
              && session.metadataValues(imageA, tag: tag) == ["0"]
              && session.undoInfo(imageA) == busyBefore.undo,
              "actual native BUSY preserves the chosen Rating draft and original metadata/history")
        if let filter = heldFilter { try session.abortFilter(filter); heldFilter = nil }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == busyBefore,
              "aborting the independent native preview restores all pre-refusal image and metadata state")
        guard apply(busy) else { return }
        check(try session.metadataValues(imageA, tag: tag) == ["1"]
              && session.undoInfo(imageA).undoCount == busyBefore.undo.undoCount + 1,
              "the actual Rating form can retry successfully after native BUSY ends")

        // Prepare the public row first; only its subsequent typed descriptor
        // read is held. No queue sync or private controller access is used.
        guard let readPanel = prepareRating(ownerA, values: ["1"]),
              let readLaunch = view(readPanel, "Edit XMP rating", NSButton.self) else { return }
        let beforeReadCancel = try MetadataRatingEditSnapshot(session, image: imageA)
        let readGate = DispatchSemaphore(value: 0); gates.append(readGate)
        documentA.inputQueue.async { readGate.wait() }
        readLaunch.performClick(nil)
        guard waitFor("held descriptor form is visible", { readPanel.attachedSheet?.isVisible == true }),
              let pendingRead = form(in: readPanel) else { return }
        check(documentA.pendingWork > 0 && pendingRead.message.stringValue == "Reading…" && !pendingRead.apply.isEnabled,
              "actual typed descriptor read is counted before its held worker starts")
        pendingRead.cancel.performClick(nil)
        guard waitFor("Cancel dismisses a held descriptor form", {
            !pendingRead.window.isVisible && readPanel.attachedSheet == nil
        }) else { return }
        check(documentA.pendingWork > 0 && readPanel.attachedSheet == nil,
              "actual Cancel closes the form while its accepted descriptor read remains counted")
        readGate.signal()
        guard settle() else { return }
        check(try MetadataRatingEditSnapshot(session, image: imageA) == beforeReadCancel
              && readPanel.attachedSheet == nil && !pendingRead.window.isVisible,
              "late descriptor delivery after Cancel drains without metadata change or sheet revival")

        guard let closing = openForm(ownerB, values: ["4"]), choose(closing, title: "5 stars") else { return }
        let unchangedA = try MetadataRatingEditSnapshot(session, image: imageA)
        let writeGate = DispatchSemaphore(value: 0); gates.append(writeGate)
        guard let applyAction = closing.apply.action else {
            return check(false, "actual held Rating Apply exposes its public action")
        }
        // Dispatch the actual button action without performClick's highlight
        // run loop, so the following barrier precedes the queued read's ack.
        _ = NSApp.sendAction(applyAction, to: closing.apply.target, from: closing.apply)
        // This barrier follows Apply's fresh descriptor read. Its main-actor
        // callback accepts exactly one write behind the held barrier.
        documentB.inputQueue.async { writeGate.wait() }
        guard waitFor("fresh descriptor admits the held Rating write", {
            closing.message.stringValue == "Applying…" && documentB.pendingWork > 0
        }) else { return }
        check(!closing.apply.isEnabled && !closing.cancel.isEnabled && documentB.pendingWork > 0,
              "actual Rating write stays counted and its form cannot resubmit or Cancel after admission")
        var drainedRating: Result<[String], Error>?
        documentB.readMetadataValues(tag) { drainedRating = $0 }
        windowB.close() // Public AppKit close runs the real windowWillClose drain.
        check(documentB.isClosing && documentB.pendingWork > 0 && !gone(imageB),
              "owned window close fences new work but keeps the native image alive for accepted Rating input")
        writeGate.signal()
        guard waitFor("accepted Rating write/read and native close all drain", {
            drainedRating != nil && documentB.pendingWork == 0 && gone(imageB)
        }) else { return }
        let observed: [String]?
        if case .success(let values)? = drainedRating { observed = values } else { observed = nil }
        check(try observed == ["5"] && !closing.window.isVisible && windowB.attachedSheet == nil
              && MetadataRatingEditSnapshot(session, image: imageA) == unchangedA,
              "accepted close-time write completes before counted read/native destruction and never revives UI or alters A")
        scenarioCompleted = true
    }
}
