import AppKit

/// The global tool-color target an editor session captured when it opened.
/// The identity is fixed at capture time: a later document retarget cannot
/// redirect an open editor to the other slot.
@MainActor
enum ToolColorTarget: String, CaseIterable {
    case foreground, background

    var title: String {
        switch self {
        case .foreground: return "Foreground"
        case .background: return "Background"
        }
    }

    /// The captured slot in the global `ToolState`.
    var keyPath: ReferenceWritableKeyPath<ToolState, NSColor> {
        switch self {
        case .foreground: return \.foreground
        case .background: return \.background
        }
    }
}

/// One RGB component row of the tool color editor.
enum ToolColorComponent: String, CaseIterable {
    case red, green, blue

    var name: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

/// The model of the tool color editor: the captured target plus the current
/// color as full-precision RGB doubles. Nothing here is ever quantized to
/// 8 bits: the Percent column is the float value scaled by 100 in Double
/// arithmetic and both columns render with Swift's shortest round-trip
/// formatting, so a displayed text parses back to the exact same Double.
///
/// A draft that is not a finite number in range is refused: the color stays
/// unchanged and `lastError` carries an actionable message. Values are never
/// silently clamped.
@MainActor
final class ToolColorEditorModel {
    let target: ToolColorTarget
    private(set) var red: Double
    private(set) var green: Double
    private(set) var blue: Double
    /// The last refused draft's actionable message; nil after an accepted edit.
    private(set) var lastError: String?

    /// Called with the captured target and the opaque color after every
    /// accepted edit (numeric or well). Refused drafts never commit, and
    /// `syncExternal` never calls it, so external sampling cannot loop back.
    var onCommit: ((ToolColorTarget, NSColor) -> Void)?

    init(target: ToolColorTarget, color: NSColor) {
        self.target = target
        let srgb = color.usingColorSpace(.sRGB) ?? color
        self.red = Double(srgb.redComponent)
        self.green = Double(srgb.greenComponent)
        self.blue = Double(srgb.blueComponent)
    }

