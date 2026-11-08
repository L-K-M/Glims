import AppKit

/// Which app-owned palette windows hold a field edit belonging to a
/// document. Rigi's PaletteCenter keeps each palette's content view
/// controller private, so a palette controller that can hold a pending
/// edit for its target registers here when it is aimed. A document window
/// that must finish pending edits ends them in its own window and in just
/// the palette windows aimed at its document, never another document's.
@MainActor
enum PaletteEditScope {
    /// A palette view controller whose fields can be mid-edit for the
    /// document it is aimed at.
    @MainActor
    protocol Content: NSViewController {
        /// The document the palette's edits currently belong to.
        var editTarget: ImageDocument? { get }
    }

    private final class WeakContent {
        weak var value: (any Content)?
        init(_ value: any Content) { self.value = value }
    }

    private static var contents: [WeakContent] = []

    /// Registers a palette content; each registers once.
    static func track(_ content: any Content) {
        guard !contents.contains(where: { $0.value === content }) else { return }
        contents.append(WeakContent(content))
    }

    /// Whether `window`'s first responder is a field editor holding an
    /// uncommitted edit — document, preview and palette windows alike.
    static func isFieldEditing(_ window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /// The distinct windows of presented palettes aimed at `document`.
    static func windowsEditing(_ document: ImageDocument) -> [NSWindow] {
        contents.removeAll { $0.value == nil }
        var seen = Set<ObjectIdentifier>()
        return contents.compactMap { entry in
            guard let content = entry.value, content.editTarget === document,
                  let window = content.view.window,
                  seen.insert(ObjectIdentifier(window)).inserted else { return nil }
            return window
        }
    }
}
