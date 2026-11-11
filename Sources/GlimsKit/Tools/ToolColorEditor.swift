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
        String(self.component(component) * 100)
    }

    /// The Float column text (0-1) in shortest round-trip form.
    func floatText(_ component: ToolColorComponent) -> String {
        String(self.component(component))
    }

    /// Applies a Percent-column draft for `component`. Refuses (false plus
    /// `lastError`, color unchanged, never clamped) anything that is not a
    /// finite number in 0...100.
    @discardableResult
    func applyPercentDraft(_ text: String, for component: ToolColorComponent) -> Bool {
        // An unchanged readout must not round-trip through multiply/divide
        // and perturb an otherwise unchanged floating-point component.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == percentText(component) {
            lastError = nil
            return true
        }
        return applyDraft(text, for: component, scale: 100, range: 0...100, column: "percent", rangeText: "0 to 100")
    }

    /// Applies a Float-column draft for `component`. Refuses anything that is
    /// not a finite number in 0...1.
    @discardableResult
    func applyFloatDraft(_ text: String, for component: ToolColorComponent) -> Bool {
        applyDraft(text, for: component, scale: 1, range: 0...1, column: "float", rangeText: "0 to 1")
    }

    /// Color lists can supply colors with no RGB components. Refuse those
    /// before component access; an AppKit exception cannot be caught in Swift.
    @discardableResult
    func applyWellColor(_ picked: NSColor) -> Bool {
        guard let srgb = picked.usingColorSpace(.sRGB) else {
            lastError = "This color cannot be converted to sRGB. Choose a solid color or enter RGB values."
            return false
        }
        let components = [Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            lastError = "Tool colors need finite RGB values from 0 to 1. The color was left unchanged."
            return false
        }
        red = components[0]
        green = components[1]
        blue = components[2]
        lastError = nil
        onCommit?(target, color)
        return true
    }

    /// Re-seeds from an external `ToolState` change (swap, reset, canvas
    /// sampling). Never commits, so it cannot loop back into `ToolState`.
    func syncExternal(_ external: NSColor) {
        let srgb = external.usingColorSpace(.sRGB) ?? external
        red = Double(srgb.redComponent)
        green = Double(srgb.greenComponent)
        blue = Double(srgb.blueComponent)
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
                          "the entry is not a number; enter a finite value from \(rangeText)")
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
        guard self.component(component) != value else {
            lastError = nil
            return
        }
        switch component {
        case .red: red = value
        case .green: green = value
        case .blue: blue = value
        }
        lastError = nil
        onCommit?(target, color)
    }
}

