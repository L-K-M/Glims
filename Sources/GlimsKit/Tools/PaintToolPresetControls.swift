import AppKit

/// The pure, value-based rules behind the Presets panel (docs/tool-preset-controls.md):
/// capturing the current paint tool's stable settings into a preset value,
/// and applying a preset back to a `ToolState`. No windows, no engine calls —
/// the resource identity is only handed to `ToolState.setBrushResource`, which
/// persists it through the brush store; the native resolve stays on the
/// normal worker stroke. Unit tests drive this directly with an injected
/// `ToolState` + UserDefaults-backed stores.
@MainActor
enum PaintToolPresetControls {

    /// Every stable `EngineSession.Brush` setting, minus the transient and
    /// derived fields: `source` (the clone/heal source point) and the
    /// per-read `tool`/color are never captured, and no session `ResourceID`
    /// handle exists in a `Brush` value.
    static func captureSettings(from brush: EngineSession.Brush) -> PaintToolPreset.Settings {
        PaintToolPreset.Settings(size: brush.size, opacity: brush.opacity,
                                 pressureSize: brush.pressureSize, hardness: brush.hardness,
                                 rate: brush.rate, flow: brush.flow, exposure: brush.exposure,
                                 tones: PaintToolPreset.ToneRange(brushTones: brush.tones),
                                 antiErase: brush.antiErase)
    }

    /// The chosen brush resource as a typed `.brush` reference, or nil for
    /// the native default brush. Only the identity is captured, never a
    /// session handle.
    static func captureBrushResource(from brush: EngineSession.Brush) -> PaintToolPreset.BrushResource? {
        brush.resource.map { PaintToolPreset.BrushResource($0) }
    }

    /// The foreground color as sRGB primitive components — but only when
    /// `include` is set: capturing the color is a deliberate, explicit choice
    /// (the panel's checkbox), never implied by the brush settings. Returns
    /// nil when not included, or when the color has no finite sRGB form.
    static func captureForeground(_ color: NSColor, include: Bool) -> PaintToolPreset.SRGBColor? {
        guard include else { return nil }
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return PaintToolPreset.SRGBColor(red: components[0], green: components[1], blue: components[2])
    }

    /// Applies `preset` to the global `state`: selects the preset's tool,
    /// copies EVERY stable brush field, and hands the resource identity to
    /// `setBrushResource(_:for:)` so the choice persists through the existing
    /// brushStore path (nil resets to the native Default). The global
    /// foreground changes only when the preset carries an explicit color.
    ///
    /// `ToolState.cloneSource` is deliberately untouched: `update` and
    /// `setBrushResource` never write it, so the current clone/heal source
    /// point survives an apply exactly — a clone/heal preset does NOT restore
    /// its source point (docs/paint-tool-presets.md), and nothing here
    /// pretends otherwise. The derived per-read `tool`/color/`source` fields
    /// of `Brush` are not written either; `brush(for:)` derives them.
    static func apply(_ preset: PaintToolPreset, to state: ToolState) {
        state.select(preset.tool)
        state.update(preset.tool) { brush in
            if let paintTool = preset.tool.paintTool { brush.tool = paintTool }
            brush.size = preset.settings.size
            brush.opacity = preset.settings.opacity
            brush.pressureSize = preset.settings.pressureSize
            brush.hardness = preset.settings.hardness
            brush.rate = preset.settings.rate
            brush.flow = preset.settings.flow
            brush.exposure = preset.settings.exposure
            brush.tones = preset.settings.tones.brushTones
            brush.antiErase = preset.settings.antiErase
        }
        state.setBrushResource(preset.brushResource?.identity, for: preset.tool)
        if let color = preset.foregroundColor {
            state.foreground = NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                                       blue: CGFloat(color.blue), alpha: 1)
        }
    }

    /// The row of preset `id`, or nil when it is gone: selection follows the
    /// UUID across reloads, never a row index, and a gone UUID is never
    /// silently replaced by the first row.
    static func index(of id: UUID, in presets: [PaintToolPreset]) -> Int? {
        presets.firstIndex { $0.id == id }
    }
}

