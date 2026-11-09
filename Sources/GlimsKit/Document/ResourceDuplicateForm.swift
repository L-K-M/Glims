import AppKit

/// The pure, UI-free rules behind the choosers' Duplicate… command: the
/// captured source of a duplication, the shared resource-name contract
/// (the same `EngineSession.validateResourceName` slot 131 applies before
/// its RPC), the cached document gate and the proposed draft name. No
/// windows, no engine — unit tests drive this directly.
enum ResourceDuplicateValidation {
    /// Why the form cannot accept right now; the message shows inline.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The captured source of one Duplicate… form, fixed when the form
    /// opens: the resource's persistent identity, its session-local native
    /// handle (in memory only, never persisted) and its kind. A `Source`
    /// is a value, so later table-highlight, tool, document or front-window
    /// changes cannot alter what a form duplicates.
    struct Source: Equatable {
        let kind: EngineSession.ResourceKind
        let id: EngineSession.ResourceID
        let identity: EngineSession.ResourceIdentity
        /// The source's persistent name.
        var name: String { identity.name }
    }

    /// The editable draft proposed when the form opens. A suggestion only:
    /// the field text is what `validateName` checks, unchanged.
    static func proposedName(_ source: Source) -> String {
        "\(source.identity.name) copy"
    }

    /// The shared label contract — nonempty UTF-8, no embedded NUL, at most
    /// 255 UTF-8 bytes, no Unicode Cc control characters — through the same
    /// `EngineSession.validateResourceName` the facade's slot 131 pre-RPC
    /// gate uses. The input is returned exactly as typed: no trimming, no
    /// normalization.
    static func validateName(_ text: String) -> Result<String, Rejection> {
        do {
            try EngineSession.validateResourceName(text)
            return .success(text)
        } catch let error as EngineSession.EngineError {
            return .failure(Rejection(message: error.message))
        } catch {
            return .failure(Rejection(message: String(describing: error)))
        }
    }

    /// Why `source` is not a duplicatable resource, or nil when it is. The
    /// choosers' Default row carries a nil resource: it is not a saved
    /// resource and cannot be duplicated.
    static func sourceRefusal(_ source: Source?, kind: EngineSession.ResourceKind) -> String? {
        guard source == nil else { return nil }
        switch kind {
        case .brush:
            return "Select a saved brush row to duplicate — the Default row is not a saved resource."
        case .gradient:
            return "Select a saved gradient row to duplicate — the Foreground to Background Default is not a saved resource."
        case .pattern:
            return "Select a saved pattern row to duplicate."
        }
    }

