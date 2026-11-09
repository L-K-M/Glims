import AppKit

/// The Keyboard Shortcuts… panel: a searchable list of the built-in menu
/// commands (shown with their menu path), a literal character key field
/// with Command/Shift/Option/Control checkboxes and a function-key picker,
/// and Assign / Disable / Reset Selected / Reset All / Close. Errors are
/// persistent and visible in the panel's own line.
///
/// No global or event key capture: the key field is read literally when
/// Assign is clicked. Mutations go through the manager, which validates the
/// full catalog and persists before the menu or this panel changes.
@MainActor
final class KeyboardShortcutsPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    private let manager: MenuShortcutManager
    var onClose: (() -> Void)?

    // MARK: Controls (internal so tests and the smoke test can drive them)

    let searchField = NSSearchField()
    let table = NSTableView()
    let keyField = NSTextField()
    let commandCheck = NSButton(checkboxWithTitle: "⌘ Command", target: nil, action: nil)
    let shiftCheck = NSButton(checkboxWithTitle: "⇧ Shift", target: nil, action: nil)
    let optionCheck = NSButton(checkboxWithTitle: "⌥ Option", target: nil, action: nil)
    let controlCheck = NSButton(checkboxWithTitle: "⌃ Control", target: nil, action: nil)
    let functionPicker = NSPopUpButton()
    let assignButton = NSButton(title: "Assign", target: nil, action: nil)
    let disableButton = NSButton(title: "Disable", target: nil, action: nil)
    let resetSelectedButton = NSButton(title: "Reset Selected", target: nil, action: nil)
    let resetAllButton = NSButton(title: "Reset All", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")

    /// The function tag chosen in the picker, if any; the key field then
    /// exposes that read-only model key.
    private var pendingFunctionTag: String?
    private var filteredRows: [MenuShortcutManager.Row] = []
    /// The last mutation error; stays visible until a mutation succeeds.
    private var lastError: String?

    init(manager: MenuShortcutManager) {
        self.manager = manager
        let window = ShortcutsPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        reloadFromManager()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Interface

    private func buildInterface() {
        guard let window else { return }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search commands"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search commands")

        let commandColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        commandColumn.title = "Command"
        commandColumn.width = 300
        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "Shortcut"
        shortcutColumn.width = 110
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 80
        table.addTableColumn(commandColumn)
        table.addTableColumn(shortcutColumn)
        table.addTableColumn(statusColumn)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Commands list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.headerView?.isHidden = false

        keyField.placeholderString = "Type one character"
        keyField.delegate = self
        keyField.setAccessibilityLabel("Shortcut key")
        functionPicker.target = self
        functionPicker.action = #selector(functionKeyChanged(_:))
        functionPicker.setAccessibilityLabel("Function key")
        rebuildFunctionPicker()

        for button in [assignButton, disableButton, resetSelectedButton, resetAllButton, closeButton] {
            button.bezelStyle = .rounded
        }
        assignButton.target = self
        assignButton.action = #selector(assignClicked(_:))
        assignButton.setAccessibilityLabel("Assign shortcut")
        disableButton.target = self
        disableButton.action = #selector(disableClicked(_:))
        disableButton.setAccessibilityLabel("Disable shortcut")
        resetSelectedButton.target = self
        resetSelectedButton.action = #selector(resetSelectedClicked(_:))
        resetSelectedButton.setAccessibilityLabel("Reset selected shortcut")
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAllClicked(_:))
        resetAllButton.setAccessibilityLabel("Reset all shortcuts")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.setAccessibilityLabel("Close keyboard shortcuts panel")

        let modifierRow = NSStackView(views: [commandCheck, shiftCheck, optionCheck, controlCheck])
        modifierRow.orientation = .horizontal
        modifierRow.spacing = 10

        let editor = NSStackView(views: [label("Key"), keyField, label("Function Key"), functionPicker, modifierRow])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 6
        keyField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        functionPicker.widthAnchor.constraint(equalToConstant: 160).isActive = true

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityLabel("Shortcut panel error")

        let buttons = NSStackView(views: [assignButton, disableButton, resetSelectedButton, resetAllButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let middle = NSStackView(views: [scroll, editor])
        middle.orientation = .horizontal
        middle.spacing = 16
        middle.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        let stack = NSStackView(views: [searchField, middle, errorLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        return field
    }

    private static let namedFunctionTitles: [String: String] = [
        "upArrow": "Up Arrow", "downArrow": "Down Arrow", "leftArrow": "Left Arrow", "rightArrow": "Right Arrow",
        "insert": "Insert", "delete": "Delete", "home": "Home", "end": "End",
        "pageUp": "Page Up", "pageDown": "Page Down", "printScreen": "Print Screen",
        "scrollLock": "Scroll Lock", "pause": "Pause", "sysReq": "Sys Req", "break": "Break",
        "reset": "Reset", "print": "Print", "help": "Help",
    ]

    /// Human titles for every function tag the model knows.
    static func functionKeyTitle(_ tag: String) -> String {
        if let named = namedFunctionTitles[tag] { return named }
        if tag.hasPrefix("f"), let number = Int(tag.dropFirst()) { return "F\(number)" }
        return tag
    }

    /// The picker lists exactly the model's function keys (read-only model
    /// keys) plus a "Character…" entry for the literal key field.
    private func rebuildFunctionPicker() {
        functionPicker.removeAllItems()
        functionPicker.addItem(withTitle: "Character…")
        functionPicker.lastItem?.representedObject = nil
        for scalar in ShortcutKey.functionKeyTags.keys.sorted() {
            let tag = ShortcutKey.functionKeyTags[scalar]!
            functionPicker.addItem(withTitle: Self.functionKeyTitle(tag))
            functionPicker.lastItem?.representedObject = tag
        }
    }

    // MARK: Rows

    var errorText: String { errorLabel.stringValue }

    private var searchText: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refilter() {
        let query = searchText.lowercased()
        filteredRows = manager.rows.filter { row in
            query.isEmpty
                || row.pathLabel.lowercased().contains(query)
                || row.id.lowercased().contains(query)
                || (row.shortcut.map { Self.displayString(for: $0).lowercased().contains(query) } ?? false)
        }
        table.reloadData()
    }

    /// Reloads the list, the editor and the persistent error line from the
    /// manager. Called by the manager after every mutation too.
    func reloadFromManager() {
        refilter()
        updateErrorLine()
        updateEditorForSelection()
    }

    private func updateErrorLine() {
        if let lastError {
            errorLabel.stringValue = lastError
        } else if let loadError = manager.loadError {
            errorLabel.stringValue = loadError.localizedDescription
        } else {
            errorLabel.stringValue = ""
        }
    }

    // MARK: Selection and editor

    var selectedRow: MenuShortcutManager.Row? {
        let row = table.selectedRow
        guard row >= 0, row < filteredRows.count else { return nil }
        return filteredRows[row]
    }

    /// Selects the row of a command id (used by tests and the smoke test).
    func selectCommand(_ id: String) {
        guard let index = filteredRows.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateEditorForSelection()
    }

    private func updateEditorForSelection() {
        guard let row = selectedRow else {
            assignButton.isEnabled = false
            disableButton.isEnabled = false
            resetSelectedButton.isEnabled = false
            keyField.isEnabled = false
            functionPicker.isEnabled = false
            return
        }
        let shortcut = row.override.map { override -> KeyboardShortcut? in
            if case .assign(let shortcut) = override { return shortcut }
            return nil
        } ?? row.base
        if let shortcut {
            keyField.stringValue = shortcut.key.value
            commandCheck.state = shortcut.modifiers.contains(.command) ? .on : .off
            shiftCheck.state = shortcut.modifiers.contains(.shift) ? .on : .off
            optionCheck.state = shortcut.modifiers.contains(.option) ? .on : .off
            controlCheck.state = shortcut.modifiers.contains(.control) ? .on : .off
            if ShortcutKey.knownTags.contains(shortcut.key.value) {
                pendingFunctionTag = shortcut.key.value
                functionPicker.selectItem(withTitle: Self.functionKeyTitle(shortcut.key.value))
            } else {
                pendingFunctionTag = nil
                functionPicker.selectItem(at: 0)
            }
        } else {
            keyField.stringValue = ""
            for check in [commandCheck, shiftCheck, optionCheck, controlCheck] { check.state = .off }
            pendingFunctionTag = nil
            functionPicker.selectItem(at: 0)
        }
        // A macOS-reserved owner is read-only: no assign, disable or reset.
        let editable = !row.reservedOwner
        assignButton.isEnabled = editable
        disableButton.isEnabled = editable
        resetSelectedButton.isEnabled = editable
        keyField.isEnabled = editable
        functionPicker.isEnabled = editable
        for check in [commandCheck, shiftCheck, optionCheck, controlCheck] { check.isEnabled = editable }
    }

    // MARK: Actions

    @objc private func searchChanged(_ sender: Any?) { refilter() }

    @objc private func functionKeyChanged(_ sender: NSPopUpButton) {
        pendingFunctionTag = sender.selectedItem?.representedObject as? String
        if let tag = pendingFunctionTag {
            // Expose the read-only model key in the field.
            keyField.stringValue = tag
            keyField.isEditable = false
        } else {
            keyField.isEditable = true
            keyField.stringValue = ""
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        // Typing a literal character leaves the function-key picker.
        pendingFunctionTag = nil
        keyField.isEditable = true
        functionPicker.selectItem(at: 0)
    }

    private func editorShortcut() -> KeyboardShortcut? {
        let key: ShortcutKey?
        if let tag = pendingFunctionTag {
            key = ShortcutKey(persisted: tag)
        } else {
            key = ShortcutKey(input: keyField.stringValue)
        }
        guard let key else { return nil }
        var modifiers: ShortcutModifiers = []
        if commandCheck.state == .on { modifiers.insert(.command) }
        if shiftCheck.state == .on { modifiers.insert(.shift) }
        if optionCheck.state == .on { modifiers.insert(.option) }
        if controlCheck.state == .on { modifiers.insert(.control) }
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    @objc private func assignClicked(_ sender: Any?) {
        guard let row = selectedRow else { return }
        guard let shortcut = editorShortcut() else {
            lastError = KeyboardShortcutError.invalidKey(keyField.stringValue).localizedDescription
            updateErrorLine()
            return
        }
        do {
            try manager.assign(shortcut, to: row.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updateErrorLine()
        updateEditorForSelection()
    }

    @objc private func disableClicked(_ sender: Any?) {
        guard let row = selectedRow else { return }
        do {
            try manager.disable(row.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updateErrorLine()
        updateEditorForSelection()
    }

    @objc private func resetSelectedClicked(_ sender: Any?) {
        guard let row = selectedRow else { return }
        do {
            try manager.reset(row.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updateErrorLine()
        updateEditorForSelection()
    }

    @objc private func resetAllClicked(_ sender: Any?) {
        do {
            try manager.resetAll()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updateErrorLine()
        updateEditorForSelection()
    }

    @objc private func closeClicked(_ sender: Any?) {
        manager.closePanel()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filteredRows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < filteredRows.count else { return nil }
        let item = filteredRows[row]
        switch tableColumn?.identifier.rawValue {
        case "command": return item.pathLabel
        case "shortcut": return item.shortcut.map { Self.displayString(for: $0) } ?? "—"
        case "status":
            if item.reservedOwner { return "System" }
            switch item.override {
            case .none: return "Factory"
            case .some(.assign): return "Custom"
            case .some(.disable): return "Disabled"
            }
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateEditorForSelection()
    }

    // MARK: Display

    /// A UI-only rendering of a shortcut (symbols, never stored).
    static func displayString(for shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("⌘") }
        if shortcut.modifiers.contains(.control) { parts.append("⌃") }
        if shortcut.modifiers.contains(.option) { parts.append("⌥") }
        if shortcut.modifiers.contains(.shift) { parts.append("⇧") }
        if ShortcutKey.knownTags.contains(shortcut.key.value) {
            parts.append(functionKeyTitle(shortcut.key.value))
        } else {
            parts.append(shortcut.key.value.uppercased())
        }
        return parts.joined()
    }
}

// MARK: - Window delegate

@MainActor
extension KeyboardShortcutsPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private final class ShortcutsPanel: NSPanel {}
