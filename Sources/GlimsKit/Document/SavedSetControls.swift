import AppKit

/// The pure, UI-free rules behind View ▸ Saved Sets…: the kind chooser,
/// the full-name contract, the token-addressed row model (the token, never
/// the label, is the identity), cached admission, member/request
/// validation, all-kinds recall admission and the phase machine.
enum SavedSetControlsLogic {
    struct Rejection: Error, Equatable {
        let message: String
    }
    static let nameMaxUTF8Bytes = 255
    static let kinds: [(EngineSession.ItemSetKind, String)] = [
        (.layer, "Layers"), (.channel, "Channels"), (.path, "Paths"),
    ]

    static func kindTitle(_ kind: EngineSession.ItemSetKind) -> String {
        kinds.first { $0.0 == kind }?.1 ?? "Layers"
    }

    /// The saved-set full name: nonempty, no NUL, no control characters
    /// (Cc, what the native side rejects), at most 255 UTF-8 bytes.
    static func validateName(_ text: String) -> Result<String, Rejection> {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty else {
            return .failure(Rejection(message: "The name must not be empty."))
        }
        guard !utf8.contains(0) else {
            return .failure(Rejection(message: "The name must not contain a NUL character."))
        }
        guard utf8.count <= nameMaxUTF8Bytes else {
            return .failure(Rejection(message: "The name must be at most \(nameMaxUTF8Bytes) UTF-8 bytes (it is \(utf8.count))."))
        }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(Rejection(message: "The name must not contain control characters."))
        }
        return .success(text)
    }

    /// The rename draft's seed: always empty. The display label may be
    /// truncated, so it is never a valid seed for the FULL new name.
    static func initialRenameDraft(displayName: String) -> String { "" }

    /// One table row: the slot-133 row plus the slot-134 current member ids
    /// of the same token. The token is the identity; label and count are
    /// read-only presentation bound to it.
    struct Row: Equatable {
        let token: UInt64
        let kind: EngineSession.ItemSetKind
        let displayName: String
        let memberCount: Int
        let members: [Int32]

        init(set: EngineSession.ItemSet, members: [Int32]) {
            self.token = set.token
            self.kind = set.kind
            self.displayName = set.displayName
            self.memberCount = set.memberCount
            self.members = members
        }
    }
    static func rows(ofKind kind: EngineSession.ItemSetKind, in rows: [Row]) -> [Row] {
        rows.filter { $0.kind == kind }
    }

    /// The selection a reload preserves: the same token while still listed,
    /// else nil — never matched through a label (a same-named recreated set
    /// has a fresh token and inherits nothing).
    static func preservedSelection(_ token: UInt64?, in rows: [Row]) -> UInt64? {
        guard let token, token != 0, rows.contains(where: { $0.token == token }) else { return nil }
        return token
    }
    static func readIsCurrent(generation: Int, current: Int) -> Bool {
        generation == current
    }

    /// The cached-state reason a mutation cannot be accepted now, or nil —
    /// pure flags in, reason out, no native call.
    static func writeAdmission(isClosing: Bool, isSavingForClose: Bool, isTransferringClipboard: Bool,
                               pluginRunning: Bool, engineBusy: Bool, previewOpen: Bool) -> String? {
        if isClosing { return ImageDocument.DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard { return ImageDocument.DocumentError.busy.localizedDescription }
        if engineBusy, !pluginRunning { return "Wait for the current image operation to finish." }
        if previewOpen { return "Apply or cancel the filter preview first." }
        if pluginRunning { return "Finish or cancel the running plug-in first." }
        return nil
    }

    /// The explicit member list: ids positive (0 never means "the current
    /// selection") and unique; empty is an explicit empty set.
    static func validateMembers(_ members: [Int32]) -> Result<[Int32], Rejection> {
        if members.contains(where: { $0 <= 0 }) {
            return .failure(Rejection(message: "A member id must be positive; the current selection is never implied."))
        }
        if Set(members).count != members.count {
            return .failure(Rejection(message: "The member list contains a duplicate id."))
        }
        return .success(members)
    }
    /// Local preflight of one edit request (slot-135 field relevance).
    static func validateRequest(operation: EngineSession.ItemSetEdit, kind: EngineSession.ItemSetKind,
                                token: UInt64, name: String?, members: [Int32],
                                captureSelection: Bool) -> Result<Void, Rejection> {
        switch operation {
        case .create:
            guard token == 0, let name else {
                return .failure(Rejection(message: "Creating a set takes a full new name."))
            }
            if case .failure(let rejection) = validateName(name) { return .failure(rejection) }
        case .replace:
            guard token != 0, name == nil else {
                return .failure(Rejection(message: "Replacing a set takes its current token and the captured members only."))
            }
            if !captureSelection, case .failure(let rejection) = validateMembers(members) {
                return .failure(rejection)
            }
        case .rename:
            guard token != 0, let name, members.isEmpty else {
                return .failure(Rejection(message: "Renaming a set takes its current token and the full new name only."))
            }
            if case .failure(let rejection) = validateName(name) { return .failure(rejection) }
        case .remove:
            guard token != 0, name == nil, members.isEmpty else {
                return .failure(Rejection(message: "Deleting a set takes its current token only."))
            }
        }
        return .success(())
    }

    /// Recall admission for any kind: the row's exact member list must be
    /// nonempty and still exist in the document, so the set recalls via
    /// the native batch selection (slot 136) exactly; else a reason.
    static func recallAdmission(kind: EngineSession.ItemSetKind, row: Row?,
                                existingIDs: Set<Int32>) -> Result<[Int32], Rejection> {
        guard let row else { return .failure(Rejection(message: "Select a saved set to recall.")) }
        guard !row.members.isEmpty else {
            return .failure(Rejection(message: "The selected set is empty; there is nothing to recall."))
        }
        guard Set(row.members).isSubset(of: existingIDs) else {
            return .failure(Rejection(message: "Some members of the selected set are no longer in this image, so it cannot be recalled exactly."))
        }
        return .success(row.members)
    }

    /// The document's current item ids of `kind`, for recall admission and
    /// capture preflight — the cached rows, pure cache read.
    static func existingIDs(ofKind kind: EngineSession.ItemSetKind, layers: [EngineSession.Layer],
                            channels: [EngineSession.Channel], paths: [EngineSession.PathInfo]) -> Set<Int32> {
        switch kind {
        case .layer: return Set(layers.map(\.id))
        case .channel: return Set(channels.map(\.id))
        case .path: return Set(paths.map(\.id))
        }
    }

    /// `idle`, or `mutating` while one accepted edit is active (gated).
    enum Phase: Equatable {
        case idle, mutating
    }
    /// A mutation begins only from `idle` (no reentrant second edit).
    static func beginMutation(_ phase: Phase) -> Phase {
        phase == .idle ? .mutating : phase
    }
    /// The completion returns to `idle`; any other phase is stale.
    static func mutationCompletion(_ phase: Phase) -> Phase {
        phase == .mutating ? .idle : phase
    }
}
/// View ▸ Saved Sets…: this document's non-modal saved-set panel, owned by
/// one window controller (never a singleton), capturing the document at
/// open so two documents never retarget to the front window. The table is
/// read-only (labels + LIVE counts); rows are addressed by their opaque
/// current token, never by label. Catalog and members (slots 133/134) are
/// read off the main thread as counted work, generations discard stale
/// completions. New/Replace capture the current selected ids explicitly (an
/// actual per-kind query on the worker; empty = explicit empty set, never a
/// fake all-items list); the request binds the selected row's token at
/// apply. Mutations (slot 135) go through the global EngineActivity off the
/// main thread, counted exactly once through the idle completion, including
/// close. Recall works for all three kinds through the native batch
/// selection (slots 136/137) with fresh slot-134 members. Window close
/// invalidates the panel, so a late completion cannot resurrect UI.
@MainActor
final class SavedSetPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let imageDocument: ImageDocument
    private weak var host: DocumentWindowController?

    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView(frame: .zero)
    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    let countColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count"))
    private let nameField = NSTextField(string: "")
    private let newButton = NSButton(title: "New from Selection", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace with Selection", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let recallButton = NSButton(title: "Recall", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let noteLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    private var allRows: [SavedSetControlsLogic.Row] = []
    private var loadGeneration = 0
    private(set) var selectedToken: UInt64?
    private(set) var phase: SavedSetControlsLogic.Phase = .idle
    private var lastUndoSignature: EngineSession.UndoInfo?
    private(set) var isInvalidated = false
    private(set) var lastError: String?
    private(set) var lastNote: String?

    init(document imageDocument: ImageDocument, host: DocumentWindowController) {
        self.imageDocument = imageDocument
        self.host = host
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Saved Sets"
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        updateControlStates()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var kind: EngineSession.ItemSetKind {
        let index = kindPopup.indexOfSelectedItem
        guard SavedSetControlsLogic.kinds.indices.contains(index) else { return .layer }
        return SavedSetControlsLogic.kinds[index].0
    }

    var rows: [SavedSetControlsLogic.Row] {
        SavedSetControlsLogic.rows(ofKind: kind, in: allRows)
    }

    var selectedRow: SavedSetControlsLogic.Row? {
        guard let token = selectedToken else { return nil }
        return rows.first { $0.token == token }
    }

    private func buildContent(in panel: NSPanel) {
        kindPopup.addItems(withTitles: SavedSetControlsLogic.kinds.map(\.1))
        kindPopup.setAccessibilityLabel("Saved set kind")
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))

        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Saved sets table")
        table.headerView = nil
        nameColumn.title = "Name"
        countColumn.title = "Count"
        // Read-only display: the cells are not editable.
        (nameColumn.dataCell as? NSCell)?.isEditable = false
        (countColumn.dataCell as? NSCell)?.isEditable = false
        countColumn.width = 48
        table.addTableColumn(nameColumn)
        table.addTableColumn(countColumn)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 140))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        table.frame = NSRect(x: 0, y: 0, width: 430, height: 140)

        nameField.setAccessibilityLabel("Saved set name")
        nameField.placeholderString = "Set name"
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        closeButton.keyEquivalent = "\u{1b}"
        for (button, label, action) in [(newButton, "New from selection", #selector(newFromSelection(_:))),
                                        (replaceButton, "Replace with selection", #selector(replaceWithSelection(_:))),
                                        (renameButton, "Rename saved set", #selector(renameSavedSet(_:))),
                                        (deleteButton, "Delete saved set", #selector(deleteSavedSet(_:))),
                                        (recallButton, "Recall saved set", #selector(recallSavedSet(_:))),
                                        (closeButton, "Close saved sets panel", #selector(closePanel(_:)))] {
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        noteLabel.setAccessibilityLabel("Saved sets note")
        messageLabel.setAccessibilityLabel("Saved sets message")
        for label in [noteLabel, messageLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let topRow = NSStackView(views: [NSTextField(labelWithString: "Kind:"), kindPopup])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        let buttonRow = NSStackView(views: [newButton, replaceButton, renameButton,
                                             deleteButton, recallButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        let stack = NSStackView(views: [topRow, scroll, nameRow, buttonRow, noteLabel, messageLabel])
        stack.orientation = .vertical
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
        ])
        panel.contentView!.setFrameSize(stack.fittingSize)
        panel.minSize = panel.frame.size
        panel.initialFirstResponder = nameField
    }

    func reload() {
        guard !isInvalidated, !imageDocument.isClosing else { return }
        loadGeneration += 1
        let generation = loadGeneration
        imageDocument.readSavedSetRows { [weak self] result in
            guard let self, !self.isInvalidated,
                  SavedSetControlsLogic.readIsCurrent(generation: generation, current: self.loadGeneration) else { return }
            switch result {
            case .success(let rows):
                self.allRows = rows.map { SavedSetControlsLogic.Row(set: $0.set, members: $0.members) }
                self.lastUndoSignature = self.imageDocument.undoInfo
                self.selectedToken = SavedSetControlsLogic.preservedSelection(self.selectedToken, in: self.allRows)
                self.table.reloadData()
                if let token = self.selectedToken,
                   let index = self.rows.firstIndex(where: { $0.token == token }) {
                    self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
            case .failure(let error):
                self.refuse(error.localizedDescription)
            }
            self.updateControlStates()
        }
    }

    private func cachedAdmission() -> String? {
        SavedSetControlsLogic.writeAdmission(
            isClosing: imageDocument.isClosing,
            isSavingForClose: imageDocument.isSavingForClose,
            isTransferringClipboard: imageDocument.isTransferringClipboard,
            pluginRunning: PlugInCommands.isRunning,
            engineBusy: EngineActivity.shared.isBusy,
            previewOpen: imageDocument.filterPreviewIsOpen)
    }

    private func updateControlStates() {
        let blocked = isInvalidated || phase == .mutating || cachedAdmission() != nil
        let hasRow = selectedRow != nil
        newButton.isEnabled = !blocked
        replaceButton.isEnabled = !blocked && hasRow
        renameButton.isEnabled = !blocked && hasRow
        deleteButton.isEnabled = !blocked && hasRow
        let recall = SavedSetControlsLogic.recallAdmission(
            kind: kind, row: selectedRow,
            existingIDs: SavedSetControlsLogic.existingIDs(ofKind: kind, layers: imageDocument.layers,
                                                            channels: imageDocument.channels,
                                                            paths: imageDocument.paths))
        recallButton.isEnabled = !blocked && { if case .success = recall { return true }; return false }()
        recallButton.toolTip = hasRow ? {
            if case .failure(let rejection) = recall { return rejection.message }
            return nil
        }() : nil
        if let admission = cachedAdmission()  { note(admission) } else if !hasRow {
            note("Select a saved set to replace, rename, delete or recall it.")
        } else {
            note(nil)
        }
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    private func clearMessage() {
        lastError = nil
        messageLabel.stringValue = ""
    }

    private func note(_ text: String?) {
        lastNote = text
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.stringValue = text ?? ""
    }

    func documentStateDidChange() {
        guard !isInvalidated else { return }
        if lastUndoSignature != imageDocument.undoInfo { reload() } else { updateControlStates() }
    }

    func showError(_ message: String) {
        guard !isInvalidated, phase == .idle else { return }
        refuse(message)
    }

    func commitFieldEdit() {
        window?.endEditing(for: nil)
    }

    func invalidate() {
        isInvalidated = true
        window?.endEditing(for: nil)
    }

    @objc func kindChanged(_ sender: Any?) {
        guard !isInvalidated else { return }
        reload()
        updateControlStates()
    }

    @objc private func newFromSelection(_ sender: Any?) {
        guard !isInvalidated, phase == .idle else { return }
        window?.endEditing(for: nil)
        if let admission = cachedAdmission() { refuse(admission); NSSound.beep(); return }
        switch SavedSetControlsLogic.validateName(nameField.stringValue) {
        case .success(let name):
            beginMutation(.create, token: 0, name: name, captureSelection: true)
        case .failure(let rejection):
            refuse(rejection.message)
            NSSound.beep()
        }
    }

    @objc private func replaceWithSelection(_ sender: Any?) {
        guard !isInvalidated, phase == .idle, let row = selectedRow else { return }
        window?.endEditing(for: nil)
        if let admission = cachedAdmission() { refuse(admission); NSSound.beep(); return }
        beginMutation(.replace, token: row.token, name: nil, captureSelection: true)
    }

    /// Rename: current token + FULL new name (draft never seeded from label).
    @objc private func renameSavedSet(_ sender: Any?) {
        guard !isInvalidated, phase == .idle, let row = selectedRow else { return }
        window?.endEditing(for: nil)
        if let admission = cachedAdmission() { refuse(admission); NSSound.beep(); return }
        switch SavedSetControlsLogic.validateName(nameField.stringValue) {
        case .success(let name):
            beginMutation(.rename, token: row.token, name: name, captureSelection: false)
        case .failure(let rejection):
            refuse(rejection.message)
            NSSound.beep()
        }
    }

    @objc private func deleteSavedSet(_ sender: Any?) {
        guard !isInvalidated, phase == .idle, let row = selectedRow else { return }
        if let admission = cachedAdmission() { refuse(admission); NSSound.beep(); return }
        beginMutation(.remove, token: row.token, name: nil, captureSelection: false)
    }

    /// Recall: any kind, via the exact-list native batch selection — the
    /// document, kind and current token captured at the call.
    @objc private func recallSavedSet(_ sender: Any?) {
        guard !isInvalidated, phase == .idle, let row = selectedRow else { return }
        if let reason = cachedAdmission() { refuse(reason); return }
        let admission = SavedSetControlsLogic.recallAdmission(
            kind: kind, row: selectedRow,
            existingIDs: SavedSetControlsLogic.existingIDs(ofKind: kind, layers: imageDocument.layers,
                                                            channels: imageDocument.channels,
                                                            paths: imageDocument.paths))
        guard case .success = admission else {
            if case .failure(let rejection) = admission { refuse(rejection.message) }
            NSSound.beep()
            return
        }
        clearMessage()
        phase = .mutating
        updateControlStates()
        imageDocument.recallItemSet(token: row.token, kind: row.kind) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.phase = .idle
            if case .failure(let error) = result { self.refuse(error.localizedDescription) }
            self.reload()
        }
    }

    @objc private func closePanel(_ sender: Any?) {
        window?.close()
    }

    private func beginMutation(_ operation: EngineSession.ItemSetEdit, token: UInt64,
                               name: String?, captureSelection: Bool) {
        phase = SavedSetControlsLogic.beginMutation(phase)
        updateControlStates()
        let request = ImageDocument.SavedSetEditRequest(
            operation: operation, kind: kind, token: token,
            name: name, members: [], captureSelection: captureSelection)
        imageDocument.editSavedSet(request) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.phase = SavedSetControlsLogic.mutationCompletion(self.phase)
            switch result {
            case .success(let newToken):
                self.clearMessage()
                // Fresh token after CREATE/REPLACE/RENAME (the old one
                // expired), the current one after a no-op, 0 after REMOVE.
                self.selectedToken = newToken == 0 ? nil : newToken
                self.reload()
            case .failure(let error):
                self.refuse(error.localizedDescription)
            }
            self.updateControlStates()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < rows.count else { return nil }
        let entry = rows[row]
        if tableColumn == countColumn { return "\(entry.memberCount)" }
        return entry.displayName
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0, row < rows.count  { selectedToken = rows[row].token } else {
            selectedToken = nil
        }
        updateControlStates()
    }
}

extension SavedSetPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        invalidate()
        host?.clearSavedSetPanel(self)
    }
}
