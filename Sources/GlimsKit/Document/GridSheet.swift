import AppKit

/// Image ▸ Configure Grid…: the per-window sheet that edits the image's
/// cached display grid. The sheet captures its document at open and
/// seeds a LOCAL draft (spacing, offset, style, foreground, background)
/// from the cached `ImageDocument.grid`. Every edit stays local until
/// Apply parses and validates the whole draft and performs ONE queued
/// atomic `setGrid` (one undo step when changed; an identical grid is a
/// no-op). Cancel and window close write nothing. Validation and native
/// refusals are shown in the sheet and the draft is preserved, so the
/// user can correct the values. The owning window controller retains
/// this controller for the sheet's lifetime and routes reload, error and
/// close feedback through the document's existing callbacks; after
/// invalidation late callbacks do nothing.
@MainActor
final class GridSheetController: NSObject, NSTextFieldDelegate {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spacingXField = NSTextField(string: "")
    private let spacingYField = NSTextField(string: "")
    private let offsetXField = NSTextField(string: "")
    private let offsetYField = NSTextField(string: "")
    private let foregroundWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let backgroundWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    /// The local draft. Seeded from the cached grid; every control edit
    /// marks it dirty, and a reload only re-seeds while it is clean, so
    /// an unapplied draft — in particular after a validation or native
    /// refusal — is never clobbered.
    private var draft: EngineSession.Grid
    private var draftIsDirty = false
    /// The last validation or native refusal shown in the sheet.
    private(set) var lastError: String?
    /// Set on close; late reload/error callbacks then do nothing.
    private var isInvalidated = false
    /// Whether the shared color panel was already visible when this
    /// sheet opened: only a panel this sheet's own wells activated is
    /// closed on close.
    private let colorPanelWasVisible: Bool

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.draft = document.grid
        self.colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Configure Grid"
        buildContent()
        seedFromCache()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        stylePopup.addItems(withTitles: EngineSession.GridStyle.allCases.map(\.title))
        stylePopup.setAccessibilityLabel("Grid style")
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged(_:))
        for (field, label) in [(spacingXField, "Grid spacing X"), (spacingYField, "Grid spacing Y"),
                               (offsetXField, "Grid offset X"), (offsetYField, "Grid offset Y")] {
            field.setAccessibilityLabel(label)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        foregroundWell.setAccessibilityLabel("Grid foreground color")
        backgroundWell.setAccessibilityLabel("Grid background color")
        foregroundWell.target = self
        foregroundWell.action = #selector(colorChanged(_:))
        backgroundWell.target = self
        backgroundWell.action = #selector(colorChanged(_:))
        applyButton.setAccessibilityLabel("Apply grid")
        cancelButton.setAccessibilityLabel("Cancel grid changes")
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.keyEquivalent = "\r"
        messageLabel.setAccessibilityLabel("Grid message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        hintLabel.setAccessibilityLabel("Grid hint")
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.stringValue = "Changes apply to this image as one undoable step when you press Apply. Cancel discards them."

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Style:"), stylePopup, NSView(), NSView()],
            [NSTextField(labelWithString: "Spacing X:"), spacingXField,
             NSTextField(labelWithString: "Spacing Y:"), spacingYField],
            [NSTextField(labelWithString: "Offset X:"), offsetXField,
             NSTextField(labelWithString: "Offset Y:"), offsetYField],
            [NSTextField(labelWithString: "Foreground:"), foregroundWell,
             NSTextField(labelWithString: "Background:"), backgroundWell],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let buttonRow = NSStackView(views: [applyButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [hintLabel, grid, buttonRow, messageLabel])
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

    // MARK: Draft and reload routing (called by the owning window)

    /// Re-seeds the draft and the controls from the cached grid. A dirty
    /// draft (unapplied edits) is preserved — after a validation or
    /// native refusal the user corrects the shown values, not a reset.
    private func seedFromCache() {
        draft = document.grid
        selectStyle(draft.style)
        setField(spacingXField, draft.spacingX)
        setField(spacingYField, draft.spacingY)
        setField(offsetXField, draft.offsetX)
        setField(offsetYField, draft.offsetY)
        if !foregroundWell.isActive { foregroundWell.color = draft.foreground }
        if !backgroundWell.isActive { backgroundWell.color = draft.background }
    }

    /// The document's cached state changed: re-seed a clean draft (e.g.
    /// after Undo/Redo or a successful Apply's reload) and refresh the
    /// guards. A dirty draft is kept.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        if !draftIsDirty { seedFromCache() }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too,
    /// keeping the draft so the values can be corrected.
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

    /// Close cleanup: no later callback may update or reopen the sheet,
    /// and only the color panel this sheet's own wells activated is
    /// closed (a panel that was already visible when the sheet opened
    /// stays). Idempotent: the window's close path and the sheet's own
    /// completion may both run.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        let ownActivation = foregroundWell.isActive || backgroundWell.isActive
        if ownActivation && !colorPanelWasVisible { NSColorPanel.shared.orderOut(nil) }
        foregroundWell.deactivate()
        backgroundWell.deactivate()
        panel.endEditing(for: nil)
    }

    // MARK: Controls

    private var selectedStyle: EngineSession.GridStyle {
        let index = stylePopup.indexOfSelectedItem
        return EngineSession.GridStyle.allCases[min(max(index, 0), EngineSession.GridStyle.allCases.count - 1)]
    }

    private func selectStyle(_ style: EngineSession.GridStyle) {
        if let index = EngineSession.GridStyle.allCases.firstIndex(of: style) {
            stylePopup.selectItem(at: index)
        }
    }

    /// Writes a field only while the user is not editing it, like the
    /// guides sheet: an asynchronous reload never clobbers a field edit.
    private func setField(_ field: NSTextField, _ value: Double) {
        guard field.currentEditor() == nil else { return }
        field.stringValue = Self.format(value)
    }

    /// Canonical decimal rendering of a cached value (finite by contract;
    /// anything else renders empty rather than clamping the metadata).
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(value)
    }

    private func updateControlStates() {
        // Cached busy/closing state only — no native call here. The draft
        // controls stay editable while busy (edits are local); only Apply
        // gates on the document's cached acceptsEdits.
        applyButton.isEnabled = !isInvalidated && document.acceptsEdits
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    private func clearMessage() {
        lastError = nil
        messageLabel.textColor = .labelColor
        messageLabel.stringValue = ""
    }

    @objc private func styleChanged(_ sender: Any?) {
        draftIsDirty = true
        updateControlStates()
    }

    @objc private func colorChanged(_ sender: Any?) {
        draftIsDirty = true
        updateControlStates()
    }

    func controlTextDidChange(_ notification: Notification) {
        draftIsDirty = true
        updateControlStates()
    }

    // MARK: Actions

    /// Apply: commits the field edits, parses and validates the whole
    /// draft, then captures the document and the grid values before the
    /// ONE queued atomic setGrid. The draft is kept — a native refusal
    /// (e.g. a spacing beyond the engine's bounds) comes back through
    /// the document's error callback and is shown with the values intact.
    @objc private func apply(_ sender: Any?) {
        guard !isInvalidated, document.acceptsEdits else { return }
        panel.endEditing(for: nil)
        switch GridSheetLogic.validateDraft(style: selectedStyle,
                                            spacingXText: spacingXField.stringValue,
                                            spacingYText: spacingYField.stringValue,
                                            offsetXText: offsetXField.stringValue,
                                            offsetYText: offsetYField.stringValue,
                                            foreground: foregroundWell.color,
                                            background: backgroundWell.color) {
        case .failure(let rejection):
            refuse(rejection.message)
        case .success(let grid):
            clearMessage()
            draft = grid
            let owner = document
            owner.setGrid(grid)
        }
    }

    /// Cancel: closes the sheet; nothing was written.
    @objc private func cancel(_ sender: Any?) {
        hostWindow?.endSheet(panel, returnCode: .alertSecondButtonReturn)
    }
}
