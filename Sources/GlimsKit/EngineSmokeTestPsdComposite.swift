import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exercisePsdComposite(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool, seconds: TimeInterval = 30) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        guard let path = ProcessInfo.processInfo.environment["GLIMS_DUOTONE_FIXTURE"] else {
            return check(false, "Photoshop composite fixture path is supplied")
        }
        let source = URL(fileURLWithPath: path), original = try Data(contentsOf: source)
        let owner = AppController(session: session)
        let oldMenu = NSApp.mainMenu
        let palettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        var retained: [ImageDocument] = []
        func remember() {
            for controller in owner.documents where !retained.contains(where: { $0 === controller.imageDocument }) {
                retained.append(controller.imageDocument)
                documents.items.append(controller.imageDocument)
            }
        }
        defer {
            remember()
            owner.documents.filter { !$0.closeStarted }.forEach { $0.closeDiscardingChanges() }
            check(wait({ retained.allSatisfy { $0.pendingWork == 0 && gone($0.image) } && !EngineActivity.shared.isBusy }),
                  "all composite documents close and drain")
            documents.items.removeAll { item in retained.contains { $0 === item } }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let visible = palettes[ObjectIdentifier(window)] {
                    if visible { window.orderFront(nil) } else { window.orderOut(nil) }
                } else { window.close() }
            }
            NSApp.mainMenu = oldMenu
        }
        NSApp.mainMenu = MainMenu.make()
        guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first(where: {
            $0.action == #selector(AppController.openPhotoshopComposite(_:))
        }) else { return check(false, "File menu contains Photoshop composite import") }
        check(item.title == "Open Photoshop Composite…" && owner.validateMenuItem(item) == session.supportsPhotoshopCompositeImport,
              "File menu exposes composite import only with the adapter capability")
        guard session.supportsPhotoshopCompositeImport else { return }
        var cancelled = false, timedOut = false
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            if let panel = NSApp.modalWindow as? NSOpenPanel {
                cancelled = panel.message.contains("Individual layers")
                panel.cancel(nil); timer.invalidate()
            } else if Date() >= deadline {
                timedOut = true; NSApp.abortModal(); timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let sent = NSApp.sendAction(#selector(AppController.openPhotoshopComposite(_:)), to: owner, from: item)
        timer.invalidate()
        check(sent && cancelled && !timedOut && NSApp.modalWindow == nil && owner.documents.isEmpty,
              "the real Open panel explains flattening and Cancel opens no document")
        var imported: Result<DocumentWindowController, Error>?
        owner.importPhotoshopComposite(from: source) { imported = $0 }
        guard wait({ imported != nil && !EngineActivity.shared.isBusy }), let result = imported else {
            return check(false, "composite import finishes")
        }
        let controller = try result.get(); remember()
        let document = controller.imageDocument
        check(document.fileState.importStrategy == .photoshopComposite && document.fileState.nativeURL == nil &&
              document.fileState.revertSource == .photoshopComposite(source) && document.hasUnsavedChanges &&
              document.fileState.saveRoute == .askForFile,
              "composite opens as an unsaved imported copy with a distinct Revert route")
        let pixels = try session.copyPixels(document.image, merged: true).pixels
        check(pixels.count == 64 && pixels[0] >= 23 && pixels[0] <= 25 && pixels[3] == 255 && document.layers.count == 1,
              "composite document displays the Photoshop gradient as one opaque layer")
        var repeated: Result<DocumentWindowController, Error>?
        owner.importPhotoshopComposite(from: source) { repeated = $0 }
        check(wait({ repeated != nil }) && (try? repeated?.get()) === controller && owner.documents.count == 1,
              "opening the same composite again focuses the existing document")
        var reverted: Result<DocumentWindowController, Error>?
        owner.revert(controller, to: source) { reverted = $0 }
        guard wait({ reverted != nil && !EngineActivity.shared.isBusy }), let replacement = try reverted?.get() else {
            return check(false, "composite Revert finishes")
        }
        remember()
        check(replacement.imageDocument.fileState.importStrategy == .photoshopComposite &&
              (try session.copyPixels(replacement.imageDocument.image, merged: true).pixels) == pixels,
              "Revert uses the composite loader and restores its pixels")
        check(try Data(contentsOf: source) == original, "composite import and Revert do not modify the source PSD")
    }
}
