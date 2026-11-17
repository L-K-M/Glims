import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// File > New's Contents: the panel offers White, Background Color and
    /// Transparent for RGB only and only on an adapter with slot 240;
    /// Create captures the tool background color; the engine makes one
    /// clean layer of that color, or a transparent "Layer 1", with no
    /// history, and the document opens on it.
    static func exerciseNewImageContents(_ session: EngineSession, documents: DocumentList) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rowHidden(_ view: NSView) -> Bool {
            var ancestor = view.superview
            while let current = ancestor, !(current is NSGridView) { ancestor = current.superview }
            return (ancestor as? NSGridView)?.cell(for: view)?.row?.isHidden ?? true
        }
        func settings(supportsContents: Bool, choose title: String?, mode: String = "RGB") -> (NewImageSettings?, Bool) {
            let panel = NewImagePanel(supportsContents: supportsContents)
            defer { panel.close() }
            panel.showWindow(nil)
            guard let content = panel.window?.contentView else { return (nil, false) }
            let views = descendants(content)
            guard let contents = views.first(where: { $0.accessibilityLabel() == "Contents" }) as? NSPopUpButton,
                  let modePopup = views.first(where: { $0.accessibilityLabel() == "Image mode" }) as? NSPopUpButton,
                  let create = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Create" })
            else { return (nil, false) }
            modePopup.selectItem(withTitle: mode)
            _ = modePopup.sendAction(modePopup.action, to: modePopup.target)
            let offered = !rowHidden(contents)
            if let title { contents.selectItem(withTitle: title) }
            var result: NewImageSettings?
            panel.onCreate = { result = $0 }
            create.performClick(nil)
            return (result, offered)
        }

        // The panel.
        let supported = session.supportsImageNewFilled
        let (colored, offered) = settings(supportsContents: true, choose: "Background Color")
        check(offered && colored?.contents == .backgroundColor && colored?.kind == .rgb,
              "New Image offers Contents for RGB and Create sends Background Color")
        let (clear, _) = settings(supportsContents: true, choose: "Transparent")
        check(clear?.contents == .transparent, "Create sends Transparent")
        let (ink, inkOffered) = settings(supportsContents: true, choose: "Transparent", mode: "Multichannel")
        check(!inkOffered && ink?.contents == .white, "Multichannel hides Contents and creates White")
        let (old, oldOffered) = settings(supportsContents: false, choose: "Transparent")
        check(!oldOffered && old?.contents == .white, "an adapter without slot 240 hides Contents and creates White")
        guard supported else {
            var refused = false
            do { _ = try session.newImage(width: 8, height: 8, contents: .transparent) }
            catch { refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) }
            let white = try? session.newImage(width: 8, height: 8, contents: .white)
            if let white { try? session.closeImage(white) }
            check(refused && white != nil, "an older adapter refuses Transparent and still makes White")
            return
        }
        guard let colored, let clear else { return check(false, "New Image Contents settings were created") }

        // The engine and the document, with the background color captured at Create.
        let state = ToolState.shared, oldBackground = state.background
        defer { state.background = oldBackground }
        state.background = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let fill = try colored.engineContents(background: state.background)
        state.background = .white
        let cases: [(NewImageSettings, EngineSession.NewImageContents, [UInt8], String)] = [
            (colored, fill, [51, 102, 153, 255], "Background"),
            (clear, try clear.engineContents(background: state.background), [0, 0, 0, 0], "Layer 1"),
        ]
        for (settings, contents, expected, name) in cases {
            let image = try session.newImage(width: 48, height: 32, contents: contents)
            let document: ImageDocument
            do { document = try ImageDocument(session: session, image: image, name: "Contents") }
            catch { try? session.closeImage(image); throw error }
            documents.items.append(document)
            defer {
                var closed = false; document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
                documents.items.removeAll { $0 === document }
            }
            let info = try session.info(image), layers = try session.layers(image)
            let undoCount = try session.undoInfo(image).undoCount
            let pixels = [pixel(session, image, x: 0, y: 0), pixel(session, image, x: 47, y: 31)]
            check(info.width == 48 && info.height == 32 && !info.isDirty && undoCount == 0
                  && layers.map(\.name) == [name] && pixels.allSatisfy { $0 == expected },
                  "New Image \(settings.contents.title) makes one clean \"\(name)\" layer of \(expected) "
                  + "(\(layers.map(\.name)), \(String(describing: pixels[0])))")
        }
    }
}