/// The ONE retained presets panel for the global `ToolState`, opened from
/// Tool Options' "Presets…" action for paint tools. It owns a table of the
/// stored presets (the current paint tool's, or every tool's behind the
/// explicit "All tools" filter), a name field, the deliberate "Include
/// foreground color" checkbox, and Save Current / Rename / Update / Delete /
/// Apply / Close. Selection is tracked by UUID and preserved across reloads;
/// every store/name failure is shown inline and never resets or rewrites the
/// stored data. No engine calls and no document state: the panel only reads
/// `ToolState` and the store, so an in-flight stroke snapshot is never
/// touched. Tests and the smoke test inject their own `ToolState`/store.
@MainActor
final class PaintToolPresetPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = PaintToolPresetPanelController(toolState: .shared, store: .shared)

    let toolState: ToolState
    let store: PaintToolPresetStore

    private(set) var isOpen = false
    /// The rows as displayed: the current paint tool's presets, or every
    /// preset behind the explicit All-tools filter.
    private(set) var rows: [PaintToolPreset] = []
    /// The selected preset by UUID; preserved across reloads by UUID, cleared
    /// when the UUID is gone (never substituted by another row).
    private(set) var selectedPresetID: UUID?
    /// The last store/name error, shown inline in the panel.
    private(set) var lastError: String?
    /// The explicit, transparent filter: false shows only the current paint
    /// tool's presets.
    var showsAllTools = false

    let tableView = PresetTableView()
    private let allToolsCheckbox = NSButton(checkboxWithTitle: "All tools", target: nil, action: nil)
    private let nameField = NSTextField()
    private let includeForegroundCheckbox = NSButton(checkboxWithTitle: "Include foreground color", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Current", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var observer: UUID?

    init(toolState: ToolState, store: PaintToolPresetStore) {
        self.toolState = toolState
        self.store = store
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Presets"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        // Follow the global tool: the current-tool filter and the Save Current
        // capture track the tool the user switches to while the panel is open.
        observer = toolState.observe { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    private func buildContent(in panel: NSPanel) {
        for (button, label, action) in [
            (saveButton, "Save current settings as preset", #selector(saveCurrent(_:))),
            (renameButton, "Rename selected preset", #selector(renameSelected(_:))),
            (updateButton, "Update selected preset with current settings", #selector(updateSelected(_:))),
            (deleteButton, "Delete selected preset", #selector(deleteSelected(_:))),
            (applyButton, "Apply selected preset", #selector(applySelected(_:))),
            (closeButton, "Close presets panel", #selector(closePanel(_:))),
        ] as [(NSButton, String, Selector)] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        allToolsCheckbox.controlSize = .small
        allToolsCheckbox.font = .systemFont(ofSize: 11)
        allToolsCheckbox.toolTip = "Show the presets of every paint tool instead of only the current tool's"
        allToolsCheckbox.setAccessibilityLabel("All tools filter")
        allToolsCheckbox.target = self
        allToolsCheckbox.action = #selector(allToolsChanged(_:))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.setAccessibilityLabel("Presets list")
        tableView.doubleAction = #selector(applySelected(_:))
        tableView.onCommit = { [weak self] in self?.applySelected(nil) }
        tableView.onCancel = { [weak self] in self?.closePanel(nil) }
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 200
        let toolColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tool"))
        toolColumn.title = "Tool"
        toolColumn.width = 120
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(toolColumn)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        nameField.placeholderString = "Preset name"
        nameField.font = .systemFont(ofSize: 12)
        nameField.setAccessibilityLabel("Preset name")
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6

        includeForegroundCheckbox.controlSize = .small
        includeForegroundCheckbox.font = .systemFont(ofSize: 11)
        includeForegroundCheckbox.toolTip = "Capture the current foreground color into the preset (applied only when the preset carries it)"
        includeForegroundCheckbox.setAccessibilityLabel("Include foreground color")

        saveButton.toolTip = "Save the current tool's settings as a new preset"
        renameButton.toolTip = "Rename the selected preset"
        updateButton.toolTip = "Replace the selected preset's snapshot with its tool's current settings"
        deleteButton.toolTip = "Delete the selected preset"
        applyButton.toolTip = "Apply the selected preset to the current tool settings"
        closeButton.toolTip = "Close this panel"
        applyButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityLabel("Preset message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3

        let editingRow = NSStackView(views: [saveButton, renameButton, updateButton, deleteButton])
        editingRow.orientation = .horizontal
        editingRow.spacing = 6
        editingRow.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let panelRow = NSStackView(views: [applyButton, closeButton])
        panelRow.orientation = .horizontal
        panelRow.spacing = 6
        panelRow.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let stack = NSStackView(views: [allToolsCheckbox, scroll, nameRow, includeForegroundCheckbox,
                                        editingRow, panelRow, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        // The minimum size fits every control: shrinking the panel can never
        // hide a button, the list or the message line.
        let fit = stack.fittingSize
        panel.setContentSize(fit)
        panel.contentMinSize = fit
        panel.initialFirstResponder = tableView
        reload()
    }

    // MARK: Open / close

    /// Opens (or focuses) the retained panel and reloads from the store.
    func open() {
        reload()
        isOpen = true
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(tableView)
    }

    @objc func closePanel(_ sender: Any?) {
        isOpen = false
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
    }

    // MARK: Reload and selection

    /// Reloads the rows from the store. The selection is preserved by UUID;
    /// a gone UUID is cleared, never replaced by another row. A load failure
    /// (unreadable or unknown-schema document) shows the actionable error and
    /// keeps the last readable rows — it never resets or overwrites the
    /// stored bytes.
    func reload() {
        let previous = selectedPresetID
        do {
            let all = try store.load()
            rows = showsAllTools ? all : all.filter { $0.tool == toolState.current }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        tableView.reloadData()
        if let previous, let row = PaintToolPresetControls.index(of: previous, in: rows) {
            selectedPresetID = previous
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            selectedPresetID = nil
            if tableView.selectedRow != -1 { tableView.deselectAll(nil) }
        }
        refreshMessage()
        updateControlStates()
    }

    @objc private func allToolsChanged(_ sender: NSButton) {
        showsAllTools = sender.state == .on
        reload()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if rows.indices.contains(row) {
            selectedPresetID = rows[row].id
            // Do not clobber a name the user is editing inline.
            if nameField.currentEditor() == nil { nameField.stringValue = rows[row].name }
        } else {
            selectedPresetID = nil
            if nameField.currentEditor() == nil { nameField.stringValue = "" }
        }
        updateControlStates()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let preset = rows[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = text
        text.stringValue = tableColumn?.identifier.rawValue == "tool" ? preset.tool.name : preset.name
        return cell
    }

    private func updateControlStates() {
        let hasSelection = selectedPresetID != nil && rows.contains(where: { $0.id == selectedPresetID })
        renameButton.isEnabled = hasSelection
        updateButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        applyButton.isEnabled = hasSelection
        saveButton.isEnabled = toolState.current.paintTool != nil
    }

    private func showError(_ message: String) {
        lastError = message
        refreshMessage()
    }

    private func refreshMessage() {
        if let lastError {
            messageLabel.textColor = .systemRed
            messageLabel.stringValue = lastError
        } else {
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.stringValue = ""
        }
    }

    /// Captures the given tool's current brush by value; the foreground color
    /// only when `includeForeground` is set. Returns nil with an inline error
    /// when the color was requested but has no finite sRGB form.
    private func capturedValues(for tool: ToolID, includeForeground: Bool) -> (settings: PaintToolPreset.Settings,
                                                                                 resource: PaintToolPreset.BrushResource?,
                                                                                 color: PaintToolPreset.SRGBColor?)? {
        let brush = toolState.brush(for: tool)
        let color = PaintToolPresetControls.captureForeground(toolState.foreground, include: includeForeground)
        if includeForeground && color == nil {
            showError("The foreground color must be convertible to sRGB to be captured.")
            return nil
        }
        return (PaintToolPresetControls.captureSettings(from: brush),
                PaintToolPresetControls.captureBrushResource(from: brush),
                color)
    }

    // MARK: Actions

    /// Save Current: stores the current paint tool's settings under the name
    /// field's text as a new preset and selects it by UUID. Store/name errors
    /// (empty, overlong or duplicate name, non-paint tool, unreadable stored
    /// document) are shown inline; nothing is written on failure.
    @objc func saveCurrent(_ sender: Any?) {
        saveCurrent(name: nameField.stringValue, includeForeground: includeForegroundCheckbox.state == .on)
    }

    func saveCurrent(name: String, includeForeground: Bool) {
        let tool = toolState.current
        guard tool.paintTool != nil else {
            showError(PaintToolPresetError.nonPaintTool(tool).description)
            return
        }
        guard let captured = capturedValues(for: tool, includeForeground: includeForeground) else { return }
        do {
            let created = try store.create(tool: tool, name: name, settings: captured.settings,
                                           brushResource: captured.resource, foregroundColor: captured.color)
            lastError = nil
            reload()
            selectedPresetID = created.id
            if let row = PaintToolPresetControls.index(of: created.id, in: rows) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if nameField.currentEditor() == nil { nameField.stringValue = created.name }
        } catch {
            // The store threw before writing: the stored bytes and the rows
            // stay as they were; only the inline message changes.
            showError("\(error)")
        }
        refreshMessage()
        updateControlStates()
    }

    /// Rename: renames the selected preset (UUID, position and snapshot
    /// stay); the name is stored trimmed. Errors are shown inline.
    @objc func renameSelected(_ sender: Any?) {
        renameSelected(to: nameField.stringValue)
    }

    func renameSelected(to name: String) {
        guard let id = selectedPresetID else { return }
        do {
            try store.rename(id: id, to: name)
            lastError = nil
        } catch {
            showError("\(error)")
            return
        }
        reload()
        if let preset = rows.first(where: { $0.id == id }), nameField.currentEditor() == nil {
            nameField.stringValue = preset.name
        }
    }

    /// Update: replaces the selected preset's snapshot with its own tool's
    /// current settings (and the foreground color when the checkbox is on).
    @objc func updateSelected(_ sender: Any?) {
        updateSelected(includeForeground: includeForegroundCheckbox.state == .on)
    }

    func updateSelected(includeForeground: Bool) {
        guard let id = selectedPresetID, let preset = rows.first(where: { $0.id == id }) else { return }
        guard let captured = capturedValues(for: preset.tool, includeForeground: includeForeground) else { return }
        do {
            try store.replace(id: id, settings: captured.settings, brushResource: captured.resource,
                              foregroundColor: captured.color)
            lastError = nil
        } catch {
            showError("\(error)")
            return
        }
        reload()
    }

    /// Delete: removes the selected preset; the selection is cleared (the UUID
    /// is gone), never substituted by another row.
    @objc func deleteSelected(_ sender: Any?) {
        deleteSelected()
    }

    func deleteSelected() {
        guard let id = selectedPresetID else { return }
        do {
            try store.delete(id: id)
            lastError = nil
            reload()
        } catch {
            reload()
            showError("\(error)")
        }
    }

    /// Apply: selects the preset's tool and copies every stable field, the
    /// resource identity (persisted through the brushStore path) and — only
    /// when the preset carries one — the foreground color. The current
    /// cloneSource is preserved exactly. Pure `ToolState` writes; no engine
    /// call, no document state, no stroke snapshot is touched.
    @objc func applySelected(_ sender: Any?) {
        applySelected()
    }

    func applySelected() {
        guard let id = selectedPresetID else { return }
        do {
            guard let preset = try store.load().first(where: { $0.id == id }) else {
                throw PaintToolPresetError.unknownPreset(id)
            }
            PaintToolPresetControls.apply(preset, to: toolState)
            lastError = nil
            reload()
        } catch {
            reload()
            showError("\(error)")
        }
    }
}

/// The presets list: Return/Enter applies the selected preset, Escape closes,
/// and the first click is accepted even when the panel is not key.
final class PresetTableView: NSTableView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()        // return / keypad enter
        case 53: onCancel?()            // escape
        default: super.keyDown(with: event)
        }
    }
}
