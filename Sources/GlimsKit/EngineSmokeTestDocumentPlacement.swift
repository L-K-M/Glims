import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseDocumentPlacement(_ session: EngineSession, documents: DocumentList) throws {
        let owner = AppController()
        let preferences = EditorPreferences.shared
        let previousView = preferences.initialView
        preferences.initialView = .fit
        defer {
            preferences.initialView = previousView
            PaletteCenter.shared.closeAll()
        }
        var opened: [ImageDocument] = []
        var windows: [NSWindow] = []
        defer {
            for window in windows { window.orderOut(nil) }
            for doc in opened {
                documents.items.removeAll { $0 === doc }
                var closed = false
                doc.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
                check((try? session.info(doc.image)) == nil, "the placement fixture drains before engine shutdown")
            }
        }
        var paletteFrames: [CGRect]?
        for index in 0..<2 {
            let image = try session.newImage(width: 2400, height: 1800)
            let doc = try ImageDocument(session: session, image: image, name: "Placement \(index)")
            opened.append(doc)
            documents.items.append(doc)
            let infoBefore = try session.info(image)
            let undoBefore = try session.undoInfo(image)
            let pixelsBefore = try session.copyPixels(image, merged: true).pixels
            owner.open(doc)
            spin(0.1)
            guard let window = NSApp.windows.first(where: {
                ($0.windowController as? DocumentWindowController)?.imageDocument === doc
            }), let controller = window.windowController as? DocumentWindowController,
            let screen = window.screen else { check(false, "open adopts a real document window"); return }
            windows.append(window)
            let frames = NSApp.windows.filter { $0.isVisible && $0 is ClassicPaletteWindow }.map(\.frame)
            check(!frames.isEmpty, "palette frames exist before initial document fitting")
            let available = DocumentWindowPlacement.availableFrame(in: screen.visibleFrame, avoiding: frames)
            check(available.contains(window.frame), "the initial/cascaded document stays in the available screen area")
            let hasUsableSpace = !frames.contains { $0.intersects(available) }
            check(!hasUsableSpace || frames.allSatisfy { !$0.intersects(window.frame) },
                  "a usable document rectangle avoids every visible palette")
            let viewport = controller.scrollView.contentSize
            check(controller.canvas.frame.width <= viewport.width + 1
                    && controller.canvas.frame.height <= viewport.height + 1,
                  "initial Fit Image uses the placed window's final viewport")
            if let paletteFrames {
                check(frames == paletteFrames, "opening another document preserves all palette positions")
            }
            paletteFrames = frames
            let native = try session.info(image)
            let undoAfter = try session.undoInfo(image)
            let pixelsAfter = try session.copyPixels(image, merged: true).pixels
            check(native == infoBefore && undoAfter == undoBefore,
                  "placement and fitting preserve native image info, dirty state and history")
            check(pixelsAfter == pixelsBefore, "placement and fitting preserve all native composite bytes")
        }
    }
}
