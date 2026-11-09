import AppKit

/// The pure, UI-free rules behind Edit ▸ Create Resource ▸ Gradient…:
/// the whole draft — the name plus both endpoints as plain sRGB RGBA
/// values — through the same `EngineSession.validateGradientCreation` gate
/// the facade's slot-138 `EngineSession.createGradient` applies before its
/// RPC (the name exactly as typed, never trimmed; the .ggr ASCII
/// edge-whitespace refusal; every endpoint component, alpha included,
/// finite inside 0...1, never clamped), the endpoint conversion from a
/// color well's NSColor on the main thread, the cached document gate and
/// the field-acceptance rule. No windows, no engine — unit tests drive
/// this directly.
enum GradientCreateValidation {
    /// Why a field or the cached state cannot be accepted; the message is
    /// shown inline in the sheet.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The accepted draft captured at Create: the name exactly as typed
    /// and both endpoints as immutable plain data, so the native write
    /// never sees NSColor or AppKit.
    struct Draft: Equatable {
        let name: String
        let left: EngineSession.RGBAColor
        let right: EngineSession.RGBAColor
    }

    /// The whole draft through the facade's pre-RPC gate,
    /// `EngineSession.validateGradientCreation`: unchanged on success.
    static func validate(name: String, left: EngineSession.RGBAColor,
                         right: EngineSession.RGBAColor) -> Result<Draft, Rejection> {
        do {
            try EngineSession.validateGradientCreation(name: name, left: left, right: right)
            return .success(Draft(name: name, left: left, right: right))
        } catch let error as EngineSession.EngineError {
            return .failure(Rejection(message: error.message))
        } catch {
            return .failure(Rejection(message: String(describing: error)))
        }
    }

    /// One color well's current color as plain sRGB data — the conversion
    /// runs HERE on the main thread and the returned value is immutable
    /// plain data, the only thing the worker ever sees. A color that does
    /// not convert (a pattern) is one rejection; the component range is
    /// enforced by `validate`, never clamped here.
    static func endpoint(_ color: NSColor, label: String) -> Result<EngineSession.RGBAColor, Rejection> {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return .failure(Rejection(message: "The \(label) endpoint color must be convertible to sRGB."))
        }
        return .success(EngineSession.RGBAColor(
            red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent)))
    }

    /// The cached-state reason a Gradient… write cannot run right now, or
    /// nil when it can — pure flags in, reason out, so menu validation and
    /// the sheet's open/accept gates make no native call on the main
    /// thread. The gradient catalog is global and the write touches no
    /// image, so no gate keys on the selection, the paint target, layer or
    /// channel targets, a floating selection or the file state.
    static func gate(engineActivity: String?, plugInLabel: String?, isClosing: Bool,
                     isSavingForClose: Bool, isTransferringClipboard: Bool,
                     previewOpen: Bool) -> String? {
        if let activity = engineActivity {
            return "\(activity)… Wait for it to finish before creating a gradient."
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

    /// Whether the fields and Create accept input right now: only while
    /// the sheet is editing. An accepted write owns its own close, so both
    /// are gated until its completion.
    static func acceptsInput(_ phase: ResourceSelectionFormValidation.Phase) -> Bool {
        phase == .editing
    }
}

/// The sheet's small endpoint preview: a code-native left-to-right
/// two-stop gradient of the endpoint colors the wells hold right now,
/// drawn with Core Graphics. Nothing engine-rendered is shown or implied.
final class GradientPreviewView: NSView {
    var leftColor: NSColor = .black { didSet { needsDisplay = true } }
    var rightColor: NSColor = .white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [leftColor.cgColor, rightColor.cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: bounds.minX, y: bounds.midY),
                                   end: CGPoint(x: bounds.maxX, y: bounds.midY), options: [])
    }
}

/// Edit ▸ Create Resource ▸ Gradient…: this document's sheet. It is owned
/// by one window controller (never a singleton) and captures the document
/// when opened, so two documents keep independent sheets and an action on
/// one document never retargets to the front window. The wells are seeded
/// from the current foreground/background colors captured as sRGB on the
/// main thread at open; Create converts the wells to immutable RGBA values
/// HERE on the main thread and hands the document exactly one counted
/// exclusive job (facade slot 138), whose native call runs off the main
/// thread with plain data only. Invalid field values disable Create and
/// show the reason inline; a native refusal — including a duplicate name
/// — keeps the draft for retry. An accepted write gates the fields and
/// both buttons and owns the close; a window close after acceptance lets
/// the job drain on the document without any stale UI resurrecting (the
/// completion checks `isInvalidated`). Cancel closes with no mutation.
@MainActor
private final class GradientEndpointWell: NSColorWell {
    var willActivate: (() -> Void)?
    override func activate(_ exclusive: Bool) {
        willActivate?()
        super.activate(exclusive)
    }
}

