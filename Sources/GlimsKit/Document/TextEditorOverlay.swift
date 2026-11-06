import AppKit

/// The Text tool's editor: a text view laid over the canvas where the text
/// goes, showing the typed text in the closest macOS font at the canvas's
/// zoom. The engine draws the real text layer once editing finishes, so
/// the overlay is a preview, not the result.
@MainActor
final class TextEditorOverlay: NSTextView {

    /// The text layer being edited, or nil for new text.
    let textLayer: Int32?
    /// Where the text's top-left sits on the image, in pixels.
    let origin: CGPoint
    /// The text the editor opened with, to tell whether anything changed.
    let originalText: String
    /// Escape and Command-Return finish editing; so does clicking outside,
    /// which the canvas handles.
    var onFinish: (() -> Void)?

    private let settings: EngineSession.TextSettings
    private var scale: Double
    /// Typing's own undo history. The window's undo manager is the
    /// engine's, which takes no AppKit registrations (it raises), and
    /// Edit ▸ Undo while typing should take back typing, not image edits.
    private let typingUndo = UndoManager()

    init(layer: Int32?, text: String, origin: CGPoint, settings: EngineSession.TextSettings, scale: Double) {
        self.textLayer = layer
        self.origin = origin
        originalText = text
        self.settings = settings
        self.scale = scale

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = .zero
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.8)
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        setAccessibilityLabel(layer == nil ? "New text" : "Edit text")

        applyStyle()
        string = text
        fit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasChanges: Bool { string != originalText }

    override var undoManager: UndoManager? { typingUndo }

    @objc func undo(_ sender: Any?) { typingUndo.undo() }
    @objc func redo(_ sender: Any?) { typingUndo.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")):
            (item as? NSMenuItem)?.title = typingUndo.undoMenuItemTitle
            return typingUndo.canUndo
        case Selector(("redo:")):
            (item as? NSMenuItem)?.title = typingUndo.redoMenuItemTitle
            return typingUndo.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// Follows the canvas zoom.
    func setScale(_ newScale: Double) {
        scale = newScale
        applyStyle()
        fit()
    }

    override func didChangeText() {
        super.didChangeText()
        fit()
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?()
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    /// The text in the font the engine will use, or the system font at the
    /// same size when macOS does not know it by that name.
    private func applyStyle() {
        let size = max(1, settings.size * scale)
        let font = Self.font(named: settings.font, size: size)
        let paragraph = NSMutableParagraphStyle()
        switch settings.justify {
        case .left: paragraph.alignment = .left
        case .right: paragraph.alignment = .right
        case .center: paragraph.alignment = .center
        case .fill: paragraph.alignment = .justified
        }
        paragraph.lineSpacing = max(0, settings.lineSpacing * scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: settings.color, .paragraphStyle: paragraph,
            .kern: settings.letterSpacing * scale,
        ]
        typingAttributes = attributes
        textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textStorage?.length ?? 0))
        insertionPointColor = settings.color
    }

    static func font(named name: String, size: Double) -> NSFont {
        if let font = NSFont(name: name, size: size) { return font }
        let family = name.split(separator: " ").first.map(String.init) ?? name
        if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return name.lowercased().contains("mono") ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : name.lowercased().contains("serif") && !name.lowercased().contains("sans")
            ? NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
            : .systemFont(ofSize: size)
    }

    /// Sizes the view to its text, at least one character wide, with its
    /// top-left at `origin`.
    private func fit() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let minimum = max(1, settings.size * scale)
        frame = NSRect(x: origin.x * scale, y: origin.y * scale,
                       width: max(used.width + 2, minimum * 0.6), height: max(used.height, minimum * 1.2))
    }
}
