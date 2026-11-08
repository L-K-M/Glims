import AppKit

/// Pure logic behind Image ▸ Guides…: strict position parsing, the
/// per-orientation valid range against the cached image size, display
/// order and selection preservation. No AppKit state, so the rules are
/// unit-testable without an engine.
enum GuidesSheetLogic {
    /// Strictly parses a decimal integer position: digits only, in
    /// canonical form — no whitespace, sign, decimal point, padding or
    /// any other decoration. Anything else is not a position.
    static func parsePosition(_ text: String) -> Int32? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), let result = Int32(exactly: value),
              String(result) == text else { return nil }
        return result
    }

    /// The image extent a guide on `orientation` may sit at: the height
    /// for a horizontal guide (its position is a y coordinate) and the
    /// width for a vertical one (an x coordinate), matching the native
    /// semantics — orientation is fixed at creation and never reoriented.
    static func extent(orientation: EngineSession.GuideOrientation, width: Int, height: Int) -> Int {
        orientation == .horizontal ? height : width
    }

    /// Whether `position` is inside the inclusive 0...extent range for
    /// `orientation` in an image of `width` × `height`.
    static func isValid(position: Int32, orientation: EngineSession.GuideOrientation,
                        width: Int, height: Int) -> Bool {
        position >= 0 && position <= Int32(extent(orientation: orientation, width: width, height: height))
    }

    /// The sheet's rows: horizontal guides first, then vertical, each by
    /// ascending position.
    static func sortedGuides(_ guides: [EngineSession.Guide]) -> [EngineSession.Guide] {
        guides.sorted { a, b in
            if a.orientation != b.orientation { return a.orientation == .horizontal }
            return a.position < b.position
        }
    }

    /// A reload preserves the selected row by guide identity, not by
    /// index; nil when the guide is gone.
    static func index(ofGuide id: Int32, in guides: [EngineSession.Guide]) -> Int? {
        guides.firstIndex { $0.id == id }
    }

    /// A reload may rewrite the inline position field only while the user
    /// is not editing it.
    static func shouldRewritePositionField(isEditing: Bool) -> Bool { !isEditing }
}

/// View ▸ Show Guides' cached per-window state. Pure view state: toggling
/// changes only what the canvas draws — never a native guide edit, image
/// pixels, the file's dirty state, export or print.
struct GuideViewState {
    var showsGuides = true
    var menuState: NSControl.StateValue { showsGuides ? .on : .off }
    mutating func toggle() { showsGuides.toggle() }
}