@MainActor
final class GradientCreateSheetController: NSObject {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let nameField = NSTextField(string: "")
    private let leftWell = GradientEndpointWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let rightWell = GradientEndpointWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let preview = GradientPreviewView()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")

    /// The phase machine's current phase, driven only through
    /// `ResourceSelectionFormValidation`'s pure transitions.
    private(set) var phase: ResourceSelectionFormValidation.Phase = .editing
    /// Set on close; late completion/error callbacks then do nothing, so a
    /// closed window's accepted job cannot resurrect the sheet.
    private(set) var isInvalidated = false
    /// The validation, gate or native refusal currently shown inline.
    private(set) var lastError: String?
    /// The native refusal of the last accepted write; cleared only after
    /// the next successful local validation, never by a passing gate.
    private var nativeError: String?
    /// Whether the color panel was already visible when the sheet opened;
    /// the sheet then leaves it alone on close.
    private let colorPanelWasVisible: Bool
    private var legacyAlphaBefore: Bool?

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 350),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Create Gradient"
        buildContent()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        nameField.setAccessibilityLabel("Gradient name")
        nameField.stringValue = "New Gradient"
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        leftWell.setAccessibilityLabel("Gradient left endpoint")
        leftWell.color = ToolState.shared.foreground.usingColorSpace(.sRGB) ?? .black
        leftWell.target = self
        leftWell.action = #selector(colorsChanged(_:))
        rightWell.setAccessibilityLabel("Gradient right endpoint")
        rightWell.color = ToolState.shared.background.usingColorSpace(.sRGB) ?? .white
        rightWell.target = self
        rightWell.action = #selector(colorsChanged(_:))
        for well in [leftWell, rightWell] {
            if #available(macOS 14, *) {
                well.supportsAlpha = true
            } else {
                well.willActivate = { [weak self] in
                    guard let self else { return }
                    if self.legacyAlphaBefore == nil { self.legacyAlphaBefore = NSColorPanel.shared.showsAlpha }
                    NSColorPanel.shared.showsAlpha = true
                }
            }
            well.widthAnchor.constraint(equalToConstant: 64).isActive = true
            well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        preview.setAccessibilityLabel("Gradient preview")
        preview.widthAnchor.constraint(equalToConstant: 220).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 28).isActive = true
        createButton.setAccessibilityLabel("Create gradient")
        createButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel gradient")
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [createButton, cancelButton] as [NSButton] {
            button.widthAnchor.constraint(equalToConstant: 88).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        messageLabel.setAccessibilityLabel("Gradient creation message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        createButton.target = self
        createButton.action = #selector(create(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Left:"), leftWell],
            [NSTextField(labelWithString: "Right:"), rightWell],
            [NSTextField(labelWithString: "Preview:"), preview],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        let scopeLabel = NSTextField(labelWithString: "")
        scopeLabel.setAccessibilityLabel("Gradient creation scope")
        scopeLabel.stringValue = "Create a reusable gradient from two colors. "
            + "Choose it from the Gradient tool’s resource list."
        scopeLabel.lineBreakMode = .byWordWrapping
        scopeLabel.maximumNumberOfLines = 3
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let buttonRow = NSStackView(views: [createButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [grid, scopeLabel, buttonRow, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        // The content size is fixed at init and the stack fills it exactly:
        // no fittingSize measurement and no content-view resizing, so no
        // button can land outside the panel's bounds.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        panel.initialFirstResponder = nameField
        syncPreview()
        // The same notification the field editor posts on every typed
        // change, so a live edit revalidates the draft immediately.
        NotificationCenter.default.addObserver(self, selector: #selector(nameEdited(_:)),
                                               name: NSControl.textDidChangeNotification, object: nameField)
    }

    private func syncPreview() {
        preview.leftColor = leftWell.color
        preview.rightColor = rightWell.color
    }

    @objc private func colorsChanged(_ sender: NSColorWell) {
        syncPreview()
        updateControlStates()
    }

    @objc private func nameEdited(_ notification: Notification) {
        updateControlStates()
    }

    // MARK: Control state

    /// The current fields' draft, converted on the main thread: the wells
    /// to plain RGBA values and the whole request through the facade's
    /// pre-RPC validation.
    private func currentDraft() -> Result<GradientCreateValidation.Draft, GradientCreateValidation.Rejection> {
        switch GradientCreateValidation.endpoint(leftWell.color, label: "left") {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let left):
            switch GradientCreateValidation.endpoint(rightWell.color, label: "right") {
            case .failure(let rejection):
                return .failure(rejection)
            case .success(let right):
                return GradientCreateValidation.validate(name: nameField.stringValue, left: left, right: right)
            }
        }
    }

    /// Create is enabled only while editing with a valid draft and no
    /// cached gate; the fields and both buttons are gated while an accepted
    /// write is active. The inline message prefers the draft's own
    /// rejection, then the native error, then the cached gate's reason — a
    /// temporary gate never replaces a draft's native or local error.
    private func updateControlStates() {
        let accepting = !GradientCreateValidation.acceptsInput(phase)
        let gateReason = document.createGradientRefusal()
        let draftReason = accepting ? nil : currentDraft().failureMessage
        createButton.isEnabled = !isInvalidated && !accepting && gateReason == nil && draftReason == nil
        cancelButton.isEnabled = !isInvalidated && !accepting
        nameField.isEnabled = !isInvalidated && !accepting
        leftWell.isEnabled = !isInvalidated && !accepting
        rightWell.isEnabled = !isInvalidated && !accepting
        let message = draftReason ?? nativeError ?? (accepting ? nil : gateReason)
        lastError = message
        messageLabel.stringValue = message ?? ""
        messageLabel.textColor = message == nil ? .labelColor : .systemRed
    }

    // MARK: Window routing (called by the owning window controller)

    /// The document's cached state changed: refresh the cached-gate and
    /// draft enablement only.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too.
    func showError(_ message: String) {
        guard !isInvalidated, phase == .editing else { return }
        nativeError = message
        updateControlStates()
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update or reopen the sheet, and
    /// the sheet's own color panel activation is released. An accepted
    /// write is never cancelled by this; its counted job drains on the
    /// document and the completion is dropped by the `isInvalidated` guard.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        NotificationCenter.default.removeObserver(self)
        panel.endEditing(for: nil)
        let ownsColorPanel = leftWell.isActive || rightWell.isActive
        if ownsColorPanel && !colorPanelWasVisible { NSColorPanel.shared.orderOut(nil) }
        if ownsColorPanel, let legacyAlphaBefore { NSColorPanel.shared.showsAlpha = legacyAlphaBefore }
        leftWell.deactivate()
        rightWell.deactivate()
    }

    // MARK: Actions

    /// Create: the pure draft validation and the cached gate first — any
    /// rejection keeps the sheet open, editable, with an inline reason and
    /// nothing queued. A valid Create converts the wells to immutable RGBA
    /// values, moves the phase to `accepting` (gating the fields and both
    /// buttons) and hands the document exactly one counted exclusive job;
    /// the completion runs on the main actor exactly once: success closes
    /// the sheet and reports the created resource, failure returns to
    /// `editing` with the draft and message preserved for retry.
    @objc private func create(_ sender: Any?) {
        guard !isInvalidated, phase == .editing else { return }
        panel.endEditing(for: nil)
        switch currentDraft() {
        case .failure(let rejection):
            refuse(rejection)
        case .success(let draft):
            if let reason = document.createGradientRefusal() {
                refuse(GradientCreateValidation.Rejection(message: reason))
                return
            }
            // The old error clears only now, after successful local
            // validation.
            nativeError = nil
            phase = ResourceSelectionFormValidation.applyTransition(phase, locallyValid: true)
            updateControlStates()
            document.createGradient(name: draft.name, left: draft.left, right: draft.right) { [weak self] result in
                guard let self, !self.isInvalidated else { return }
                let succeeded: Bool
                if case .success = result { succeeded = true } else { succeeded = false }
                self.phase = ResourceSelectionFormValidation.completionTransition(self.phase, success: succeeded)
                switch result {
                case .success:
                    // The beginSheet callback invalidates and releases the
                    // controller; the accepted work was already counted.
                    self.hostWindow?.endSheet(self.panel)
                case .failure(let error):
                    // Native or busy failure after acceptance: the draft
                    // stays editable and the reason shows inline for retry.
                    self.nativeError = error.localizedDescription
                    self.updateControlStates()
                }
            }
            updateControlStates()
        }
    }

    private func refuse(_ rejection: GradientCreateValidation.Rejection) {
        lastError = rejection.message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = rejection.message
        NSSound.beep()
        updateControlStates()
    }

    /// Cancel: only while editing — never while an accepted write is active
    /// (its close belongs to the completion). Closes with no mutation.
    @objc private func cancel(_ sender: Any?) {
        guard !isInvalidated, ResourceSelectionFormValidation.cancelAllowed(phase) else { return }
        hostWindow?.endSheet(panel)
    }
}

private extension Result where Success == GradientCreateValidation.Draft,
                                Failure == GradientCreateValidation.Rejection {
    var failureMessage: String? {
        if case .failure(let rejection) = self { return rejection.message }
        return nil
    }
}
