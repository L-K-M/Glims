import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// `palette-keyboard-focus`: a normal AppKit host owns one real document
    /// through a real `AppController` on the smoke engine (no second engine).
    /// Opening the document materializes the automatic palette layout, which
    /// must not steal the document's key focus. An explicit Window menu
    /// palette action must make its own palette panel the key window with a
    /// usable first responder, while the main document window stays main and
    /// unchanged.
    static func exercisePaletteKeyboardFocus(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ condition: Bool, _ message: String) {
            check(condition, "palette-keyboard-focus: \(message)")
        }
        func waitFor(_ description: String, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if condition() { return true }
                EngineSmokeTestHost.pumpEvents()
            }
            expect(false, "timed out: \(description)")
            return false
        }
        func descendants<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
        }
        func isInside(_ view: NSView?, _ container: NSView?) -> Bool {
            var node = view
            while let current = node {
                if current === container { return true }
                node = current.superview
            }
            return false
        }
        func windowMenuItem(_ title: String) -> NSMenuItem? {
            NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: title)
        }
        func visiblePalettePanel(titled title: String) -> NSWindow? {
            NSApp.windows.first { ($0 is ClassicPaletteWindow) && $0.isVisible && $0.title == title }
        }

        let image = try session.newImage(width: 48, height: 32)
        let document = try ImageDocument(session: session, image: image, name: "Palette Keyboard Focus")
        documents.items.append(document)
        let owner = AppController()
        expect(owner.session == nil, "the fixture AppController does not start a second engine")
        let paletteKinds = AppController.defaultPaletteLayout.flatMap(\.kinds)
        let previouslyPresented = Set(paletteKinds.filter {
            PaletteCenter.shared.registeredPalette(for: $0)?.isPresented == true
        })
        defer {
            for kind in paletteKinds where !previouslyPresented.contains(kind) {
                PaletteCenter.shared.registeredPalette(for: kind)?.close()
            }
            EngineSmokeTestHost.pumpEvents(for: 0.05)
            if let controller = owner.documents.first {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .abort)
                }
                controller.closeDiscardingChanges()
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                _ = waitFor("owned renderer drains during teardown", { stopped })
            }
            document.closeImageWhenDrained()
            let closed = waitFor("owned native image and document close during teardown", {
                (try? session.info(image)) == nil && owner.documents.isEmpty
            })
            expect(closed && paletteKinds.allSatisfy {
                        previouslyPresented.contains($0)
                            || PaletteCenter.shared.registeredPalette(for: $0)?.isPresented != true
                    },
                   "teardown closes the owned document, palette panels and native image")
            documents.items.removeAll { $0 === document }
            EngineSmokeTestHost.pumpEvents(for: 0.03)
        }

        NSApp.activate(ignoringOtherApps: true)
        owner.open(document)
        guard let controller = owner.documents.first(where: { $0.imageDocument === document }),
              let docWindow = controller.window else {
            expect(false, "the real AppController adopted the opened document")
            return
        }
        guard waitFor("document startup work drains", {
            document.pendingWork == 0 && !EngineActivity.shared.isBusy
        }) else { return }
        // Real document main/key focus, settled by pumping real events.
        docWindow.makeKeyAndOrderFront(nil)
        docWindow.makeMain()
        guard waitFor("the document window is the actual key and main window", {
            NSApp.isActive && NSApp.keyWindow === docWindow && NSApp.mainWindow === docWindow
        }) else { return }
        let groupCount = AppController.defaultPaletteLayout.count
        expect(paletteKinds.allSatisfy { PaletteCenter.shared.registeredPalette(for: $0)?.isPresented == true }
                && NSApp.windows.filter { ($0 is ClassicPaletteWindow) && $0.isVisible }.count == groupCount,
               "opening a document presents the automatic palette layout as \(groupCount) visible panels")
        EngineSmokeTestHost.pumpEvents(for: 0.2)
        expect(NSApp.keyWindow === docWindow && NSApp.mainWindow === docWindow,
               "the automatic palette layout does not steal the document's key focus")
        let documentResponder = docWindow.firstResponder
        let undoBefore = try session.undoInfo(image)
        let pixelsBefore = try session.copyPixels(image, merged: true).pixels

        // The installed Window > Recorder action, dispatched to the AppController.
        guard let recorderItem = windowMenuItem("Recorder"),
              recorderItem.action == #selector(AppController.showRecorder(_:)) else {
            expect(false, "the installed Window menu exposes Recorder as its showRecorder action")
            return
        }
        expect(NSApp.sendAction(recorderItem.action!, to: owner, from: recorderItem),
               "the installed Window > Recorder action dispatches to the AppController")
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        let recorderTitle = RecorderPaletteController.definition.title
        guard waitFor("the Recorder palette panel is presented", {
            PaletteCenter.shared.registeredPalette(for: RecorderPaletteController.definition.kind)?.isPresented == true
                && visiblePalettePanel(titled: recorderTitle) != nil
        }), let recorderPanel = visiblePalettePanel(titled: recorderTitle) else { return }
        // Baseline guard: the palette panel must become the actual key window.
        // On the unfixed build this fails here; the deferred teardown still runs.
        guard waitFor("Window > Recorder makes its palette panel the actual key window",
                      { NSApp.keyWindow === recorderPanel }) else { return }
        let recordButton = descendants(recorderPanel.contentView, NSButton.self).first {
            $0.accessibilityLabel() == "Recorder \(RecorderPaletteAction.record.title)"
        }
        let stopButton = descendants(recorderPanel.contentView, NSButton.self).first {
            $0.accessibilityLabel() == "Recorder \(RecorderPaletteAction.stop.title)"
        }
        let table = descendants(recorderPanel.contentView, NSTableView.self).first
        let responder = recorderPanel.firstResponder
        let usableResponder = responder != nil && (responder as? NSView)?.window === recorderPanel
            && ((responder === recordButton || responder === stopButton)
                ? (responder as? NSButton)?.isEnabled == true : responder === table)
        expect(usableResponder, "the key Recorder panel has a usable Record/Stop button or table first responder")
        expect(NSApp.mainWindow === docWindow && docWindow.firstResponder === documentResponder
                && (try? session.undoInfo(image)) == undoBefore
                && (try? session.copyPixels(image, merged: true).pixels) == pixelsBefore,
               "the real main document window and its native state stay unchanged")

        // Complete path: a real Tab event must stay inside the key panel.
        if let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: recorderPanel.windowNumber, context: nil,
                                      characters: "\t", charactersIgnoringModifiers: "\t",
                                      isARepeat: false, keyCode: 48) {
            NSApp.sendEvent(tab)
            EngineSmokeTestHost.pumpEvents(for: 0.05)
        }
        let afterTab = recorderPanel.firstResponder
        expect(NSApp.keyWindow === recorderPanel
                && (afterTab === recorderPanel || afterTab === recorderPanel.contentView
                    || isInside(afterTab as? NSView, recorderPanel.contentView)),
               "an actual Tab key event keeps keyboard focus within the Recorder panel")

        // The explicit Window > Layers / Tool Options actions allow keyboard entry too.
        for (title, action) in [("Layers", #selector(AppController.showLayers(_:))),
                                ("Tool Options", #selector(AppController.showToolOptions(_:)))] {
            guard let item = windowMenuItem(title), item.action == action else {
                expect(false, "the installed Window menu exposes \(title)")
                continue
            }
            expect(NSApp.sendAction(item.action!, to: owner, from: item),
                   "the installed Window > \(title) action dispatches to the AppController")
            EngineSmokeTestHost.pumpEvents(for: 0.05)
            guard waitFor("the \(title) palette panel is presented", { visiblePalettePanel(titled: title) != nil }),
                  let panel = visiblePalettePanel(titled: title),
                  waitFor("Window > \(title) makes its palette panel key", { NSApp.keyWindow === panel }) else { continue }
            expect((panel.firstResponder as? NSView)?.window === panel || panel.firstResponder === panel,
                   "Window > \(title) allows keyboard entry into its panel")
        }
    }
}