/// An owned modeless editor for the global foreground or background color.
/// Controls belong to one opening: callbacks from detached controls cannot
/// cross into a later opening or a different color target.
@MainActor
final class ToolColorEditorController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private enum Column: Equatable { case percent, float }

    private struct Binding {
        let field: NSTextField
        let component: ToolColorComponent
        let column: Column
    }

    @MainActor
    private final class Session {
        let id = UUID()
        let model: ToolColorEditorModel
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        let revertButton = NSButton(title: "Revert Entries", target: nil, action: nil)
        var bindings: [Binding] = []
        var drafts: [ObjectIdentifier: String] = [:]
        var errors: [ObjectIdentifier: String] = [:]
        var wellError: String?
        var observerID: UUID?
        var updatingControls = false
        var suppressEditingCallbacks = false
        let colorPanelWasVisible: Bool

        init(model: ToolColorEditorModel) {
            self.model = model
            colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        }
    }

    private let state: ToolState
    private var session: Session?

    init(state: ToolState? = nil) {
        self.state = state ?? .shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 266),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Tool Color"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.appearance = EditorPreferences.shared.chromeAppearance
        panel.setFrameAutosaveName("Glims.toolColorEditor")
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: EditorPreferences.didChange, object: EditorPreferences.shared)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A different target opens only after all existing drafts validate.
    /// Invalid entries remain visible in their original session for correction
    /// or an explicit Revert Entries action.
    @discardableResult
    func open(target: ToolColorTarget) -> Bool {
        if let current = session, current.model.target == target {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        guard finishDrafts() else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            return false
        }
        endSession()
        let model = ToolColorEditorModel(target: target, color: state[keyPath: target.keyPath])
        let current = Session(model: model)
        session = current
        let identity = current.id
        model.onCommit = { [weak self] committedTarget, color in
            guard let self, self.session?.id == identity,
                  committedTarget == self.session?.model.target else { return }
            self.session?.wellError = nil
            self.state[keyPath: committedTarget.keyPath] = color
            self.state.notifyChange()
        }
        current.observerID = state.observe { [weak self] in
            guard let self, let active = self.session, active.id == identity else { return }
            let color = self.state[keyPath: active.model.target.keyPath]
            guard !active.model.hasSameComponents(as: color) else { return }
            active.model.syncExternal(color)
            active.wellError = nil
            self.refreshControls(active)
        }
        buildContent(current)
        window?.title = "\(target.title) Color"
        refreshControls(current)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let first = current.bindings.first?.field { window?.makeFirstResponder(first) }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finishDrafts() }

    override func close() {
        guard finishDrafts() else { return }
        super.close()
    }

    func windowWillClose(_ notification: Notification) { endSession() }

    private func endSession() {
        guard let previous = session else { return }
        // Invalidate identity before ending editing/deactivating the well.
        session = nil
        previous.model.onCommit = nil
        if let observer = previous.observerID { state.removeObserver(observer) }
        previous.well.target = nil
        previous.well.action = nil
        for binding in previous.bindings { binding.field.delegate = nil }
        if previous.well.isActive {
            previous.well.deactivate()
            if !previous.colorPanelWasVisible, NSColorPanel.sharedColorPanelExists {
                NSColorPanel.shared.orderOut(nil)
            }
        }
        window?.makeFirstResponder(nil)
        window?.contentView = nil
    }

    /// Validate the whole unfinished form before committing or detaching any
    /// controls. A dry-run model has no commit callback, so an invalid entry
    /// cannot partly change the global color during a target switch.
    private func finishDrafts() -> Bool {
        guard let current = session else { return true }
        let candidate = ToolColorEditorModel(target: current.model.target, color: current.model.color)
        for binding in current.bindings {
            let key = ObjectIdentifier(binding.field)
            guard let text = current.drafts[key] else { continue }
            if !apply(text, binding: binding, model: candidate) {
                current.errors[key] = candidate.lastError
                refreshControls(current)
                window?.makeFirstResponder(binding.field)
                return false
            }
        }
        current.suppressEditingCallbacks = true
        let ended = window?.makeFirstResponder(nil) ?? true
        current.suppressEditingCallbacks = false
        guard ended else { return false }
        for binding in current.bindings {
            guard let text = current.drafts[ObjectIdentifier(binding.field)] else { continue }
            _ = apply(text, binding: binding, model: current.model)
        }
        current.drafts.removeAll()
        current.errors.removeAll()
        current.wellError = nil
        refreshControls(current)
        return true
    }

    private func apply(_ text: String, binding: Binding, model: ToolColorEditorModel) -> Bool {
        switch binding.column {
        case .percent: return model.applyPercentDraft(text, for: binding.component)
        case .float: return model.applyFloatDraft(text, for: binding.component)
        }
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard let current = session, sender === current.well, !current.updatingControls else { return }
        if !current.model.applyWellColor(sender.color) { current.wellError = current.model.lastError }
        refreshControls(current)
    }

    @objc private func revertEntries(_ sender: NSButton) {
        guard let current = session, sender === current.revertButton else { return }
        current.suppressEditingCallbacks = true
        window?.makeFirstResponder(nil)
        current.suppressEditingCallbacks = false
        current.drafts.removeAll()
        current.errors.removeAll()
        current.wellError = nil
        refreshControls(current)
    }

    @objc private func preferencesChanged() { window?.appearance = EditorPreferences.shared.chromeAppearance }

    private func refreshControls(_ current: Session) {
        guard session === current else { return }
        current.updatingControls = true
        defer { current.updatingControls = false }
        // NSColorWell programmatic changes do not send an action, but fence
        // any synchronous feedback as well. Active wells must also track
        // numeric edits and externally sampled tool colors.
        current.well.color = current.model.color
        for binding in current.bindings {
            let field = binding.field
            guard current.drafts[ObjectIdentifier(field)] == nil, field.currentEditor() == nil else { continue }
            field.stringValue = text(for: binding, model: current.model)
        }
        let error = current.bindings.compactMap { current.errors[ObjectIdentifier($0.field)] }.first ?? current.wellError
        current.errorLabel.stringValue = error.map { $0 + " Correct the entry or choose Revert Entries." } ?? ""
        current.errorLabel.isHidden = error == nil
        current.revertButton.isEnabled = !current.drafts.isEmpty || current.wellError != nil
    }

    private func text(for binding: Binding, model: ToolColorEditorModel) -> String {
        switch binding.column {
        case .percent: return model.percentText(binding.component)
        case .float: return model.floatText(binding.component)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let current = session, !current.updatingControls, !current.suppressEditingCallbacks,
              let field = notification.object as? NSTextField,
              current.bindings.contains(where: { $0.field === field }) else { return }
        current.drafts[ObjectIdentifier(field)] = field.currentEditor()?.string ?? field.stringValue
        current.revertButton.isEnabled = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let current = session, !current.suppressEditingCallbacks,
              let field = notification.object as? NSTextField,
              let binding = current.bindings.first(where: { $0.field === field }) else { return }
        let key = ObjectIdentifier(field)
        // Focusing a stale readout without typing must not overwrite a newer
        // external sample when the field finally loses focus.
        guard let draft = current.drafts[key] else {
            field.stringValue = text(for: binding, model: current.model)
            refreshControls(current)
            return
        }
        if apply(draft, binding: binding, model: current.model) {
            current.drafts[key] = nil
            current.errors[key] = nil
            field.stringValue = text(for: binding, model: current.model)
        } else {
            current.errors[key] = current.model.lastError
        }
        refreshControls(current)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let current = session,
              let binding = current.bindings.first(where: { $0.field === control }) else { return false }
        let key = ObjectIdentifier(binding.field)
        current.drafts[key] = nil
        current.errors[key] = nil
        let value = text(for: binding, model: current.model)
        binding.field.stringValue = value
        textView.string = value
        refreshControls(current)
        return true
    }

    private func buildContent(_ current: Session) {
        let content = NSView()
        window?.contentView = content
        current.well.target = self
        current.well.action = #selector(wellChanged(_:))
        current.well.setAccessibilityLabel("\(current.model.target.title) color well")
        current.revertButton.target = self
        current.revertButton.action = #selector(revertEntries(_:))
        current.revertButton.controlSize = .small
        current.revertButton.setAccessibilityLabel("Revert uncommitted color entries")

        let wellRow = NSStackView(views: [current.well, NSTextField(labelWithString: "Choose a color or enter RGB values.")])
        wellRow.orientation = .horizontal
        wellRow.spacing = 8
        wellRow.alignment = .centerY
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let percentHeader = NSTextField(labelWithString: "Percent (0–100)")
        let floatHeader = NSTextField(labelWithString: "Float (0–1)")
        for header in [percentHeader, floatHeader] {
            header.font = .systemFont(ofSize: 11)
            header.textColor = .secondaryLabelColor
            header.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        let header = NSStackView(views: [spacer, percentHeader, floatHeader])
        header.spacing = 6
        var rows: [NSView] = [wellRow, header]
        for component in ToolColorComponent.allCases {
            let caption = NSTextField(labelWithString: component.name)
            caption.alignment = .right
            caption.widthAnchor.constraint(equalToConstant: 44).isActive = true
            var fields: [NSView] = [caption]
            for column in [Column.percent, .float] {
                let field = NSTextField(string: "")
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.widthAnchor.constraint(equalToConstant: 160).isActive = true
                field.delegate = self
                let unit = column == .percent ? "percent (0 to 100)" : "float (0 to 1)"
                field.setAccessibilityLabel("\(component.name) \(unit)")
                field.toolTip = "Enter a finite value using a period for the decimal separator. Escape reverts this entry."
                current.bindings.append(Binding(field: field, component: component, column: column))
                fields.append(field)
            }
            let row = NSStackView(views: fields)
            row.spacing = 6
            rows.append(row)
        }
        current.errorLabel.font = .systemFont(ofSize: 11)
        current.errorLabel.textColor = .systemRed
        current.errorLabel.setAccessibilityLabel("Color editor message")
        current.errorLabel.isHidden = true
        let footer = NSStackView(views: [current.revertButton])
        footer.alignment = .centerY
        rows += [current.errorLabel, footer]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            current.errorLabel.widthAnchor.constraint(equalToConstant: 376),
        ])
        window?.initialFirstResponder = current.bindings.first?.field
        window?.recalculateKeyViewLoop()
    }
}
