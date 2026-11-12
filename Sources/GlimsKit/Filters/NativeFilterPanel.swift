import AppKit
import RigiUI

/// The generic native filter form: one row per editable property, a
/// status line for refused writes and an Apply/Cancel pair driving the
/// shared preview lifecycle.
///
/// Rows bind one way each — the control reports changes through
/// `setProperty`, the engine's answer comes back over the document's
/// input queue; a refused write restores the last value the engine
/// accepted and keeps the error visible while Cancel stays available.
@MainActor
class NativeFilterPanel: FilterPreviewPanel {
    let operation: EngineSession.FilterOperation
    private let mergesPixels: Bool
    /// Control refreshers by property name, for reads and refused writes.
    /// Subclass layouts register their own through `control(for:)`.
    private var bindings: [String: (EngineSession.FilterValue) -> Void] = [:]
    /// Every send bumps its property's generation; only the newest
    /// request's answer decides the row. Values are unusable for this —
    /// a NaN request never equals itself yet must still take its answer.
    private var generations: [String: Int] = [:]
    private var pendingGenerations: [String: Int] = [:]
    private var requestSequence = 0
    /// The text last displayed/submitted by each text control, so peer
    /// acknowledgements can preserve a newer uncommitted field draft.
    private var draftFields: [String: () -> (NSTextField, String)?] = [:]
    /// The latest value the engine accepted, for reverts.
    private var accepted: [String: EngineSession.FilterValue] = [:]
    let statusField = NSTextField(wrappingLabelWithString: "")
    private(set) var lastError: String?