    /// The current color, always opaque: tool colors carry no alpha.
    var color: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    func component(_ component: ToolColorComponent) -> Double {
        switch component {
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// The Percent column text (0-100) at full precision.
    func percentText(_ component: ToolColorComponent) -> String {
        String(component(component) * 100)
    }

    /// The Float column text (0-1) in shortest round-trip form.
    func floatText(_ component: ToolColorComponent) -> String {
        String(component(component))
    }

    /// Applies a Percent-column draft for `component`. Refuses (false plus
    /// `lastError`, color unchanged, never clamped) anything that is not a
    /// finite number in 0...100.
    @discardableResult
    func applyPercentDraft(_ text: String, for component: ToolColorComponent) -> Bool {
        applyDraft(text, for: component, scale: 100, range: 0...100, column: "percent", rangeText: "0 to 100")
    }

    /// Applies a Float-column draft for `component`. Refuses anything that is
    /// not a finite number in 0...1.
    @discardableResult
    func applyFloatDraft(_ text: String, for component: ToolColorComponent) -> Bool {
        applyDraft(text, for: component, scale: 1, range: 0...1, column: "float", rangeText: "0 to 1")
    }

    /// Applies a color-well pick. Well colors arrive from AppKit already
    /// valid; alpha is dropped so the tool color stays opaque.
    func applyWellColor(_ picked: NSColor) {
        let srgb = picked.usingColorSpace(.sRGB) ?? picked
        red = Double(srgb.redComponent)
        green = Double(srgb.greenComponent)
        blue = Double(srgb.blueComponent)
        lastError = nil
        onCommit?(target, color)
    }

    /// Re-seeds from an external `ToolState` change (swap, reset, canvas
    /// sampling). Never commits, so it cannot loop back into `ToolState`.
    func syncExternal(_ external: NSColor) {
        let srgb = external.usingColorSpace(.sRGB) ?? external
        red = Double(srgb.redComponent)
        green = Double(srgb.greenComponent)
        blue = Double(srgb.blueComponent)
        lastError = nil
    }

    /// Whether `other` has exactly the current components (full-precision
    /// compare), used to ignore our own commits in the `ToolState` observer.
    func hasSameComponents(as other: NSColor) -> Bool {
        let srgb = other.usingColorSpace(.sRGB) ?? other
        return red == Double(srgb.redComponent)
            && green == Double(srgb.greenComponent)
            && blue == Double(srgb.blueComponent)
    }

    private func applyDraft(_ text: String, for component: ToolColorComponent, scale: Double,
                            range: ClosedRange<Double>, column: String, rangeText: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = Double(trimmed) else {
            return refuse(component, column: column,
                          "\(trimmed.isEmpty ? "no value" : "\"\(trimmed)\"") is not a number; enter a finite value from \(rangeText)")
        }
        guard parsed.isFinite else {
            return refuse(component, column: column,
                          "\(parsed) is not finite (NaN or infinity); enter a value from \(rangeText)")
        }
        guard range.contains(parsed) else {
            return refuse(component, column: column, "\(parsed) is outside \(rangeText)")
        }
        set(component, parsed / scale)
        return true
    }

    private func refuse(_ component: ToolColorComponent, column: String, _ reason: String) -> Bool {
        lastError = "\(component.name) \(column): \(reason). The color was left unchanged."
        return false
    }

    private func set(_ component: ToolColorComponent, _ value: Double) {
        switch component {
        case .red: red = value
        case .green: green = value
        case .blue: blue = value
        }
        lastError = nil
        onCommit?(target, color)
    }
}

/// The owned modeless tool color editor. One instance lives with the Tools
/// palette; a Foreground/Background click opens it for that captured global
/// `ToolState` target. It composes standard AppKit controls only: a native
/// `NSColorWell` for visual choosing plus Percent (0-100) and Float (0-1)
/// numeric columns for each RGB component, shown simultaneously.
///
/// Lifecycle: `open(target:)` captures the target and its current color NOW
/// and starts observing `ToolState`; `windowWillClose` stops the session
/// first, then deactivates the well and orders the shared color panel out
/// only when this session's own well activated it, so the panel is never
/// left belonging to the editor and a late well callback after close or
/// reopen cannot write any target. No dialogs are used.
@MainActor
final class ToolColorEditorController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private enum Column: Int {
        case percent, float
    }

    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var bindings: [(field: NSTextField, component: ToolColorComponent, column: Column)] = []

    /// The current session's model, recreated on every `open(target:)` so a
    /// callback can only ever see the currently captured target.
    private var model: ToolColorEditorModel?
    /// False while the window is closed; every callback bails on it.
    private var isOpen = false
    private var observerID: UUID?
    /// Whether the shared color panel was already visible when this session
    /// opened: only a panel this session's own well activated is ordered out.
    private var colorPanelWasVisibleAtOpen = false

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 288, height: 216),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Tool Color"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.appearance = EditorPreferences.shared.chromeAppearance
        panel.setFrameAutosaveName("Glims.toolColorEditor")
        buildContent(in: panel)
        panel.initialFirstResponder = bindings.first?.field
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: EditorPreferences.didChange, object: EditorPreferences.shared)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let observerID { ToolState.shared.removeObserver(observerID) }
    }

    // MARK: Opening and closing

    /// Opens (or re-targets) the editor for a global tool color. The target
    /// and its current color are captured now; a later document retarget
    /// cannot redirect this session.
    func open(target: ToolColorTarget) {
        if let observerID { ToolState.shared.removeObserver(observerID); self.observerID = nil }
        let model = ToolColorEditorModel(target: target, color: ToolState.shared[keyPath: target.keyPath])
        model.onCommit = { [weak self] committedTarget, color in self?.commit(target: committedTarget, color: color) }
        self.model = model
        isOpen = true
        colorPanelWasVisibleAtOpen = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        observerID = ToolState.shared.observe { [weak self] in self?.toolStateChanged() }
        window?.title = "\(target.title) Color"
        colorWell.setAccessibilityLabel("\(target.title) color well")
        refreshControls()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let first = bindings.first?.field {
            window?.makeFirstResponder(first)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // End the session first: a late well or panel callback during
        // teardown then finds no open session and cannot write any target.
        isOpen = false
        if let observerID { ToolState.shared.removeObserver(observerID); self.observerID = nil }
        // Release the shared color panel from this editor: the well is
        // deactivated so the panel no longer belongs to it, and the panel is
        // ordered out only when this session's own well activated it.
        if colorWell.isActive {
            if !colorPanelWasVisibleAtOpen, NSColorPanel.sharedColorPanelExists {
                NSColorPanel.shared.orderOut(nil)
            }
            colorWell.deactivate()
        }
        model = nil
    }

    // MARK: Synchronization

    /// Writes an accepted edit to the captured slot of the global `ToolState`.
    /// The resulting notification comes back through `toolStateChanged`, sees
    /// identical components and does nothing, so there is no feedback loop.
    private func commit(target: ToolColorTarget, color: NSColor) {
        guard isOpen, target == model?.target else { return }
        ToolState.shared[keyPath: target.keyPath] = color
        ToolState.shared.notifyChange()
    }

    /// External `ToolState` change (swap, reset, canvas sampling): re-seed
    /// the model and the controls, skipping any field being edited so a
    /// focused draft is never overwritten.
    private func toolStateChanged() {
        guard isOpen, let model else { return }
        let current = ToolState.shared[keyPath: model.target.keyPath]
        guard !model.hasSameComponents(as: current) else { return }
        model.syncExternal(current)
        refreshControls()
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard isOpen, sender === colorWell, let model else { return }
        model.applyWellColor(sender.color)
        refreshControls()
    }

    @objc private func preferencesChanged() {
        window?.appearance = EditorPreferences.shared.chromeAppearance
    }

    /// Pushes the model into the controls. A field the user is editing right
    /// now (it has a current editor) is left alone; the well is not rewritten
    /// while it is active, so the shared panel keeps driving it.
    private func refreshControls() {
        guard let model else { return }
        if !colorWell.isActive {
            colorWell.color = model.color
        }
        for binding in bindings where binding.field.currentEditor() == nil {
            switch binding.column {
            case .percent: binding.field.stringValue = model.percentText(binding.component)
            case .float: binding.field.stringValue = model.floatText(binding.component)
            }
        }
        if let error = model.lastError {
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = error
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
    }

    // MARK: NSTextFieldDelegate

    /// A numeric edit commits when editing ends, never while typing. A refused
    /// draft leaves the color unchanged; the field is restored to the
    /// unchanged value and the actionable error is shown.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isOpen, let model,
              let field = notification.object as? NSTextField,
              let binding = bindings.first(where: { $0.field === field }) else { return }
        switch binding.column {
        case .percent: _ = model.applyPercentDraft(field.stringValue, for: binding.component)
        case .float: _ = model.applyFloatDraft(field.stringValue, for: binding.component)
        }
        refreshControls()
    }

    // MARK: Content

    private static func makeNumericField() -> NSTextField {
        let field = NSTextField(string: "")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return field
    }

    private func buildContent(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        colorWell.target = self
        colorWell.action = #selector(wellChanged(_:))
        colorWell.setAccessibilityLabel("Tool color well")

        let wellCaption = NSTextField(labelWithString: "Well opens the shared color panel")
        wellCaption.font = .systemFont(ofSize: 11)
        wellCaption.textColor = .secondaryLabelColor
        let wellRow = NSStackView()
        wellRow.orientation = .horizontal
        wellRow.spacing = 8
        wellRow.alignment = .centerY

        let headerPercent = NSTextField(labelWithString: "Percent (0-100)")
        let headerFloat = NSTextField(labelWithString: "Float (0-1)")
        for header in [headerPercent, headerFloat] {
            header.font = .systemFont(ofSize: 11)
            header.textColor = .secondaryLabelColor
            header.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        var rows: [NSView] = [wellRow, headerRow]
        for view in [colorWell, wellCaption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            wellRow.addArrangedSubview(view)
        }
        for view in [spacer, headerPercent, headerFloat] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(view)
        }

        for component in ToolColorComponent.allCases {
            let nameLabel = NSTextField(labelWithString: component.name)
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.alignment = .right
            nameLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

            let percentField = Self.makeNumericField()
            percentField.setAccessibilityLabel("\(component.name) percent (0 to 100)")
            percentField.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let floatField = Self.makeNumericField()
            floatField.setAccessibilityLabel("\(component.name) float (0 to 1)")
            floatField.widthAnchor.constraint(equalToConstant: 100).isActive = true
            percentField.delegate = self
            floatField.delegate = self
            bindings.append((percentField, component, .percent))
            bindings.append((floatField, component, .float))

            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            for view in [nameLabel, percentField, floatField] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(view)
            }
            rows.append(row)
        }

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.setAccessibilityLabel("Color editor message")
        errorLabel.isHidden = true
        rows.append(errorLabel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}
