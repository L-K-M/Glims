import AppKit
import RigiUI

private struct ChannelMenuNativeState: Equatable {
    let channels: [EngineSession.Channel]
    let selected: [Int32]
    let pixels: Data
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let history: EngineSession.UndoInfo
}

private struct ChannelMenuMask: Equatable {
    let width: Int
    let height: Int
    let bytes: Data
}

@MainActor
private final class ChannelMenuSmokeHost: NSObject, NSApplicationDelegate {
    var result: Int32 = 1
    var completed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(#selector(runChecks(_:)), with: nil, afterDelay: 0)
    }
    @objc private func runChecks(_ unused: Any?) {
        result = EngineSmokeTest.run()
        completed = true
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }
}

@MainActor
extension EngineSmokeTest {
    static func runHostedChannelMenus() -> Int32 {
        let app = NSApplication.shared
        guard !app.isRunning, app.delegate == nil, !NSRunningApplication.current.isFinishedLaunching else {
            print("FAIL channel menus require their own unlaunched AppKit host")
            return 1
        }
        let previousPolicy = app.activationPolicy()
        guard app.setActivationPolicy(.regular) else { return 1 }
        let host = ChannelMenuSmokeHost()
        app.delegate = host
        defer { app.delegate = nil; _ = app.setActivationPolicy(previousPolicy) }
        app.run()
        return host.completed ? host.result : 1
    }

