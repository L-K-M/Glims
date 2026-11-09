import AppKit

/// The pure, UI-free rules behind Edit ▸ Create Resource ▸ Brush/Pattern
/// from Selection…: the resource-name and brush-spacing field rules (the
/// same bounds the facade's slot-129 pre-RPC gate enforces), admission of
/// the cached selection bounds — including the dimension cap that refuses
/// an oversized selection BEFORE any pixels are allocated — the cached
/// menu/sheet gate, and the sheet's phase machine. No windows, no engine —
/// unit tests drive this directly.
enum ResourceSelectionFormValidation {
    /// Why a field or the cached state cannot be accepted; the message is
    /// shown inline in the sheet.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The facade's resource label bound: 255 UTF-8 bytes (the native
    /// 256-byte label including its NUL terminator).
    static let nameMaxUTF8Bytes = EngineSession.resourceNameMaxUTF8Bytes
    /// The facade's per-side dimension bound of a created resource.
    static let maxDimension = EngineSession.resourceMaxDimension
    /// The brush spacing bound in percent; patterns take none (0).
    static let brushSpacingMinimum = 1
    static let brushSpacingMaximum = 1000

    // MARK: Name

    /// The resource name: nonempty UTF-8, no embedded NUL, no control
    /// characters (Unicode Cc, exactly what the native side rejects) and
    /// at most 255 UTF-8 bytes — the same rules as
    /// `EngineSession.validateResourceCreation`, applied to the field text
    /// before anything is queued.
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

    // MARK: Spacing

