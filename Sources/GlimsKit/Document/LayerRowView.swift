import AppKit

/// One Layers palette row: a visibility checkbox, the layer's and its
/// mask's thumbnails, a lock badge when the engine enforces locks on the
/// item, and the layer's name, editable in place. The row keeps the
/// document and layer it was made for for the whole edit, so a rename
/// cannot land on another document or on a layer that went away while
/// the name was being typed.
@MainActor
final class LayerRowView: NSStackView, NSTextFieldDelegate {
    /// The document and layer an edit belongs to. The document is compared
    /// by identity: an edit for a document that is no longer the palette's
    /// target is refused.
    struct Context {
        let document: AnyObject
        let layerID: Int32
    }

    /// Commits a change to the row's layer; returns false when the document
    /// refused it (a plug-in is running, it is closing, or the layer is
    /// gone). The row then shows the layer it last showed again.
    typealias Commit = (Context, EngineSession.LayerChange) -> Bool

    /// Which drawable a thumbnail click picks.
    enum ThumbnailPick {
        /// The layer itself: painting, fills and filters land on its pixels.
        case layer
        /// The layer's mask: they land on the mask instead.
        case mask
    }

    /// The row's height; the palette's outline uses it too.
    static let rowHeight: CGFloat = 22
    /// The thumbnails' square size inside the row.
    static let thumbnailSide: CGFloat = 20

    let checkbox: NSButton
    /// The layer's color thumbnail; its ring marks the layer as the
    /// active paint target.
    let layerThumb: ThumbnailButton
    /// The mask's gray thumbnail, present only when the layer has a mask.
    /// Its ring marks mask editing; Option-click views the mask.
    let maskThumb: ThumbnailButton?
    let nameField: NSTextField
    /// The lock badge; nil when nothing locks the layer.
    let lockView: NSImageView?
    /// Called after a name edit ends, so the palette can catch the list up
    /// after reloads were held off while typing.
    var onEditEnded: (() -> Void)?
    /// Called with a thumbnail pick and whether Option was held — the
    /// mask thumbnail's Option-click is View Mask, not Edit Mask.
    var onThumbnail: ((ThumbnailPick, Bool) -> Void)?
    /// Where the Option check reads; tests substitute a fixed answer
    /// because no event is being dispatched under XCTest.
    var optionIsDown: () -> Bool = {
        NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
    }

    /// The row's document and layer, for the palette's stale guards.
    let context: Context
    private let commit: Commit
    private var shownName: String
    private var shownVisible: Bool