    /// `filter` is the session `ImageDocument.beginFilterPreview` began
    /// behind pending input; `initialValues` holds the values it read
    /// back in the same job, before this init runs on the main actor.
    init?(document imageDocument: ImageDocument,
          operation: EngineSession.FilterOperation,
          properties: [EngineSession.FilterProperty],
          filter: Int32,
          initialValues: [String: EngineSession.FilterValue], mergesPixels: Bool = false) {
        guard (!mergesPixels && operation.support == .supported)
                || (mergesPixels && NativeFilterMenuLayout.usesSourceChooser(operation)) else { return nil }
        self.operation = operation
        self.mergesPixels = mergesPixels
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = NativeFilterMenuLayout.displayTitle(operation)
        panel.isFloatingPanel = true
        super.init(document: imageDocument, panel: panel, filter: filter)
        buildContent(in: panel, properties: properties)
        for (name, value) in initialValues {
            accepted[name] = value
            bindings[name]?(value)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a refusal in the form itself as well as the status bar;
    /// cleared by the next write the engine accepts.
    override func showError(_ message: String) {
        lastError = message
        statusField.stringValue = message
    }

    /// A control's new value, queued on the input queue behind pending
    /// input. Answers arrive in order; only the newest request per
    /// property decides the row, so a refused stale write never reverts
    /// a value the user has already moved past.
    func setProperty(_ name: String, _ value: EngineSession.FilterValue) {
        guard let filter else { return }
        let generation = (generations[name] ?? 0) + 1
        generations[name] = generation
        pendingGenerations[name] = generation
        let sentGenerations = generations
        requestSequence += 1
        let request = requestSequence
        let submittedText = draftFields[name]?().map { field, _ in
            field.currentEditor()?.string ?? field.stringValue
        }
        imageDocument.setFilterProperty(filter, name, value, reading: bindings.keys.sorted()) { [weak self] answer in
            guard let self, self.filter == filter else { return }
            if self.pendingGenerations[name] == generation { self.pendingGenerations[name] = nil }
            for (peer, actual) in answer.values {
                self.accepted[peer] = actual
                // A later queued edit owns its control until its own answer.
                if let pending = self.pendingGenerations[peer], pending > (sentGenerations[peer] ?? 0) { continue }
                if peer == name && !answer.didWrite {
                    self.restore(peer, actual, submittedText: submittedText)
                } else if let field = self.draftFields[peer]?() {
                    FilterFieldDrafts.preserve([field]) { self.bindings[peer]?(actual) }
                } else {
                    self.bindings[peer]?(actual)
                }
            }
            if !answer.didWrite, answer.values[name] == nil, self.generations[name] == generation,
               let accepted = self.accepted[name] {
                self.restore(name, accepted, submittedText: submittedText)
            }
            if request == self.requestSequence { self.showError(answer.error?.localizedDescription ?? "") }
        }
    }

    /// Register a specialized control without exposing the transport state.
    func registerBinding(_ name: String, update: @escaping (EngineSession.FilterValue) -> Void) {
        bindings[name] = update
    }

    private func restore(_ name: String, _ value: EngineSession.FilterValue, submittedText: String?) {
        if let field = draftFields[name]?()?.0, let submittedText {
            FilterFieldDrafts.preserve([(field, submittedText)]) { bindings[name]?(value) }
        } else {
            bindings[name]?(value)
        }
    }

    /// Builds the form's content during init; subclass editors override
    /// it to lay out their own rows while reusing `control(for:)` and the
    /// shared write/acknowledgement lifecycle.
    func buildContent(in panel: NSPanel, properties: [EngineSession.FilterProperty]) {
        // Operations with no editable properties (Invert, Absolute, …)
        // get a note, not a settings grid — an empty NSGridView has no
        // column 0 and Apply/Cancel still need a stable window.
        let rows: [[NSView]] = properties.isEmpty
            ? [[Self.noSettingsNote()]]
            : properties.map { property in [Self.label(for: property), control(for: property)] }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        if !properties.isEmpty { grid.column(at: 0).xPlacement = .trailing }
        // NSScrollView does not size a generic document view. The grid
        // needs its natural frame even when this short form never scrolls.
        let settingsSize = grid.fittingSize
        grid.setFrameSize(settingsSize)

        // Tall forms scroll; the rows then take the clip's width so the
        // labels wrap rather than the controls sliding under a scroller.
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clipped = settingsSize.height > 380
        scroll.hasVerticalScroller = clipped
        scroll.heightAnchor.constraint(equalToConstant: min(settingsSize.height, 380)).isActive = true
        let formWidth = min(settingsSize.width + (clipped ? 16 : 0), 560)
        scroll.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        if clipped {
            grid.translatesAutoresizingMaskIntoConstraints = false
            scroll.contentView.addConstraints([
                grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                grid.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                grid.heightAnchor.constraint(equalToConstant: settingsSize.height),
            ])
        }

        // A reserved line for refused writes and applies; the window
        // does not resize when a message lands.
        statusField.textColor = .systemRed
        statusField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.alignment = .left

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: mergesPixels ? "Apply to Pixels" : "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let note = NSTextField(wrappingLabelWithString: "Apply changes the target pixels. Undo restores them.")
        let stack = NSStackView(views: mergesPixels ? [scroll, note, statusField, buttons] : [scroll, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
        panel.setContentSize(NSSize(width: max(420, formWidth + 32), height: stack.fittingSize.height))
        panel.contentView?.layoutSubtreeIfNeeded()
        // NSGridView is unflipped: the first row is at the top of a tall
        // document, rather than the clip view's default bottom origin.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, grid.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.center()
    }

    /// Commit a typed-but-uncommitted field before the session commits,
    /// so the value it shows is the value that applies.
    @objc func apply() {
        window?.endEditing(for: nil)
        commit()
    }

    private static func noSettingsNote() -> NSTextField {
        let note = NSTextField(wrappingLabelWithString:
            "This filter has no settings; Apply commits it as it is.")
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        return note
    }

    private static func label(for property: EngineSession.FilterProperty) -> NSTextField {
        let text = property.label.isEmpty ? property.name : property.label
        let label = NSTextField(labelWithString: text.hasSuffix(":") ? text : text + ":")
        label.toolTip = property.blurb.isEmpty ? nil : property.blurb
        label.alignment = .right
        return label
    }

    /// One property's control cell; the binding closure updates it from
    /// the engine's answers. `displayScale`/`unit` make a number row
    /// present a scaled unit (percent over a -1...1 native property).
    func control(for property: EngineSession.FilterProperty,
                 displayScale: Double = 1, unit: String? = nil) -> NSView {
        switch property.kind {
        case .number, .integer:
            let row = FilterNumberRow(property: property, displayScale: displayScale, unitLabel: unit)
            let integer = property.kind == .integer
            draftFields[property.name] = { [weak row] in
                guard let row else { return nil }
                let shown = row.value * displayScale
                let displayed = row.formatter.string(from: NSNumber(value: shown)) ?? "\(shown)"
                return (row.field, displayed)
            }
            bindings[property.name] = { [weak row] value in
                switch value {
                case .number(let number): row?.show(number)
                case .integer(let integer): row?.show(Double(integer))
                default: break
                }
            }
            row.onChange = { [weak self] value in
                self?.setProperty(property.name, integer ? .integer(Int64(value)) : .number(value))
            }
            return row
        case .boolean:
            let row = FilterBoolRow(property: property)
            bindings[property.name] = { [weak row] value in
                if case .boolean(let flag) = value { row?.show(flag) }
            }
            row.onChange = { [weak self] flag in
                self?.setProperty(property.name, .boolean(flag))
            }
            return row
        case .enumeration:
            guard !property.choices.isEmpty else {
                return FilterUnsupportedRow(text: "Its values could not be listed.")
            }
            let row = FilterEnumRow(property: property, choices: property.choices)
            bindings[property.name] = { [weak row] value in
                if case .enumeration(let nick) = value { row?.show(nick) }
            }
            row.onChange = { [weak self] nick in
                self?.setProperty(property.name, .enumeration(nick))
            }
            return row
        case .string:
            let row = FilterStringRow(property: property)
            draftFields[property.name] = { [weak row] in row?.displayedField }
            bindings[property.name] = { [weak row] value in
                if case .string(let text) = value { row?.show(text) }
            }
            row.onChange = { [weak self] text in
                self?.setProperty(property.name, .string(text))
            }
            return row
        case .color:
            let row = FilterColorRow(property: property)
            bindings[property.name] = { [weak row] value in
                if case .color(let color) = value { row?.show(color) }
            }
            row.onChange = { [weak self] color in
                self?.setProperty(property.name, .color(color))
            }
            return row
        case .unsupported:
            return FilterUnsupportedRow(text: "This kind of setting can't be edited yet.")
        }
    }
}

/// A row that cannot edit its property: disabled text with the reason,
/// so the form stays honest about what it covers.
private final class FilterUnsupportedRow: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A boolean property: a checkbox in the value column.
private final class FilterBoolRow: NSView {
    private let check: NSButton
    var onChange: ((Bool) -> Void)?

    init(property: EngineSession.FilterProperty) {
        check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        super.init(frame: .zero)
        check.target = self
        check.action = #selector(toggled)
        check.setAccessibilityLabel(property.label)
        check.toolTip = property.blurb.isEmpty ? nil : property.blurb
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor),
            check.topAnchor.constraint(equalTo: topAnchor),
            check.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ flag: Bool) { check.state = flag ? .on : .off }

    @objc private func toggled() { onChange?(check.state == .on) }
}

/// An enum property: a popup of labels; the setter takes the nick.
private final class FilterEnumRow: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nicks: [String]
    var onChange: ((String) -> Void)?

    init(property: EngineSession.FilterProperty, choices: [EngineSession.FilterEnumChoice]) {
        nicks = choices.map(\.nick)
        super.init(frame: .zero)
        for choice in choices {
            popup.addItem(withTitle: choice.label.isEmpty ? choice.nick : choice.label)
        }
        popup.target = self
        popup.action = #selector(chose)
        popup.setAccessibilityLabel(property.label)
        popup.toolTip = property.blurb.isEmpty ? nil : property.blurb
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ nick: String) {
        guard let index = nicks.firstIndex(of: nick) else { return }
        popup.selectItem(at: index)
    }

    @objc private func chose() {
        let index = popup.indexOfSelectedItem
        guard nicks.indices.contains(index) else { return }
        onChange?(nicks[index])
    }
}

/// A UTF-8 string property; applies on Return or focus loss, not per key.
private final class FilterStringRow: NSView {
    var displayedField: (NSTextField, String) { (field, value) }
    private let field = NSTextField()
    private(set) var value = ""
    var onChange: ((String) -> Void)?

    init(property: EngineSession.FilterProperty) {
        super.init(frame: .zero)
        field.stringValue = property.defaultString
        value = property.defaultString
        field.target = self
        field.action = #selector(fieldChanged)
        field.delegate = self
        field.setAccessibilityLabel(property.label)
        field.toolTip = property.blurb.isEmpty ? nil : property.blurb
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String) {
        value = text
        field.stringValue = text
    }

    @objc private func fieldChanged() {
        guard field.stringValue != value else { return }
        value = field.stringValue
        onChange?(value)
    }
}

extension FilterStringRow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        fieldChanged()
    }
}

/// An sRGBA color property: the classic color well opens the system
/// color panel.
private final class FilterColorRow: NSView {
    private let well = ClassicColorWell(frame: .zero)
    var onChange: ((NSColor) -> Void)?

    init(property: EngineSession.FilterProperty) {
        super.init(frame: .zero)
        well.color = property.defaultColor
        well.target = self
        well.action = #selector(colorChanged)
        well.setAccessibilityLabel(property.label)
        well.toolTip = property.blurb.isEmpty ? nil : property.blurb
        well.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ color: NSColor) { well.color = color }

    @objc private func colorChanged() { onChange?(well.color) }
}
