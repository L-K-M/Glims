import AppKit

/// One Layers palette row: a visibility checkbox, a lock badge when the
/// engine enforces locks on the item, and the layer's name, editable in
/// place. The row keeps the document and layer it was made for for the
/// whole edit, so a rename cannot land on another document or on a layer
/// that went away while the name was being typed.
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

    /// The row's height; the palette's outline uses it too.
    static let rowHeight: CGFloat = 22

    let checkbox: NSButton
    let nameField: NSTextField
    /// The lock badge; nil when nothing locks the layer.
    let lockView: NSImageView?
    /// Called after a name edit ends, so the palette can catch the list up
    /// after reloads were held off while typing.
    var onEditEnded: (() -> Void)?

    private let context: Context
    private let commit: Commit
    private var shownName: String
    private var shownVisible: Bool

    init(layer: EngineSession.Layer, context: Context, details: String = "",
         locks: LayerTree.LockSources? = nil, commit: @escaping Commit) {
        self.context = context
        self.commit = commit
        self.shownName = layer.name
        self.shownVisible = layer.isVisible

        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = layer.isVisible ? .on : .off
        checkbox.setAccessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
        self.checkbox = checkbox

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

        orientation = .horizontal
        alignment = .centerY
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 4)
        addArrangedSubview(checkbox)
        if let badge { addArrangedSubview(badge) }
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