    init(layer: EngineSession.Layer, context: Context, details: String = "",
         locks: LayerTree.LockSources? = nil, mask: EngineSession.MaskState? = nil,
         activeTarget: ThumbnailButton.Target = .none,
         commit: @escaping Commit) {
        self.context = context
        self.commit = commit
        self.shownName = layer.name
        self.shownVisible = layer.isVisible

        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = layer.isVisible ? .on : .off
        checkbox.setAccessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
        self.checkbox = checkbox

        let layerThumb = ThumbnailButton(kind: .layer)
        layerThumb.isActiveTarget = activeTarget == .layer
        layerThumb.setAccessibilityLabel("\(layer.name) layer")
        layerThumb.setAccessibilityHelp("Make \(layer.name) the paint target.")
        self.layerThumb = layerThumb

        var maskThumb: ThumbnailButton?
        if let mask {
            let button = ThumbnailButton(kind: .mask)
            button.isActiveTarget = activeTarget == .mask
            button.isDimmed = !mask.enabled
            button.showsBadge = mask.showing
            button.setAccessibilityLabel("\(layer.name) mask")
            button.setAccessibilityHelp(Self.maskHelp(name: layer.name, mask: mask))
            maskThumb = button
        }
        self.maskThumb = maskThumb

        let nameField = NSTextField(string: layer.name)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = true
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.textColor = layer.kind == .group ? .secondaryLabelColor : .labelColor
        // The name takes the row's remaining width and truncates rather
        // than pushing the details out.
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setAccessibilityLabel(layer.kind == .group ? "Group name" : "Layer name")
        self.nameField = nameField

        var badge: NSImageView?
        if let locks, !locks.effective.isEmpty {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            // Full color for the item's own lock, secondary when the lock
            // reaches it through an ancestor or a locked layer inside.
            view.contentTintColor = locks.local.isEmpty ? .secondaryLabelColor : .labelColor
            let accessibility = Self.lockAccessibility(locks, name: layer.name)
            view.setAccessibilityLabel(accessibility.label)
            view.setAccessibilityHelp(accessibility.help)
            badge = view
        }
        self.lockView = badge

        super.init(frame: .zero)

        checkbox.target = self
        checkbox.action = #selector(toggleVisibility(_:))
        nameField.delegate = self
        layerThumb.target = self
        layerThumb.action = #selector(thumbClicked(_:))
        maskThumb?.target = self
        maskThumb?.action = #selector(thumbClicked(_:))

        orientation = .horizontal
        alignment = .centerY
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 4)
        for view in [checkbox, layerThumb, maskThumb, badge].compactMap({ $0 }) {
            addArrangedSubview(view)
        }
        addArrangedSubview(nameField)
        if !details.isEmpty {
            let detailsLabel = NSTextField(labelWithString: details)
            detailsLabel.font = .systemFont(ofSize: 11)
            detailsLabel.textColor = .secondaryLabelColor
            detailsLabel.lineBreakMode = .byTruncatingTail
            addArrangedSubview(detailsLabel)
        }
        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What VoiceOver hears for the mask thumbnail: its flags and the
    /// click and Option-click meanings.
    static func maskHelp(name: String, mask: EngineSession.MaskState) -> String {
        var parts = ["\(name)'s mask"]
        parts.append(mask.enabled ? "enabled" : "disabled")
        if mask.editing { parts.append("being edited") }
        if mask.showing { parts.append("shown on the canvas") }
        return parts.joined(separator: ", ")
            + ". Click to edit the mask; Option-click to view it."
    }

    /// The mask thumbnail's look for `mask` and the target rings,
    /// refreshed on reload.
    func updateMask(_ mask: EngineSession.MaskState?, activeTarget: ThumbnailButton.Target) {
        layerThumb.isActiveTarget = activeTarget == .layer
        guard let maskThumb else { return }
        maskThumb.isActiveTarget = activeTarget == .mask
        maskThumb.isDimmed = mask.map { !$0.enabled } ?? false
        maskThumb.showsBadge = mask?.showing ?? false
        if let mask {
            maskThumb.setAccessibilityHelp(Self.maskHelp(name: shownName, mask: mask))
        }
    }

    /// The thumbnails' target rings, refreshed on reload.
    func updateTarget(_ target: ThumbnailButton.Target) {
        layerThumb.isActiveTarget = target == .layer
        maskThumb?.isActiveTarget = target == .mask
    }

    @objc private func thumbClicked(_ sender: ThumbnailButton) {
        onThumbnail?(sender.kind == .layer ? .layer : .mask, optionIsDown())
    }

    /// What the lock badge says: the lock names and where they come
    /// from — the item itself, a parent group, or a layer inside a group.
    static func lockAccessibility(_ sources: LayerTree.LockSources,
                                  name: String) -> (label: String, help: String) {
        var parts: [String] = []
        if !sources.local.isEmpty {
            parts.append("locked \(lockNames(sources.local))")
        }
        if !sources.inherited.isEmpty {
            parts.append("\(lockNames(sources.inherited)) locked by a parent group")
        }
        if !sources.descendant.isEmpty {
            parts.append("a layer inside has locked \(lockNames(sources.descendant))")
        }
        let help = "\(name): " + parts.joined(separator: "; ")
        return ("Locked: \(lockNames(sources.effective))", help)
    }

    /// The lock names in menu order ("pixels, transparency").
    static func lockNames(_ locks: EngineSession.LayerLocks) -> String {
        EngineSession.LayerLocks.menuOrder.compactMap { locks.contains($0.lock) ? $0.lock.name : nil }
            .joined(separator: ", ")
    }

    /// Starts an inline name edit, as the outline's double-click does.
    func startEditingName() {
        guard let window = nameField.window else { return }
        window.makeKey()
        window.makeFirstResponder(nameField)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        // An outline's programmatic field editor can start in a nonactivating
        // palette while the document still owns the keyboard.
        nameField.window?.makeKey()
    }