/// Image ▸ Guides…: the document-owned guide management sheet. It lists
/// the cached `ImageDocument.guides` by orientation and position and offers
/// inline orientation + strictly parsed integer position with Add, Move
/// selected, Remove selected and Close. Edits take effect individually
/// through the document's queued addGuide/moveGuide/removeGuide — each one
/// undo step — so Close is not Cancel. The owning window controller retains
/// this controller for the sheet's lifetime and routes reload, error and
/// close feedback to it through its existing callbacks; late callbacks
/// after invalidation never reopen or update the sheet.
@MainActor
final class GuidesSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let tableView = NSTableView(frame: .zero)
    private let orientationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let moveButton = NSButton(title: "Move Selected", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString:
        "Each change is applied at once and can be undone with Edit ▸ Undo.")

    /// The rows as displayed, in `GuidesSheetLogic.sortedGuides` order.
    private var rows: [EngineSession.Guide] = []
    /// The selected guide by identity; preserved across asynchronous
    /// reloads by id, cleared when the guide disappears.
    private(set) var selectedGuideID: Int32?
    /// The last validation or native refusal shown in the sheet.
    private(set) var lastError: String?
    /// Set on close; late reload/error callbacks then do nothing.
    private var isInvalidated = false

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Guides"
        buildContent()
        documentStateDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.setAccessibilityLabel("Guides list")
        let orientationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("orientation"))
        orientationColumn.title = "Orientation"
        orientationColumn.width = 120
        let positionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("position"))
        positionColumn.title = "Position (px)"
        positionColumn.width = 100
        tableView.addTableColumn(orientationColumn)
        tableView.addTableColumn(positionColumn)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        tableView.frame = NSRect(x: 0, y: 0, width: 340, height: 130)

        orientationPopup.addItems(withTitles: ["Horizontal", "Vertical"])
        orientationPopup.setAccessibilityLabel("Guide orientation")
        positionField.setAccessibilityLabel("Guide position in pixels")
        positionField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        addButton.setAccessibilityLabel("Add guide")
        moveButton.setAccessibilityLabel("Move selected guide")
        removeButton.setAccessibilityLabel("Remove selected guide")
        closeButton.setAccessibilityLabel("Close guides sheet")
        messageLabel.setAccessibilityLabel("Guides message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        hintLabel.setAccessibilityLabel("Guides hint")
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        addButton.target = self
        addButton.action = #selector(addGuide(_:))
        moveButton.target = self
        moveButton.action = #selector(moveSelected(_:))
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.keyEquivalent = "\r"

        let inputRow = NSStackView(views: [
            NSTextField(labelWithString: "Orientation:"),
            orientationPopup,
            NSTextField(labelWithString: "Position (px):"),
            positionField,
        ])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        let buttonRow = NSStackView(views: [addButton, moveButton, removeButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [hintLabel, scroll, inputRow, buttonRow, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
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
    }

    // MARK: Reload, error and close routing (called by the owning window)

    /// The document's cached state changed (including the guides list):
    /// reload the rows, preserving the selection by guide identity.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        let previous = selectedGuideID
        rows = GuidesSheetLogic.sortedGuides(document.guides)
        tableView.reloadData()
        if let previous, let row = GuidesSheetLogic.index(ofGuide: previous, in: rows) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectedGuideID = nil
            tableView.deselectAll(nil)
        }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too.
    func showError(_ message: String) {
        guard !isInvalidated else { return }
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update or reopen the sheet.
    func invalidate() {
        isInvalidated = true
        selectedGuideID = nil
        tableView.dataSource = nil
        tableView.delegate = nil
        panel.endEditing(for: nil)
    }

    // MARK: Controls

    private var selectedOrientation: EngineSession.GuideOrientation {
        orientationPopup.indexOfSelectedItem == 1 ? .vertical : .horizontal
    }

    private func selectOrientation(_ orientation: EngineSession.GuideOrientation) {
        orientationPopup.selectItem(at: orientation == .vertical ? 1 : 0)
    }

    private var positionFieldIsEditing: Bool {
        positionField.currentEditor() != nil
    }

    private func updateControlStates() {
        // Cached busy/closing state only — no native call here.
        let canWrite = !isInvalidated && document.acceptsEdits
        let hasSelection = selectedGuideID != nil && rows.contains(where: { $0.id == selectedGuideID })
        addButton.isEnabled = canWrite
        moveButton.isEnabled = canWrite && hasSelection
        removeButton.isEnabled = canWrite && hasSelection
        // A move never reorients (the native put refuses it), so the inline
        // orientation locks to the selected guide's own while one is picked.
        orientationPopup.isEnabled = canWrite && !hasSelection
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
        NSSound.beep()
    }

    private func clearMessage() {
        lastError = nil
        messageLabel.stringValue = ""
    }

    /// Parses and range-checks the inline position against the cached image
    /// size for `orientation`; nil with a refusal message when invalid.
    private func validatedPosition(orientation: EngineSession.GuideOrientation) -> Int32? {
        guard let position = GuidesSheetLogic.parsePosition(positionField.stringValue) else {
            refuse("Enter a whole number of pixels — digits only, no other characters.")
            return nil
        }
        let width = document.info.width, height = document.info.height
        guard GuidesSheetLogic.isValid(position: position, orientation: orientation,
                                       width: width, height: height) else {
            let extent = GuidesSheetLogic.extent(orientation: orientation, width: width, height: height)
            refuse("Position must be from 0 to \(extent) for a \(orientation == .horizontal ? "horizontal" : "vertical") guide in this \(width) × \(height) image.")
            return nil
        }
        return position
    }

    // MARK: Actions

    /// Add: captures the owning document, the inline orientation and the
    /// parsed position before enqueueing the queued add.
    @objc private func addGuide(_ sender: Any?) {
        guard !isInvalidated, document.acceptsEdits else { return }
        let owner = document
        let orientation = selectedOrientation
        guard let position = validatedPosition(orientation: orientation) else { return }
        clearMessage()
        owner.addGuide(orientation, at: position)
    }

    /// Move selected: captures the owning document, the selected guide id
    /// and the parsed position before enqueueing; the guide's own cached
    /// orientation goes with it — a move never reorients.
    @objc private func moveSelected(_ sender: Any?) {
        guard !isInvalidated, document.acceptsEdits,
              let id = selectedGuideID,
              let guide = document.guides.first(where: { $0.id == id }) else { return }
        let owner = document
        let target = guide
        guard let position = validatedPosition(orientation: target.orientation) else { return }
        clearMessage()
        owner.moveGuide(target, to: position)
    }

    /// Remove selected: captures the owning document and the selected guide
    /// id before enqueueing the queued remove.
    @objc private func removeSelected(_ sender: Any?) {
        guard !isInvalidated, document.acceptsEdits,
              let id = selectedGuideID,
              document.guides.contains(where: { $0.id == id }) else { return }
        let owner = document
        let target = id
        clearMessage()
        owner.removeGuide(target)
    }

    /// Close ends the sheet; edits already took effect individually.
    @objc private func close(_ sender: Any?) {
        hostWindow?.endSheet(panel)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < rows.count else { return nil }
        let guide = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "position": return "\(guide.position)"
        default: return guide.orientation == .horizontal ? "Horizontal" : "Vertical"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else {
            selectedGuideID = nil
            updateControlStates()
            return
        }
        let guide = rows[row]
        selectedGuideID = guide.id
        selectOrientation(guide.orientation)
        // Never overwrite an active field edit with the row's position.
        if GuidesSheetLogic.shouldRewritePositionField(isEditing: positionFieldIsEditing) {
            positionField.stringValue = String(guide.position)
        }
        updateControlStates()
    }
}