    /// One existing smoke session. The host starts AppKit before run() starts
    /// the engine; this fixture never creates a second native engine.
    static func exerciseChannelMenus(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "channel menus: \(message)")
        }
        func pump() {
            let end = Date().addingTimeInterval(0.01)
            while Date() < end, let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: end)
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(15)
            while !condition() && Date() < end { pump() }
            return condition()
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "ChannelMenuFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "accepted channel work did not drain")
        }
        func state(_ image: Int32) throws -> ChannelMenuNativeState {
            ChannelMenuNativeState(channels: try session.channels(image),
                selected: try session.selectedItems(.channel, image: image),
                pixels: try session.copyPixels(image, merged: true).pixels,
                selection: try session.selectionBounds(image: image),
                outline: try session.selectionOutline(image: image), history: try session.undoInfo(image))
        }
        func thumbnail(_ channel: Int32, image: Int32) throws -> ChannelMenuMask {
            guard let rendered = try session.drawableThumbnail(channel, image: image, maxSize: 32),
                  let bytes = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "ChannelMenuFixture", code: 2)
            }
            return ChannelMenuMask(width: rendered.width, height: rendered.height, bytes: bytes)
        }
        // Read a full-size public RGBA thumbnail of the selection through a
        // duplicate: an oracle cannot add channels/Undo in the tested image.
        // This covers all spatial samples at the facade's thumbnail precision,
        // not the native selection buffer's raw floating-point precision.
        func selectionMask(_ image: Int32) throws -> ChannelMenuMask {
            let copy = try session.duplicateImage(image)
            defer { try? session.closeImage(copy) }
            let channel = try session.channelFromSelection(copy, name: "Selection oracle")
            return try thumbnail(channel, image: copy)
        }
        func descendants<T: NSView>(_ view: NSView?, _ type: T.Type) -> [T] {
            guard let view else { return [] }
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
        }
        func button(_ title: String, on controller: DocumentWindowController) -> NSButton? {
            descendants(controller.window?.attachedSheet?.contentView, NSButton.self).first { $0.title == title }
        }
        func field(_ label: String, on controller: DocumentWindowController) -> NSTextField? {
            descendants(controller.window?.attachedSheet?.contentView, NSTextField.self).first { $0.accessibilityLabel() == label }
        }

        var windows: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var gates: [DispatchSemaphore] = []
        let palette = ChannelsPaletteController()
        defer {
            gates.forEach { $0.signal() }
            palette.retarget(to: nil)
            for window in windows {
                if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet, returnCode: .abort) }
                if !window.closeStarted { window.closeDiscardingChanges() }
            }
            let closed = wait { windows.allSatisfy { (try? session.info($0.imageDocument.image)) == nil } }
            expect(closed && windows.allSatisfy { $0.imageDocument.pendingWork == 0 }, "owned windows drain before native shutdown")
            expect(windows.allSatisfy { $0.window?.attachedSheet == nil }, "teardown leaves no owned sheet")
            documents.items.removeAll { candidate in windows.contains { $0.imageDocument === candidate } }
            nativeOnly.forEach { try? session.closeImage($0) }
            print("     channel-menu checks: \(checks)")
        }
        func make(_ name: String) throws -> DocumentWindowController {
            let image = try session.newImage(width: 32, height: 24)
            nativeOnly.append(image)
            let document = try ImageDocument(session: session, image: image, name: name)
            let window = DocumentWindowController(document: document)
            windows.append(window)
            nativeOnly.removeAll { $0 == image }
            documents.items.append(document)
            window.showWindow(nil)
            return window
        }
        let a = try make("Channel Menu A"), b = try make("Channel Menu B")
        let doc = a.imageDocument, other = b.imageDocument
        let image = doc.image
        let reference = try session.newImage(width: 32, height: 24)
        nativeOnly.append(reference)
        var sourceOptions = EngineSession.SelectOptions()
        sourceOptions.feather = 0.9
        let sourceShape = EngineSession.SelectShape.rectangle(CGRect(x: 2, y: 3, width: 12, height: 11))
        try session.select(sourceShape, image: image, options: sourceOptions)
        let c1 = try session.channelFromSelection(image, name: "Left source")
        try session.select(.ellipse(CGRect(x: 13, y: 8, width: 14, height: 12)), image: image)
        let c2 = try session.channelFromSelection(image, name: "Right source")
        try session.select(sourceShape, image: reference, options: sourceOptions)
        let refChannel = try session.channelFromSelection(reference, name: "Independent source")
        try session.select(.rectangle(CGRect(x: 1, y: 1, width: 5, height: 5)), image: other.image)
        _ = try session.channelFromSelection(other.image, name: "B control")
        try doc.reload(); try other.reload()
        try drain(doc); try drain(other)
        let untouchedB = try state(other.image)
        let sourceC1 = try thumbnail(c1, image: image), sourceC2 = try thumbnail(c2, image: image)
        expect(sourceC1 != sourceC2 && sourceC1.width == 32 && sourceC1.height == 24,
               "independent asymmetric full-size channel masks differ")
        guard let imageMenu = NSApp.mainMenu?.item(withTitle: "Image")?.submenu?.item(withTitle: "Channels")?.submenu,
              let selectMenu = NSApp.mainMenu?.item(withTitle: "Select")?.submenu?.item(withTitle: "From Channel")?.submenu,
              let attributes = imageMenu.items.first(where: { $0.action == Selector(("channelAttributesMenu:")) }),
              let duplicate = imageMenu.items.first(where: { $0.action == Selector(("duplicateChannelMenu:")) }),
              let delete = imageMenu.items.first(where: { $0.action == Selector(("deleteChannelMenu:")) }),
              let layers = imageMenu.items.first(where: { $0.action == Selector(("returnToLayersMenu:")) }) else {
            expect(false, "actual main menus expose channel actions")
            return
        }
        let modes = selectMenu.items
        try require(modes.count == 4 && modes.map(\.tag) == [0, 1, 2, 3], "selection mode menu identity differs")
        let savedItems = [attributes, duplicate, delete] + modes
        func send(_ item: NSMenuItem, to controller: DocumentWindowController? = nil) {
            if let action = item.action { _ = NSApp.sendAction(action, to: controller, from: item) }
        }
        func refuseSaved() { savedItems.forEach { send($0, to: a) } }
        func focus(_ window: DocumentWindowController) throws {
            window.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try require(wait { NSApp.mainWindow === window.window }, "real AppKit main document did not settle")
        }
        doc.selectChannel(c1); try drain(doc); try focus(a)
        expect(savedItems.allSatisfy { a.validateMenuItem($0) } && a.validateMenuItem(layers), "actual items admit one settled saved channel")

        let beforeCancel = try state(image)
        send(attributes)
        try require(wait { button("Cancel", on: a) != nil }, "main Channel Attributes did not open its owned sheet")
        expect(field("Channel name", on: a)?.stringValue == "Left source", "main Attributes captures its selected saved channel")
        let originalSheet = a.window?.attachedSheet
        expect(savedItems.allSatisfy { !a.validateMenuItem($0) } && !a.validateMenuItem(layers),
               "an attached channel sheet disables all main channel actions")
        refuseSaved(); send(layers, to: a)
        expect(try state(image) == beforeCancel && a.window?.attachedSheet === originalSheet,
               "direct actions cannot replace the sheet or mutate its image")
        field("Channel name", on: a)?.stringValue = "Cancelled name"
        button("Cancel", on: a)?.performClick(nil)
        try require(wait { a.window?.attachedSheet == nil }, "channel attributes Cancel did not dismiss")
        expect(try state(image) == beforeCancel && state(other.image) == untouchedB, "Cancel preserves both native images and history")

        doc.selectChannel(c2); try drain(doc)
        palette.retarget(to: doc); try drain(doc)
        let attributesHistory = try session.undoInfo(image)
        palette.perform(.editChannel(c1))
        try require(wait { button("Apply", on: a) != nil }, "clicked-row Attributes did not open")
        expect(field("Channel name", on: a)?.stringValue == "Left source", "context Attributes uses C1 while C2 is selected")
        field("Channel name", on: a)?.stringValue = "Renamed left"
        field("Overlay opacity, percent", on: a)?.stringValue = NumberFormatter.localizedString(from: NSNumber(value: 37.5), number: .decimal)
        try focus(b)
        expect(NSApp.mainWindow === b.window && b.window?.attachedSheet == nil, "B is genuinely front while A owns the captured channel sheet")
        button("Apply", on: a)?.performClick(nil)
        try require(wait { a.window?.attachedSheet == nil }, "channel Apply did not dismiss")
        try drain(doc)
        let changed = try session.channels(image)
        expect(changed.first { $0.id == c1 }?.name == "Renamed left"
            && abs((changed.first { $0.id == c1 }?.opacity ?? -1) - 0.375) < 0.001
            && changed.first { $0.id == c2 }?.name == "Right source",
            "Apply changes the captured C1 attributes while leaving selected C2 intact")
        expect(try session.undoInfo(image).undoCount == attributesHistory.undoCount + 1
            && state(other.image) == untouchedB, "captured Attributes is one A Undo and cannot mutate front B")

        let baselineShape = EngineSession.SelectShape.ellipse(CGRect(x: 8, y: 5, width: 17, height: 14))
        var maskResults: [ChannelMenuMask] = []
        for (index, operation) in [EngineSession.SelectOperation.replace, .add, .subtract, .intersect].enumerated() {
            try session.select(baselineShape, image: image)
            try session.select(baselineShape, image: reference)
            try session.channelToSelection(refChannel, image: reference, operation: operation)
            try doc.reload(); doc.selectChannel(c1); try drain(doc); try focus(a)
            let beforeMask = try selectionMask(image), history = try session.undoInfo(image)
            send(modes[index])
            try drain(doc)
            let result = try selectionMask(image)
            expect(result == (try selectionMask(reference)), "mode \(index) matches the independent full native selection mask")
            expect(try session.undoInfo(image).undoCount == history.undoCount + 1, "mode \(index) adds exactly one native Undo")
            doc.undo(); try drain(doc)
            expect(try selectionMask(image) == beforeMask, "mode \(index) Undo restores every mask sample")
            doc.redo(); try drain(doc)
            expect(try selectionMask(image) == result, "mode \(index) Redo restores every mask sample")
            maskResults.append(result)
        }
        expect(maskResults.indices.allSatisfy { i in maskResults.indices.allSatisfy { j in i == j || maskResults[i] != maskResults[j] } },
               "the four mode oracles are nondegenerate and pairwise distinct")

        doc.selectChannel(c2); try drain(doc); try focus(a)
        let idsBefore = Set(try session.channels(image).map(\.id)), duplicateHistory = try session.undoInfo(image)
        send(duplicate); try drain(doc)
        let newIDs = Set(try session.channels(image).map(\.id)).subtracting(idsBefore)
        try require(newIDs.count == 1, "menu duplicate did not create exactly one channel")
        let copy = newIDs.first!
        expect(try thumbnail(copy, image: image) == sourceC2
            && session.undoInfo(image).undoCount == duplicateHistory.undoCount + 1, "main Duplicate copies selected C2 in one Undo")
        doc.selectChannel(copy); try drain(doc)
        let deleteHistory = try session.undoInfo(image)
        send(delete); try drain(doc)
        expect(try !session.channels(image).contains { $0.id == copy }
            && session.channels(image).contains { $0.id == c1 }
            && session.channels(image).contains { $0.id == c2 }
            && session.undoInfo(image).undoCount == deleteHistory.undoCount + 1, "main Delete removes only its captured selected ID in one Undo")
        doc.undo(); try drain(doc)
        expect(try thumbnail(copy, image: image) == sourceC2, "Delete Undo restores the same channel identity and pixels")
        doc.redo(); try drain(doc)
        doc.selectChannel(c2); try drain(doc)
        let contextIDs = Set(try session.channels(image).map(\.id))
        palette.perform(.duplicateChannel(c1)); try drain(doc)
        let contextCopies = Set(try session.channels(image).map(\.id)).subtracting(contextIDs)
        try require(contextCopies.count == 1, "context duplicate did not create one channel")
        let contextCopy = contextCopies.first!
        expect(try thumbnail(contextCopy, image: image) == sourceC1, "context Duplicate copies clicked C1 rather than selected C2")
        doc.selectChannel(c2); try drain(doc)
        palette.perform(.deleteChannel(contextCopy)); try drain(doc)
        expect(try !session.channels(image).contains { $0.id == contextCopy }
            && thumbnail(c2, image: image) == sourceC2, "context Delete removes its explicit ID and preserves selected C2")

        doc.returnToLayers(); try drain(doc)
        var beforeRefusal = try state(image)
        expect(savedItems.allSatisfy { !a.validateMenuItem($0) } && !a.validateMenuItem(layers), "no selected channel disables all channel actions")
        refuseSaved(); send(layers, to: a)
        expect(try state(image) == beforeRefusal && a.window?.attachedSheet == nil, "direct no-selection actions queue nothing and show no sheet")
        doc.selectChannelItems([c1, c2]); try drain(doc)
        beforeRefusal = try state(image)
        expect(savedItems.allSatisfy { !a.validateMenuItem($0) } && a.validateMenuItem(layers), "multiple channels disable single-target edits but keep Return to Layers")
        refuseSaved()
        expect(try state(image) == beforeRefusal, "ambiguous direct actions preserve native channels, selection, pixels and history")
        try focus(a); send(layers); try drain(doc)
        expect(try session.selectedItems(.channel, image: image).isEmpty
            && session.undoInfo(image) == beforeRefusal.history, "actual Return to Layers clears the whole channel list without Undo")

        doc.setQuickMask(true); try drain(doc)
        beforeRefusal = try state(image)
        expect(doc.channels.contains { $0.isQuickMask && doc.selectedChannelIDs == [$0.id] }
            && savedItems.allSatisfy { !a.validateMenuItem($0) }, "Quick Mask is never an implicit saved-channel main-menu target")
        refuseSaved()
        expect(try state(image) == beforeRefusal && a.window?.attachedSheet == nil, "Quick Mask refusals preserve exact native state")
        doc.setQuickMask(false); try drain(doc)
        doc.selectChannel(c1); try drain(doc)
        let invalid = NSMenuItem(title: "Invalid mode", action: Selector(("channelToSelectionMenu:")), keyEquivalent: "")
        beforeRefusal = try state(image)
        for tag in [-1, 4, Int(UInt32.max) + 1] {
            invalid.tag = tag
            expect(!a.validateMenuItem(invalid), "invalid mode tag \(tag) is disabled without a narrowing trap")
            send(invalid, to: a)
        }
        expect(try state(image) == beforeRefusal, "invalid mode packets perform no native work")

        // A cached row can disappear after validation. The existing native
        // service must refuse its captured ID instead of editing a fallback.
        let stale = try session.channelFromSelection(image, name: "Removed after cache")
        try doc.reload(); doc.selectChannel(stale); try drain(doc)
        _ = try session.channelCommand(.delete, channel: stale, image: image)
        beforeRefusal = try state(image)
        expect(a.validateMenuItem(duplicate), "validation reads the cached row without a native lookup")
        send(duplicate, to: a); try drain(doc)
        expect(try state(image) == beforeRefusal && !doc.channels.contains { $0.id == stale },
               "a newly stale channel refuses natively and refreshes without editing another channel")
        doc.selectChannel(c1); try drain(doc)

        let pickReady = DispatchSemaphore(value: 0), pickRelease = DispatchSemaphore(value: 0)
        gates.append(pickRelease)
        doc.inputQueue.async { pickReady.signal(); pickRelease.wait() }
        try require(wait { pickReady.wait(timeout: .now()) == .success }, "pending-pick barrier did not enter")
        doc.selectChannel(c2)
        beforeRefusal = try state(image)
        expect(doc.pendingWork == 1 && savedItems.allSatisfy { !a.validateMenuItem($0) }
            && !a.validateMenuItem(layers), "a mirrored channel pick remains unavailable until native settlement")
        refuseSaved(); send(layers, to: a)
        expect(try state(image) == beforeRefusal && doc.pendingWork == 1, "pending-pick direct actions add no jobs or native changes")
        pickRelease.signal(); try drain(doc)
        let busyReady = DispatchSemaphore(value: 0), busyRelease = DispatchSemaphore(value: 0)
        gates.append(busyRelease)
        let busyAdmitted = EngineActivity.shared.perform(label: "Channel menu busy oracle", work: {
            busyReady.signal(); busyRelease.wait()
        }, completion: {})
        try require(busyAdmitted && wait { busyReady.wait(timeout: .now()) == .success }, "busy oracle did not enter")
        beforeRefusal = try state(image)
        expect(savedItems.allSatisfy { !a.validateMenuItem($0) } && !a.validateMenuItem(layers), "real engine activity disables every channel action")
        refuseSaved(); send(layers, to: a)
        expect(try state(image) == beforeRefusal && doc.pendingWork == 0, "busy direct actions queue no work or image changes")
        busyRelease.signal(); try drain(doc)

        let renderReady = DispatchSemaphore(value: 0), renderRelease = DispatchSemaphore(value: 0)
        gates.append(renderRelease)
        a.canvas.enqueueRenderBarrier { renderReady.signal(); renderRelease.wait() }
        try require(wait { renderReady.wait(timeout: .now()) == .success }, "close render barrier did not enter")
        beforeRefusal = try state(image)
        a.window?.close()
        expect(a.closeStarted && doc.isClosing && (try? session.info(image)) != nil,
               "actual close stops admission while its native image remains behind the renderer")
        expect(savedItems.allSatisfy { !a.validateMenuItem($0) } && !a.validateMenuItem(layers), "closing disables all channel menu items")
        refuseSaved(); send(layers, to: a)
        expect(try state(image) == beforeRefusal, "closing direct actions preserve native channels, mask, pixels and history")
        renderRelease.signal()
        try require(wait { (try? session.info(image)) == nil }, "closed channel image did not drain")
        expect(try state(other.image) == untouchedB, "all A menu and context work leaves front B byte-for-byte untouched")
    }
}
