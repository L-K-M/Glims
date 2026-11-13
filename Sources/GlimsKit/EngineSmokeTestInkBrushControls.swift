import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseInkBrushControls(_ session: EngineSession) throws {
        func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let state = ToolState.shared, oldTool = ToolState.shared.current
        let oldColor = state.foreground, oldBrush = state.brush(for: .paintbrush)
        defer {
            state.foreground = oldColor
            state.update(.paintbrush) { $0 = oldBrush }
            state.select(oldTool)
            state.notifyChange()
        }
        guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
            throw ImageDocument.DocumentError.targetChanged
        }
        for mode in [EngineSession.ColorMode.cmyk, .multichannel] {
            let image = try mode == .cmyk
                ? session.newCmykImage(width: 16, height: 12, component: .u8, profileICC: profile)
                : session.newMultichannelImage(width: 16, height: 12, component: .u8, channelCount: 4)
            let document = try ImageDocument(session: session, image: image, name: "Ink controls")
            let otherImage = try mode == .cmyk
                ? session.newCmykImage(width: 16, height: 12, component: .u8, profileICC: profile)
                : session.newMultichannelImage(width: 16, height: 12, component: .u8, channelCount: 4)
            let other = try ImageDocument(session: session, image: otherImage, name: "Other ink controls")
            let rgbImage = try session.newImage(width: 16, height: 12)
            let rgb = try ImageDocument(session: session, image: rgbImage, name: "RGB controls")
            let options = ToolOptionsPaletteController()
            let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 330, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.makeFirstResponder(nil)
                window.close()
                for doc in [document, other, rgb] {
                    var closed = false
                    doc.closeImageWhenDrained { closed = true }
                    wait { closed }
                    check(closed, "ink controls close their native document")
                }
            }
            let undo = try session.undoInfo(image)
            state.select(.paintbrush)
            state.update(.paintbrush) { $0.opacity = 0.4 }
            let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            state.foreground = red
            options.retarget(to: document)
            window.contentView = options.view
            window.makeKeyAndOrderFront(nil)
            func control() -> ClassicValueSlider? {
                views(options.view, ClassicValueSlider.self).first { $0.accessibilityTitle == "Ink percentage" }
            }
            guard let ink = control(),
                  let field = views(ink, NSTextField.self).first(where: { $0.isEditable }) else {
                check(false, "ink mode exposes an accessible percentage control")
                continue
            }
            check(abs(ink.value - 78.74) < 0.001 && state.foreground == red,
                  "opening Ink controls displays red luma without changing the colored swatch")
            func draft(_ text: String) {
                window.makeFirstResponder(field)
                field.selectText(nil)
                wait { field.currentEditor() != nil }
                check(field.currentEditor() != nil, "Ink editing uses an actual AppKit field editor")
                field.stringValue = text
                field.currentEditor()?.string = text
            }
            func commit() { _ = field.sendAction(field.action, to: field.target) }
            draft(field.stringValue)
            window.makeFirstResponder(nil)
            check(state.foreground == red, "leaving an unchanged rounded Ink field preserves colored foreground")
            draft("37.5")
            commit()
            let gray = state.brush(for: .paintbrush)
            check(abs(gray.red - 0.625) < 1e-9 && gray.red == gray.green && gray.green == gray.blue
                    && gray.opacity == 0.4,
                  "an explicit Ink commit sets the neutral intensity and preserves independent opacity")
            let beforeInvalid = state.foreground
            draft("101")
            commit()
            check(state.foreground == beforeInvalid && field.currentEditor()?.string == "101",
                  "out-of-range Ink text stays visible and does not change the foreground")
            draft("20")
            state.foreground = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            state.notifyChange()
            check(field.currentEditor()?.string == "20", "an external color update preserves a pending Ink draft")
            commit()
            check(abs(state.brush(for: .paintbrush).red - 0.8) < 1e-9,
                  "the preserved Ink draft still commits after an external color update")
            state.foreground = .black
            state.notifyChange()
            check(abs(ink.value - 100) < 0.001 && field.currentEditor()?.string == field.stringValue,
                  "an untouched Ink editor follows an external foreground reset")
            let staleCommit = ink.onChange
            options.retarget(to: other)
            let beforeStale = state.foreground
            staleCommit?(12, .committed)
            check(state.foreground == beforeStale && control() !== ink,
                  "retargeting between ink documents rebuilds controls and refuses the old callback")
            for tool in [ToolID.pencil, .airbrush] {
                state.select(tool)
                check(control() != nil, "each supported ink paint tool exposes percentage control")
            }
            options.retarget(to: rgb)
            check(control() == nil, "ordinary RGB tools do not expose ink percentage")
            check(try session.undoInfo(image) == undo, "editing tool coverage does not create image history")
        }
    }
}