    /// Parses a whole non-negative integer from a whole string: empty text,
    /// whitespace, a sign, a decimal point and non-ASCII digits all fail.
    static func parseWholeInteger(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// The brush spacing in percent as the facade's UInt32: a brush takes a
    /// whole number from 1 to 1000; a pattern takes no spacing (the field is
    /// hidden and the value is 0); a gradient cannot be created from pixels.
    static func validateSpacing(_ text: String, kind: EngineSession.ResourceKind) -> Result<UInt32, Rejection> {
        switch kind {
        case .pattern:
            return .success(0)
        case .gradient:
            return .failure(Rejection(message: "Creating a gradient from pixels is not supported."))
        case .brush:
            guard let value = parseWholeInteger(text) else {
                return .failure(Rejection(message: "Enter the brush spacing in percent — a whole number, no other characters."))
            }
            guard value >= brushSpacingMinimum, value <= brushSpacingMaximum else {
                return .failure(Rejection(message: "The brush spacing must be from \(brushSpacingMinimum) to \(brushSpacingMaximum) percent."))
            }
            return .success(UInt32(value))
        }
    }

    // MARK: Selection admission

    /// The reason the cached selection bounds cannot become a resource, or
    /// nil when they can. A selection more than `maxDimension` pixels on
    /// either side is refused here — before any pixel buffer is allocated.
    /// The bounds come from the image's root selection mask, so any nonzero
    /// mask value counts — including soft coverage below the marching-ants
    /// threshold, which has bounds but no outline.
    static func oversizedReason(_ bounds: CGRect) -> String? {
        guard bounds.width.isFinite, bounds.height.isFinite else {
            return "The selection's bounds are not finite."
        }
        let width = Int(bounds.width), height = Int(bounds.height)
        if width > maxDimension || height > maxDimension {
            return "The selection is \(width) × \(height) pixels; a created resource may be at most \(maxDimension) pixels per side. Narrow the selection first."
        }
        return nil
    }

    /// Admission of the cached selection bounds: nil (no selection) or an
    /// oversized/empty bound is a rejection; otherwise the bounds pass.
    static func admission(bounds: CGRect?) -> Result<CGRect, Rejection> {
        guard let bounds, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 1, bounds.height >= 1 else {
            return .failure(Rejection(message: "There is no selection to create a resource from; select an area first."))
        }
        if let reason = oversizedReason(bounds) {
            return .failure(Rejection(message: reason))
        }
        return .success(bounds)
    }

    // MARK: Cached menu/sheet gate

    /// The cached-state reason a Create Resource command cannot run right
    /// now, or nil when it can — pure flags in, reason out, so menu
    /// validation and the sheet's open/accept gates make no native call.
    /// No gate keys on the paint target, its source kind or layer locks:
    /// the capture reads the merged image, which is valid for any target.
    static func menuRefusal(engineActivity: String?, plugInLabel: String?, isClosing: Bool,
                            isSavingForClose: Bool, isTransferringClipboard: Bool, previewOpen: Bool,
                            selectionBounds: CGRect?, kind: EngineSession.ResourceKind) -> String? {
        if let activity = engineActivity {
            return "\(activity)… Wait for it to finish before creating a \(kind.singular)."
        }
        if let label = plugInLabel {
            return "Finish or cancel “\(label)” first."
        }
        if isClosing { return ImageDocument.DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard {
            return ImageDocument.DocumentError.busy.localizedDescription
        }
        if previewOpen { return "Apply or cancel the filter preview first." }
        if case .failure(let rejection) = admission(bounds: selectionBounds) {
            return rejection.message
        }
        return nil
    }

    // MARK: Sheet phase machine

    /// The sheet's lifecycle: `editing` (fields editable, Apply/Cancel
    /// live), `accepting` (an accepted write is active; both buttons are
    /// gated), `closed` (the one-shot success ended the sheet).
    enum Phase: Equatable {
        case editing, accepting, closed
    }

    /// Apply pressed: only from `editing` with locally valid input does the
    /// phase move to `accepting`; anything else leaves it unchanged, so a
    /// reentrant or duplicate accept cannot start a second write.
    static func applyTransition(_ phase: Phase, locallyValid: Bool) -> Phase {
        guard phase == .editing, locallyValid else { return phase }
        return .accepting
    }

    /// The accepted write's completion: success closes the sheet, failure
    /// returns to `editing` with the draft preserved. A completion landing
    /// in any other phase is ignored (stale or duplicate).
    static func completionTransition(_ phase: Phase, success: Bool) -> Phase {
        guard phase == .accepting else { return phase }
        return success ? .closed : .editing
    }

    /// Cancel is allowed only while editing; while an accepted write is
    /// active the close is owned by the completion, never pretended to be a
    /// cancellation.
    static func cancelAllowed(_ phase: Phase) -> Bool {
        phase == .editing
    }

    /// The plain-language scope line shown in the sheet: the capture is the
    /// selected VISIBLE MERGED pixels of the captured document — soft edges
    /// included — and nothing else changes.
    static func scopeExplanation(kind: EngineSession.ResourceKind, documentName: String) -> String {
        let noun = kind == .brush ? "brush" : "pattern"
        return "Creates a new \(noun) from the selected visible merged pixels of “\(documentName)”. "
            + "Soft selection edges count as selected. The image's pixels, its selection, its history "
            + "and the clipboard are not changed."
    }
}

extension ImageDocument {
    /// One successfully created resource, as reported to the completion on
    /// the main actor exactly once: the engine handle, the exact name and
    /// the kind. The handle is session-local; persist a
    /// `ResourceIdentity`, never it.
    struct CreatedResource: Equatable {
        let id: EngineSession.ResourceID
        let name: String
        let kind: EngineSession.ResourceKind
    }
}

/// Edit ▸ Create Resource ▸ Brush/Pattern from Selection…: this document's
/// sheet. It is owned by one window controller (never a singleton) and
/// captures the document and the creation kind when opened, so two
/// documents keep independent sheets and an action on one document never
/// retargets to the front window. The fields are a local editable draft:
/// local and native errors — including a duplicate name — show inline and
/// keep the sheet open with the draft intact. Apply is gated while an
/// accepted write is active; the sheet closes only on the accepted write's
/// success, and a window/document close after acceptance lets the job drain
/// without any stale UI resurrecting (the completion checks `isInvalidated`).
@MainActor
final class ResourceSelectionSheetController: NSObject {
    let document: ImageDocument
    /// The creation kind captured at open.
    let kind: EngineSession.ResourceKind
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let nameField = NSTextField(string: "")
    private let spacingField = NSTextField(string: "10")
    private let scopeLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")

    /// The phase machine's current phase, driven only through
    /// `ResourceSelectionFormValidation`'s pure transitions.
    private(set) var phase: ResourceSelectionFormValidation.Phase = .editing
    /// Set on close; late completion/error callbacks then do nothing, so a
    /// closed window's accepted job cannot resurrect the sheet.
    private(set) var isInvalidated = false
    /// The last validation, gate or native refusal shown inline.
    private(set) var lastError: String?
    private var displayedGateReason: String?

    init(document: ImageDocument, kind: EngineSession.ResourceKind, hostWindow: NSWindow) {
        self.document = document
        self.kind = kind
        self.hostWindow = hostWindow
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = kind == .brush ? "Create Brush from Selection" : "Create Pattern from Selection"
        buildContent()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        nameField.setAccessibilityLabel("Resource name")
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        nameField.stringValue = kind == .brush ? "Brush from Selection" : "Pattern from Selection"
        spacingField.setAccessibilityLabel("Brush spacing, percent")
        spacingField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        // Keep the layout stable while making the unused pattern option
        // explicit. NSGridView can reset a content view's hidden state.
        spacingField.isEnabled = kind == .brush
        spacingField.isEditable = kind == .brush
        if kind != .brush { spacingField.stringValue = "Not used" }
        scopeLabel.setAccessibilityLabel("Create resource scope")
        scopeLabel.stringValue = ResourceSelectionFormValidation.scopeExplanation(kind: kind,
                                                                                 documentName: document.name)
        scopeLabel.lineBreakMode = .byWordWrapping
        scopeLabel.maximumNumberOfLines = 4
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        applyButton.setAccessibilityLabel("Apply resource creation")
        applyButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel resource creation")
        messageLabel.setAccessibilityLabel("Resource creation message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Spacing (%):"), spacingField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        let buttonRow = NSStackView(views: [applyButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [grid, scopeLabel, buttonRow, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 10
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
        panel.initialFirstResponder = nameField
    }

    // MARK: Control state

    /// Apply/Cancel are gated while an accepted write is active; the cached
    /// gate's reason stays visible when no inline error overrides it.
    private func updateControlStates() {
        let accepting = phase == .accepting
        let reason = document.createResourceRefusal(kind: kind)
        applyButton.isEnabled = !isInvalidated && !accepting && phase == .editing && reason == nil
        cancelButton.isEnabled = !isInvalidated && !accepting
        if let reason {
            // A temporary gate must not replace a draft's native or local
            // error, or clearing that gate would erase the useful error.
            if phase == .editing && (lastError == nil || lastError == displayedGateReason) { refuse(reason) }
            displayedGateReason = reason
        } else if let previous = displayedGateReason {
            displayedGateReason = nil
            if lastError == previous { clearMessage() }
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

    // MARK: Window routing (called by the owning window controller)

    /// The document's cached state changed: refresh the cached-gate
    /// enablement only.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too.
    func showError(_ message: String) {
        guard !isInvalidated, phase == .editing else { return }
        refuse(message)
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update or reopen the sheet.
    func invalidate() {
        isInvalidated = true
        panel.endEditing(for: nil)
    }

    // MARK: Actions

    /// Apply: local pure validation (name, spacing) and the cached gate
    /// first — any rejection keeps the sheet open, editable, with an inline
    /// reason and nothing queued. A valid Apply moves the phase to
    /// `accepting` (gating Apply/Cancel) and hands the document exactly one
    /// counted exclusive job; the document's completion runs on the main
    /// actor exactly once: success closes the sheet, failure returns to
    /// `editing` with the draft and the message preserved.
    @objc private func apply(_ sender: Any?) {
        guard !isInvalidated, phase == .editing else { return }
        panel.endEditing(for: nil)
        let nameResult = ResourceSelectionFormValidation.validateName(nameField.stringValue)
        let spacingResult = ResourceSelectionFormValidation.validateSpacing(spacingField.stringValue, kind: kind)
        let cachedRefusal = document.createResourceRefusal(kind: kind)
        let rejection: ResourceSelectionFormValidation.Rejection? = {
            if case .failure(let reason) = nameResult { return reason }
            if case .failure(let reason) = spacingResult { return reason }
            if let cachedRefusal { return ResourceSelectionFormValidation.Rejection(message: cachedRefusal) }
            return nil
        }()
        if let rejection {
            refuse(rejection.message)
            NSSound.beep()
            return
        }
        guard case .success(let name) = nameResult,
              case .success(let spacing) = spacingResult else { return }
        clearMessage()
        phase = ResourceSelectionFormValidation.applyTransition(phase, locallyValid: true)
        updateControlStates()
        let capturedKind = kind
        document.createResourceFromSelection(kind: capturedKind, name: name, brushSpacing: spacing) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            self.phase = ResourceSelectionFormValidation.completionTransition(self.phase, success: success)
            switch result {
            case .success:
                // The beginSheet callback invalidates and releases the
                // controller; the accepted work was already counted.
                self.hostWindow?.endSheet(self.panel)
            case .failure(let error):
                // Native or busy failure after acceptance: the draft stays
                // editable and the reason shows inline.
                self.refuse(error.localizedDescription)
                self.updateControlStates()
            }
        }
        updateControlStates()
    }

    /// Cancel: only while editing — never while an accepted write is active
    /// (its close belongs to the completion). Closes with no mutation.
    @objc private func cancel(_ sender: Any?) {
        guard !isInvalidated, ResourceSelectionFormValidation.cancelAllowed(phase) else { return }
        hostWindow?.endSheet(panel)
    }
}
