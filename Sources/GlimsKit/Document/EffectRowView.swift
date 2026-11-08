import AppKit

/// One committed effect row under a layer in the Layers palette: an eye
/// that toggles the effect, an "fx" badge that marks the effective
/// effect selection, the effect's name, and its opacity when it is not
/// full. The row keeps the document, drawable and effect it was made
/// for, so a toggle cannot land on another document or on an effect
/// that went away while the row was on screen.
@MainActor
final class EffectRowView: NSStackView {
    /// Commits a change to the row's effect; returns false when the
    /// document refused it (a plug-in is running, it is closing, or the
    /// effect is gone). The row then shows the state it last showed.
    typealias Commit = (EffectItem, EngineSession.EffectChange) -> Bool

    /// The row's item: the effect, its drawable and its document.
    let item: EffectItem
    /// The eye; disabled while the document refuses edits.
    let eye: NSButton
    /// The effect's name; truncates rather than pushing the opacity out.
    let nameLabel: NSTextField
    /// The opacity readout, absent at full opacity so the name keeps the room.
    let opacityLabel: NSTextField?
    private let badge: EffectBadge
    private let commit: Commit
    private var shownEnabled: Bool

    init(item: EffectItem, isSelected: Bool, commit: @escaping Commit) {
        self.item = item
        self.commit = commit
        self.shownEnabled = item.effect.isEnabled

        let eye = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        eye.state = item.effect.isEnabled ? .on : .off
        eye.setAccessibilityLabel("\(item.effect.isEnabled ? "Disable" : "Enable") \(item.effect.name)")
        self.eye = eye

        let badge = EffectBadge()
        badge.isSelected = isSelected
        self.badge = badge

        let name = NSTextField(labelWithString: item.effect.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setAccessibilityLabel("Filter name")
        self.nameLabel = name

        var opacity: NSTextField?
        if item.effect.opacity < 0.995 {
            let label = NSTextField(labelWithString: EffectRowView.opacityText(item.effect.opacity))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel("Filter opacity")
            opacity = label
        }
        self.opacityLabel = opacity

        super.init(frame: .zero)

        eye.target = self
        eye.action = #selector(toggleEnabled(_:))

        orientation = .horizontal
        alignment = .centerY
        spacing = 3
        edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 4)
        for view in [eye, badge, name] as [NSView] { addArrangedSubview(view) }
        if let opacity { addArrangedSubview(opacity) }
        heightAnchor.constraint(equalToConstant: LayerRowView.rowHeight).isActive = true

        toolTip = item.effect.operation == item.effect.name
            ? item.effect.name
            : "\(item.effect.name) (\(item.effect.operation))"
        setAccessibilityLabel("Filter \(item.effect.name)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The badge's selected look, refreshed on reload.
    func updateSelected(_ isSelected: Bool) {
        badge.isSelected = isSelected
    }

    /// The opacity text the row shows: whole percents, clamped to the
    /// range the effect can hold.
    static func opacityText(_ opacity: Double) -> String {
        "\(Int((min(max(opacity, 0), 1) * 100).rounded()))%"
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        var change = EngineSession.EffectChange()
        change.isEnabled = sender.state == .on
        if commit(item, change) {
            shownEnabled = sender.state == .on
            eye.setAccessibilityLabel("\(shownEnabled ? "Disable" : "Enable") \(item.effect.name)")
        } else {
            // Refused: show the effect's authoritative state again.
            sender.state = shownEnabled ? .on : .off
        }
    }
}

/// The "fx" lozenge ahead of the effect's name: filled with the accent
/// color while the row is the effective effect selection, muted
/// otherwise.
private final class EffectBadge: NSView {
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(isSelected ? "Selected filter" : "Filter")
        }
    }

    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 13).isActive = true
        setAccessibilityLabel("Filter")
        setAccessibilityHelp("A committed filter on this layer.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        (isSelected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        let text = NSAttributedString(string: "fx", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2))
    }
}

/// Which stack commands a committed effect can take right now, mirrored
/// for menu enablement. The engine's own guards stay authoritative;
/// this only decides which entries a row offers.
enum EffectCommands {
    /// Whether `command` is offered for the effect at `index` of `count`
    /// in `drawable`'s stack. Merge is limited to an enabled effect on
    /// an unlocked pixel layer — groups, text, link and vector layers
    /// keep their filters non-destructive.
    static func enabled(_ command: EngineSession.EffectCommand,
                        at index: Int, of count: Int,
                        effect: EngineSession.Effect,
                        layer: EngineSession.Layer?,
                        locks: EngineSession.LayerLocks) -> Bool {
        switch command {
        case .raise, .toTop:
            return index > 0
        case .lower, .toBottom:
            return index < count - 1
        case .remove:
            return true
        case .merge:
            return effect.isEnabled && layer?.kind == .pixel && !locks.contains(.pixels)
        }
    }
}

/// The effect row's Properties sheet: the effect's name — left empty it
/// restores the operation's default title — and its opacity, applied as
/// one undo step. The document, drawable and effect are captured when
/// the sheet opens; a retarget cannot redirect the edit.
@MainActor
enum EffectPropertiesForm {
    static func present(item: EffectItem, in document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil,
              document.canChangeEffect(item.effect.id, on: item.drawable) else { return }
        let name = NSTextField(string: item.effect.name)
        name.setAccessibilityLabel("Effect name")
        let opacity = NSTextField(
            string: NumberFormatter.localizedString(
                from: NSNumber(value: item.effect.opacity * 100), number: .decimal))
        opacity.setAccessibilityLabel("Filter opacity, percent")
        let note = NSTextField(wrappingLabelWithString: "An empty name restores the default.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "Opacity (%):"), opacity],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(stack.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Filter Properties"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, document.acceptsEdits,
                  document.canChangeEffect(item.effect.id, on: item.drawable) else { return }
            let trimmed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count <= 255, !trimmed.contains("\0"),
                  let alpha = ChannelForms.opacityValue(opacity.stringValue) else {
                document.onError?("Enter an opacity from 0 to 100%; shorten very long names.")
                return
            }
            var change = EngineSession.EffectChange()
            if trimmed != item.effect.name { change.name = trimmed }
            if alpha != item.effect.opacity { change.opacity = alpha }
            guard change.name != nil || change.opacity != nil else { return }
            document.changeEffect(item.effect.id, on: item.drawable, change)
        }
    }
}