    /// The cached-state reason a Duplicate… write cannot run right now, or
    /// nil when it can — pure flags in, reason out, so the form's Create gate
    /// makes no native call on the main thread.
    static func gate(engineActivity: String?, plugInLabel: String?, isClosing: Bool,
                     isSavingForClose: Bool, isTransferringClipboard: Bool, previewOpen: Bool,
                     kind: EngineSession.ResourceKind) -> String? {
        if let activity = engineActivity {
            return "\(activity)… Wait for it to finish before duplicating a \(kind.singular)."
        }
        if let label = plugInLabel {
            return "Finish or cancel “\(label)” first."
        }
        if isClosing { return ImageDocument.DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard {
            return ImageDocument.DocumentError.busy.localizedDescription
        }
        if previewOpen { return "Apply or cancel the filter preview first." }
        return nil
    }
}

/// The shared Duplicate… form of the brush, gradient and pattern choosers:
/// a properly owned NONMODAL child panel of the host's window — never a
/// nested AppKit sheet, so the pattern picker embedded inside the Fill sheet
/// can use it too. It shows the captured source (read-only) and an editable
/// name draft with Create / Cancel and inline native or local errors.
///
/// The host (a chooser panel or the embedded picker) owns the controller:
/// dismissing the picker, its document, its window or the app invalidates
/// the form, and a late completion then only drains the document's counted
/// job without touching any view or retargeting. Create/Cancel are disabled
/// while an accepted write is active — that close belongs to the completion,
/// never a pretended cancellation. The only native write is the document's
/// counted `duplicateResource` route (facade slot 131); source-specific
/// native refusals (VBR/GGR edge whitespace, unsupported PAT formats) arrive
/// as ordinary inline errors and keep the editable draft for retry.
@MainActor
final class ResourceDuplicateFormController: NSObject, NSWindowDelegate {
    let document: ImageDocument
    /// The source captured ONCE when the form opened.
    let source: ResourceDuplicateValidation.Source
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let nameField = NSTextField(string: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")

    /// The phase machine's current phase, driven only through
    /// `ResourceSelectionFormValidation`'s pure transitions.
    private(set) var phase: ResourceSelectionFormValidation.Phase = .editing
    /// Set on close; late completion/error callbacks then do nothing, so a
    /// closed host's accepted job cannot resurrect the form.
    private(set) var isInvalidated = false
    /// The last validation, gate or native refusal shown inline.
    private(set) var lastError: String?
    private var displayedGateReason: String?

    /// Called once on the main actor after the accepted write succeeded and
    /// the form closed; the host reloads its chooser catalog here.
    var onSucceeded: ((ImageDocument.CreatedResource) -> Void)?
    /// Called once when the form closes for any reason; the host releases
    /// its reference here.
    var onClosed: (() -> Void)?

    init(document: ImageDocument, source: ResourceDuplicateValidation.Source, hostWindow: NSWindow?) {
        self.document = document
        self.source = source
        self.hostWindow = hostWindow
        let noun = source.kind.singular.capitalized
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 190),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Duplicate \(noun)"
        panel.delegate = self
        buildContent()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        sourceLabel.setAccessibilityLabel("Duplicate source")
        sourceLabel.stringValue = "Source: \(source.name)"
        sourceLabel.font = .systemFont(ofSize: 11)
        nameField.setAccessibilityLabel("Duplicate resource name")
        nameField.stringValue = ResourceDuplicateValidation.proposedName(source)
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        createButton.setAccessibilityLabel("Create duplicate")
        createButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel duplicate")
        cancelButton.keyEquivalent = "\u{1b}"
        messageLabel.setAccessibilityLabel("Duplicate message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        createButton.target = self
        createButton.action = #selector(create(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        let buttonRow = NSStackView(views: [createButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [sourceLabel, grid, buttonRow, messageLabel])
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

    // MARK: Presentation

    /// Shows the form as a nonmodal child of the host's window (above it),
    /// or standalone when the host has no window.
    func show() {
        guard !isInvalidated else { return }
        if let hostWindow, hostWindow.isVisible {
            hostWindow.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        updateControlStates()
    }

    // MARK: Control state

    /// Create/Cancel are gated while an accepted write is active; the cached
    /// gate's reason stays visible when no inline error overrides it. Mirrors
    /// `ResourceSelectionSheetController`'s corrected error behavior: a
    /// temporary gate never replaces a draft's native or local error, and the
    /// old error is cleared only after successful local validation.
    private func updateControlStates() {
        let accepting = phase == .accepting
        let reason = document.duplicateResourceRefusal(kind: source.kind)
        createButton.isEnabled = !isInvalidated && !accepting && phase == .editing && reason == nil
        cancelButton.isEnabled = !isInvalidated && !accepting
        if let reason {
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

    /// The document's cached state changed: refresh the cached-gate
    /// enablement only.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// Commits an in-flight field edit (the host's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup — host dismissal, window closing, Cancel, success: no
    /// later callback may update or reopen the form. An accepted write is
    /// never cancelled by this; its counted job drains on the document and
    /// the completion is dropped by the `isInvalidated` guard.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        panel.endEditing(for: nil)
        panel.orderOut(nil)
        onClosed?()
    }

    // MARK: Actions

    /// Create: local pure validation (the shared name contract) and the
    /// cached gate first — any rejection keeps the form open, editable, with
    /// an inline reason and nothing queued. A valid Create moves the phase to
    /// `accepting` (gating Create/Cancel) and hands the document exactly one
    /// counted exclusive job; the completion runs on the main actor exactly
    /// once: success closes the form and reports the created resource,
    /// failure returns to `editing` with the draft and message preserved.
    @objc private func create(_ sender: Any?) {
        guard !isInvalidated, phase == .editing else { return }
        panel.endEditing(for: nil)
        let nameResult = ResourceDuplicateValidation.validateName(nameField.stringValue)
        let gateReason = document.duplicateResourceRefusal(kind: source.kind)
        if case .failure(let rejection) = nameResult {
            refuse(rejection.message)
            NSSound.beep()
            return
        }
        if let gateReason {
            refuse(gateReason)
            NSSound.beep()
            return
        }
        guard case .success(let name) = nameResult else { return }
        // The old error clears only now, after successful local validation.
        clearMessage()
        phase = ResourceSelectionFormValidation.applyTransition(phase, locallyValid: true)
        updateControlStates()
        document.duplicateResource(source: source, name: name) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            self.phase = ResourceSelectionFormValidation.completionTransition(self.phase, success: success)
            switch result {
            case .success(let created):
                self.invalidate()
                self.onSucceeded?(created)
            case .failure(let error):
                // Native or busy failure after acceptance: the draft stays
                // editable and the reason shows inline for retry.
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
        invalidate()
    }

    func windowWillClose(_ notification: Notification) {
        invalidate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateControlStates()
    }
}
