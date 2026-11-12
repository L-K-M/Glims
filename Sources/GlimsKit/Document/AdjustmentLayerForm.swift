import AppKit

/// Pure logic behind Layer ▸ New Adjustment Layer…: the known adjustment
/// set, the catalog filtering, the name rule, the default name and the
/// cached color-mode gate. No AppKit state, so the rules are unit-testable
/// without an engine.
enum AdjustmentLayerLogic {

    /// A user-facing refusal of the form's own input, before anything
    /// queues.
    struct InputError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Color adjustments with an available parameter editor. The runtime
    /// catalog decides which generic and dedicated operations can be offered.
    static let knownOperations: [(name: String, title: String)] = [
        ("gegl:brightness-contrast", "Brightness/Contrast"),
        ("gimp:levels", "Levels"),
        ("gimp:curves", "Curves"),
        ("gimp:threshold", "Threshold"),
        ("glims:posterize", "Posterize"),
        ("gimp:color-balance", "Color Balance"),
        ("gimp:hue-saturation", "Hue-Saturation"),
        ("gegl:exposure", "Exposure"),
        ("gegl:hue-chroma", "Hue/Chroma"),
        ("gegl:saturation", "Saturation"),
        ("gegl:color-temperature", "Color Temperature"),
        ("gegl:invert-linear", "Linear Invert"),
        ("gegl:invert-gamma", "Value Invert"),
    ]

    /// The catalog's operations of the known set that a parameter editor
    /// can drive — the generic form's `.supported` operations plus the
    /// dedicated config operations the effect-parameter routing owns —
    /// in the known set's display order regardless of catalog order.
    /// Unsupported, uneditable config-driven, two-input and unknown
    /// operations never appear — there is no fallback to an unlisted
    /// operation.
    static func availableOperations(in catalog: [EngineSession.FilterOperation]) -> [EngineSession.FilterOperation] {
        knownOperations.compactMap { known in
            catalog.first { $0.name == known.name && NativeFilterMenuLayout.supportsParameterEditor($0) }
        }
    }

    /// The name field accepts at most this many UTF-8 bytes.
    static let maximumNameBytes = 255

    /// The name rule: the whole field trimmed of surrounding whitespace,
    /// nonempty, no NUL, at most `maximumNameBytes` bytes. Parsing is
    /// full-string — a prefix that happens to be valid is not accepted on
    /// its own.
    static func validateName(_ raw: String) -> Result<String, InputError> {
        if raw.utf8.contains(0) {
            return .failure(InputError(message: "The name contains invalid characters."))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(InputError(message: "Enter a name for the adjustment layer."))
        }
        if trimmed.utf8.count > maximumNameBytes {
            return .failure(InputError(message: "The name is too long."))
        }
        return .success(trimmed)
    }

    /// The name a fresh sheet suggests for `title`, uniquified against the
    /// image's existing layer names: "Title", "Title 2", "Title 3", …
    static func defaultName(for title: String, existingNames: [String]) -> String {
        if !existingNames.contains(title) { return title }
        var suffix = 2
        while existingNames.contains("\(title) \(suffix)") { suffix += 1 }
        return "\(title) \(suffix)"
    }

    /// The cached color-mode gate: adjustment layers are offered for RGB
    /// and grayscale images only. Indexed is visibly unavailable in the
    /// Swift layer as well as the native guard; the reason is shown.
    struct ModeAdmission: Equatable {
        let allowed: Bool
        let reason: String?
    }

    static func modeAdmission(_ mode: EngineSession.ColorMode) -> ModeAdmission {
        switch mode {
        case .rgb, .grayscale:
            return ModeAdmission(allowed: true, reason: nil)
        case .indexed:
            return ModeAdmission(allowed: false,
                reason: "Adjustment layers require RGB or grayscale. Convert the indexed image first.")
        case .unknown:
            return ModeAdmission(allowed: false,
                reason: "The image's color mode is unknown, so no adjustment layer can be added.")
        }
    }
}