    /// Ends the name edit and commits a changed name. Called when the field
    /// editor ends; exposed for tests.
    func finishNameEditing() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != shownName else {
            nameField.stringValue = shownName
            onEditEnded?()
            return
        }
        var change = EngineSession.LayerChange()
        change.name = name
        if commit(context, change) {
            shownName = name
            checkbox.setAccessibilityLabel("\(shownVisible ? "Hide" : "Show") \(name)")
        } else {
            // Refused: show the layer's authoritative name again.
            nameField.stringValue = shownName
        }
        onEditEnded?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishNameEditing()
    }

    @objc private func toggleVisibility(_ sender: NSButton) {
        let visible = sender.state == .on
        var change = EngineSession.LayerChange()
        change.isVisible = visible
        if commit(context, change) {
            shownVisible = visible
            checkbox.setAccessibilityLabel("\(visible ? "Hide" : "Show") \(shownName)")
        } else {
            // Refused: show the layer's authoritative visibility again.
            sender.state = shownVisible ? .on : .off
        }
    }

    /// Whether an edit made for `context` still applies: the document is
    /// the palette's target and the layer is still in it.
    static func canChange(_ context: Context, document: AnyObject?, layers: [EngineSession.Layer]) -> Bool {
        guard let document, context.document === document else { return false }
        return layers.contains { $0.id == context.layerID }
    }

    /// Whether a name in `outline` is being edited. The palette holds its
    /// reloads while this is true, so a rename being typed is never
    /// committed half done.
    static func isRenaming(in outline: NSOutlineView) -> Bool {
        guard let editor = outline.window?.firstResponder as? NSText,
              let field = editor.delegate as? NSTextField else { return false }
        return field.isDescendant(of: outline)
    }
}

/// A row's drawable thumbnail: the image aspect-fit in the button, a
/// ring while its drawable is the active paint target, dimmed while a
/// mask is disabled, and a small eye badge while the mask is shown on
/// the canvas. An `NSButton` so it takes clicks, keyboard focus and
/// VoiceOver like every other control.
@MainActor
final class ThumbnailButton: NSButton {
    enum Kind { case layer, mask }
    /// Which thumbnail is the active paint target on the row.
    enum Target { case none, layer, mask }

    let kind: Kind
    /// The drawable's image, aspect-fit; nil until the thumbnail load
    /// lands (and for an empty drawable).
    var thumbnail: NSImage? {
        didSet { needsDisplay = true }
    }
    /// The active-target ring.
    var isActiveTarget = false { didSet { needsDisplay = true } }
    /// A disabled mask's gray levels, shown faded.
    var isDimmed = false { didSet { needsDisplay = true } }
    /// A mask being viewed on the canvas gets the eye badge.
    var showsBadge = false { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        imageScaling = .scaleProportionallyDown
        widthAnchor.constraint(equalToConstant: LayerRowView.thumbnailSide).isActive = true
        heightAnchor.constraint(equalToConstant: LayerRowView.thumbnailSide).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = LayerRowView.thumbnailSide
        let imageRect = NSRect(x: (bounds.width - side) / 2 + 1,
                               y: (bounds.height - side) / 2 + 1,
                               width: side - 2, height: side - 2)
        if let thumbnail {
            context.saveGState()
            if isDimmed { context.setAlpha(0.45) }
            thumbnail.draw(in: imageRect, from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            context.restoreGState()
        } else {
            // Nothing read yet: the well a thumbnail will fill.
            NSColor(calibratedWhite: 0.5, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: 2, yRadius: 2).fill()
        }
        if showsBadge, let badge = NSImage(systemSymbolName: "eye.fill",
                                          accessibilityDescription: nil) {
            let size = NSSize(width: 9, height: 9)
            let rect = NSRect(x: bounds.maxX - size.width - 1, y: bounds.maxY - size.height - 1,
                              width: size.width, height: size.height)
            badge.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: 0.9, respectFlipped: true, hints: nil)
        }
        if isActiveTarget {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: 3, yRadius: 3)
            ring.lineWidth = 2
            ring.stroke()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 3, yRadius: 3)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