/// Layer ▸ New Adjustment Layer…'s creation sheet: a name field, an
/// adjustment picker and Create/Cancel. The sheet is owned by the window
/// controller that opened it and captures that window's document at open,
/// so Create and the phase-2 editor act on the captured document, never on
/// the front one.
///
/// Upon invocation the sheet reads the native filter catalog
/// asynchronously as ONE counted document job (the document counts it, so
/// a close waits) and installs the supported known operations into the
/// picker; a generation counter plus invalidation make a late answer
/// harmless. Cancel before Create mutates nothing. An accepted Create ends
/// the document's pending edits, queues the native creation as a counted
/// target command behind accepted input, and on success closes the sheet
/// and opens the existing modeless effect-parameter editor on the created
/// effect. A failure keeps the sheet, the name and the chosen adjustment
/// and shows the native error inline; Create and Cancel are disabled while
/// accepted work runs. After invalidation (window close) late callbacks do
/// nothing and no editor opens.
@MainActor
final class AdjustmentLayerSheetController: NSObject, NSTextFieldDelegate {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?
    /// The window controller that opened this sheet; phase 2 opens the
    /// effect editor through it. Weak: a closed host simply skips phase 2.
    weak var host: DocumentWindowController?

    private let nameField = NSTextField(string: "")
    private let adjustmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    /// The picker's entries after the catalog answer; empty while loading
    /// or when nothing is supported.
    private(set) var availableOperations: [EngineSession.FilterOperation] = []
    /// True while the catalog read runs.
    private(set) var isLoadingOperations = false
    /// True while an accepted Create runs.
    private(set) var isCreating = false
    /// The last validation or native refusal shown in the sheet.
    private(set) var lastError: String?
    /// Bumped on every catalog read; a late answer of an older generation
    /// is dropped.
    private var loadGeneration = 0
    /// Set on close; late callbacks then do nothing.
    private var isInvalidated = false
    /// False once the user edits the name field; the picker then stops
    /// overwriting it.
    private var nameIsCustom = false

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                             styleMask: [.titled, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "New Adjustment Layer"
        buildContent()
        loadOperations()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        nameField.setAccessibilityLabel("Adjustment layer name")
        nameField.delegate = self
        adjustmentPopup.setAccessibilityLabel("Adjustment")
        adjustmentPopup.target = self
        adjustmentPopup.action = #selector(adjustmentChanged(_:))
        createButton.setAccessibilityLabel("Create adjustment layer")
        cancelButton.setAccessibilityLabel("Cancel adjustment layer")
        createButton.target = self
        createButton.action = #selector(create(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        createButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        messageLabel.setAccessibilityLabel("Adjustment layer message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        hintLabel.setAccessibilityLabel("Adjustment layer hint")
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 3
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.stringValue = "Create adds a layer and opens its parameters. Canceling the parameter edit keeps the created layer; Undo removes it."

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Adjustment:"), adjustmentPopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let buttonRow = NSStackView(views: [createButton, cancelButton])
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

    // MARK: Catalog load (counted document work)

    /// Reads the native catalog asynchronously on the document's counted
    /// long-queue job and filters it to the supported known operations.
    /// The document counts the job, so a close waits for it; the sheet's
    /// generation and invalidation drop a late or post-close answer.
    private func loadOperations() {
        guard !isInvalidated else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingOperations = true
        setMessage("Loading adjustments…", isError: false)
        updateControlStates()
        document.loadNativeFilterOperations { [weak self] result in
            guard let self, !self.isInvalidated, self.loadGeneration == generation else { return }
            self.isLoadingOperations = false
            guard case .success(let operations) = result else {
                if case .failure(let error) = result { self.refuse(error.localizedDescription) }
                self.updateControlStates()
                return
            }
            self.availableOperations = AdjustmentLayerLogic.availableOperations(in: operations)
            self.installPicker()
            if let first = self.availableOperations.first, !self.nameIsCustom {
                self.nameField.stringValue = AdjustmentLayerLogic.defaultName(for: first.title,
                    existingNames: self.document.layers.map(\.name))
            }
            if self.availableOperations.isEmpty {
                self.setMessage("No supported adjustments are available.", isError: true)
            } else {
                self.clearMessage()
            }
            self.updateControlStates()
        }
    }

    private func installPicker() {
        adjustmentPopup.removeAllItems()
        adjustmentPopup.addItems(withTitles: availableOperations.map(\.title))
    }

    private var selectedOperation: EngineSession.FilterOperation? {
        let index = adjustmentPopup.indexOfSelectedItem
        guard index >= 0, index < availableOperations.count else { return nil }
        return availableOperations[index]
    }

    // MARK: Sheet routing (called by the owning window)

    /// The document's cached state changed: re-gate the controls. The
    /// draft (name, picker) is never reset — a failed Create keeps it.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too,
    /// keeping the draft so it can be corrected.
    func showError(_ message: String) {
        guard !isInvalidated else { return }
        refuse(message)
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update the sheet or open the
    /// phase-2 editor. Idempotent: the window's close path and the sheet's
    /// own completion may both run.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        panel.endEditing(for: nil)
    }

    // MARK: Controls

    private func updateControlStates() {
        // Cached busy/closing/mode state only — no native call here. While
        // an accepted Create runs, Create and Cancel are both disabled so
        // no duplicate can queue.
        let canEdit = !isInvalidated && !isCreating && !isLoadingOperations
        let admitted = AdjustmentLayerLogic.modeAdmission(document.colorInfo.mode).allowed
        nameField.isEnabled = canEdit
        adjustmentPopup.isEnabled = canEdit && !availableOperations.isEmpty
        cancelButton.isEnabled = !isInvalidated && !isCreating
        createButton.isEnabled = canEdit && !availableOperations.isEmpty
            && admitted && document.acceptsEdits
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    private func setMessage(_ message: String, isError: Bool) {
        lastError = isError ? message : nil
        messageLabel.textColor = isError ? .systemRed : .labelColor
        messageLabel.stringValue = message
    }

    private func clearMessage() {
        setMessage("", isError: false)
    }

    @objc private func adjustmentChanged(_ sender: Any?) {
        if let operation = selectedOperation, !nameIsCustom {
            nameField.stringValue = AdjustmentLayerLogic.defaultName(for: operation.title,
                existingNames: document.layers.map(\.name))
        }
        updateControlStates()
    }

    func controlTextDidChange(_ notification: Notification) {
        nameIsCustom = true
        updateControlStates()
    }

    // MARK: Actions

    /// Create: commits the field edit, validates the name and the cached
    /// mode gate, captures the document, name and operation, and queues
    /// the ONE counted native creation. On success the sheet ends and the
    /// existing effect-parameter editor opens on the created effect; on
    /// failure the draft is preserved and the error shown inline.
    @objc private func create(_ sender: Any?) {
        guard !isInvalidated, !isCreating, !isLoadingOperations else { return }
        panel.endEditing(for: nil)
        if let reason = AdjustmentLayerLogic.modeAdmission(document.colorInfo.mode).reason {
            refuse(reason)
            return
        }
        guard let operation = selectedOperation else {
            refuse("Choose an adjustment.")
            return
        }
        let name: String
        switch AdjustmentLayerLogic.validateName(nameField.stringValue) {
        case .failure(let error):
            refuse(error.message)
            return
        case .success(let trimmed):
            name = trimmed
        }
        clearMessage()
        isCreating = true
        updateControlStates()
        let owner = document
        owner.createAdjustmentLayer(name: name, operation: operation.name) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.isCreating = false
            switch result {
            case .success(let created):
                // The sheet's job is done; phase 2 opens through the
                // captured host, never the front window, and a closed host
                // skips it — the committed layer stays.
                let host = self.host
                let operationName = operation.name
                self.hostWindow?.endSheet(self.panel, returnCode: .alertFirstButtonReturn)
                host?.openAdjustmentEditor(effect: created.effect, on: created.layer, operationName: operationName)
            case .failure(let error):
                self.refuse(error.localizedDescription)
            }
            self.updateControlStates()
        }
    }

    /// Cancel: nothing was queued, so the sheet simply ends. Disabled
    /// while an accepted Create runs.
    @objc private func cancel(_ sender: Any?) {
        guard !isInvalidated, !isCreating else { return }
        hostWindow?.endSheet(panel, returnCode: .alertSecondButtonReturn)
    }
}
