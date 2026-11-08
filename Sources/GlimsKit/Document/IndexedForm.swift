import AppKit

/// Pure logic behind Image ▸ Mode ▸ Indexed…: the strict custom-palette
/// parser, the cached native-eligibility gate, the form's choice lists and
/// the validated settings builder. No AppKit state, so the rules are
/// unit-testable without an engine.
enum IndexedFormLogic {

    /// A user-facing refusal of the form's own input, before anything
    /// queues.
    struct InputError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The palette popup's choices, in display order, carrying the
    /// facade's own enum values.
    static let paletteChoices: [(value: EngineSession.IndexedPalette, title: String)] = [
        (.generated, "Generated"), (.web, "Web"), (.mono, "Monochrome"), (.custom, "Custom"),
    ]

    /// The dithering popup's choices, in display order.
    static let ditherChoices: [(value: EngineSession.IndexedDither, title: String)] = [
        (.none, "None"), (.floydSteinberg, "FS"),
        (.floydSteinbergLowBleed, "Reduced Bleeding"), (.fixed, "Ordered"),
    ]

    /// `max_colors` for the Generated palette: 2 ... 256.
    static func isValidMaxColors(_ value: Int) -> Bool {
        (2...256).contains(value)
    }

    /// The custom palette's color count: 1 ... 256.
    static func isValidCustomColorCount(_ count: Int) -> Bool {
        (1...256).contains(count)
    }

    /// Strictly parses the Custom palette's plain multiline text: exactly
    /// one `#RRGGBB` color per nonblank line — a leading `#` followed by
    /// exactly six ASCII hex digits, nothing else — and blank (empty)
    /// lines are allowed and skipped. No trimming, sign, `#RGB` shorthand,
    /// whitespace, CRLF or any other decoration is accepted; a NUL anywhere
    /// refuses the whole text before any color is built. Returns opaque
    /// sRGB colors, or the offending line's reason.
    static func parseCustomPalette(_ text: String) -> Result<[NSColor], InputError> {
        if text.utf8.contains(0) {
            return .failure(InputError(message: "The palette text contains invalid characters."))
        }
        var colors: [NSColor] = []
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            let lineNumber = offset + 1
            if line.isEmpty { continue }
            let bytes = Array(line.utf8)
            guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else {
                return .failure(InputError(message: "Line \(lineNumber) is not a #RRGGBB color: exactly a # followed by six hex digits."))
            }
            var components: [Double] = []
            for byte in bytes[1...] {
                let digit: Int
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(byte - UInt8(ascii: "A")) + 10
                default:
                    return .failure(InputError(message: "Line \(lineNumber) is not a #RRGGBB color: \"\(line)\" has a non-hex character."))
                }
                components.append(Double(digit))
            }
            let red = (components[0] * 16 + components[1]) / 255
            let green = (components[2] * 16 + components[3]) / 255
            let blue = (components[4] * 16 + components[5]) / 255
            colors.append(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        }
        guard isValidCustomColorCount(colors.count) else {
            return .failure(InputError(message: colors.isEmpty
                ? "Enter at least one #RRGGBB color, one per line."
                : "A custom palette holds at most 256 colors; this text has \(colors.count)."))
        }
        return .success(colors)
    }

    /// The native eligibility gate, read from cached state only: the
    /// engine's indexed conversion accepts exactly u8 non-linear precision
    /// and a flat layer stack. Precision is never auto-converted and
    /// groups are never auto-flattened — the item says why instead.
    struct Eligibility: Equatable {
        let allowed: Bool
        let reason: String?
    }

    static func nativeEligibility(mode: EngineSession.ColorMode,
                                  component: EngineSession.ColorComponent,
                                  trc: EngineSession.ColorTRC,
                                  hasGroup: Bool) -> Eligibility {
        if mode == .indexed {
            return Eligibility(allowed: false, reason: "The image is already indexed.")
        }
        if component != .u8 || trc != .nonlinear {
            return Eligibility(allowed: false,
                reason: "Indexed conversion needs 8-bit non-linear precision. The precision is never changed automatically — convert it with Image ▸ Precision… first.")
        }
        if hasGroup {
            return Eligibility(allowed: false,
                reason: "Indexed conversion needs a flat layer stack. The image has layer groups, and they are never flattened automatically.")
        }
        return Eligibility(allowed: true, reason: nil)
    }

    /// The form's raw field values, captured at Apply.
    struct FormValues: Equatable {
        var palette: EngineSession.IndexedPalette = .generated
        var maxColors: Int = 256
        var removeUnused = true
        var dither: EngineSession.IndexedDither = .none
        var ditherAlpha = false
        var ditherText = false
        var customText = ""
    }

    /// Builds the validated facade settings for captured form values.
    /// `maxColors` is checked only for Generated (2 ... 256); Custom
    /// parses its text strictly; `removeUnused` is honored by the engine
    /// for Web and Custom only, so it is forced off elsewhere.
    static func makeSettings(_ values: FormValues,
                             preservation: EngineSession.IndexedPreservation) -> Result<EngineSession.IndexedSettings, InputError> {
        var settings = EngineSession.IndexedSettings()
        settings.palette = values.palette
        settings.dither = values.dither
        settings.ditherAlpha = values.ditherAlpha
        settings.ditherText = values.ditherText
        settings.preservation = preservation
        switch values.palette {
        case .generated:
            guard isValidMaxColors(values.maxColors) else {
                return .failure(InputError(message: "The generated palette takes from 2 to 256 colors."))
            }
            settings.maxColors = Int32(values.maxColors)
            settings.removeUnused = false
        case .web, .mono:
            settings.removeUnused = values.palette == .web && values.removeUnused
        case .custom:
            switch parseCustomPalette(values.customText) {
            case .success(let colors):
                settings.customColors = colors
                settings.removeUnused = values.removeUnused
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(settings)
    }
}

/// Image ▸ Mode ▸ Indexed…: the document-owned conversion policy sheet.
/// The owning window controller retains this controller for the sheet's
/// lifetime, and the DOCUMENT is captured when the sheet opens — Apply and
/// the rasterization confirmation always act on that captured document,
/// never on the global or front document, so a retarget cannot redirect
/// the conversion. The sheet reads only cached state to open and to gate;
/// the conversion itself goes through the document's counted exclusive
/// `convertToIndexed`.
///
/// Apply always starts with `preserveEditable`. Only an
/// `EngineError.requiresRasterization` answer admits the inline
/// confirmation region in the SAME sheet (no nested sheet): the validated
/// settings are preserved, the fields stay disabled, and Rasterize and
/// Convert / Back / Cancel are offered. Confirm re-runs the captured
/// settings with `allowRasterize` on the captured document only. Every
/// other native error stays visible in the sheet and is never
/// reinterpreted as consent. Local invalid input (a bad custom palette or
/// color count) shows inline, mutates nothing and does not close the
/// sheet. Once native work is accepted the mutating controls stay
/// disabled and no Cancel is offered; close and late completion are gated
/// by invalidating the controller while the document's accepted work
/// remains counted and drained.
@MainActor
final class IndexedSheetController: NSObject {
    /// The document captured at sheet open; every action uses it.
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let infoLabel = NSTextField(labelWithString: "")
    private let palettePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maxColorsField = NSTextField(string: "256")
    private let maxColorsStepper = NSStepper()
    private let customTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
    private let removeUnusedBox = NSButton(checkboxWithTitle: "Remove unused colors", target: nil, action: nil)
    private let ditherPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ditherAlphaBox = NSButton(checkboxWithTitle: "Dither transparency", target: nil, action: nil)
    private let ditherTextBox = NSButton(checkboxWithTitle: "Dither text", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let convertButton = NSButton(title: "Convert", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let confirmationBox: NSBox
    private let confirmationText = NSTextField(labelWithString: "")
    private let rasterizeButton = NSButton(title: "Rasterize and Convert", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let consentCancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// The sheet's phase: editing the form, awaiting the rasterization
    /// consent, or running an accepted conversion.
    private enum Phase { case editing, running, awaitingConsent }
    private var phase: Phase = .editing
    /// The validated settings captured at Apply, preserved across the
    /// consent step; Confirm swaps only the preservation policy.
    private var capturedSettings: EngineSession.IndexedSettings?
    /// The outcome of the latest accepted attempt, delivered exactly once.
    private(set) var lastResult: Result<Void, Error>?
    /// The last validation or native refusal shown in the sheet.
    private(set) var lastError: String?
    /// Set on close; late callbacks and completions then do nothing.
    private var isInvalidated = false

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
                             styleMask: [.titled, .utilityWindow],
                             backing: .buffered, defer: false)
        self.confirmationBox = NSBox()
        super.init()
        panel.title = "Convert to Indexed"
        buildContent()
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        infoLabel.stringValue = "Converts the whole image to indexed colors as one undo step. "
            + "The image must be 8-bit non-linear without layer groups: the precision is never changed "
            + "and groups are never flattened automatically. Editable text stays editable unless "
            + "Dither text is on, which asks before rasterizing."
        infoLabel.setAccessibilityLabel("Indexed conversion information")
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 0
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        palettePopup.addItems(withTitles: IndexedFormLogic.paletteChoices.map(\.title))
        palettePopup.selectItem(at: 0)
        palettePopup.setAccessibilityLabel("Palette")
        palettePopup.target = self
        palettePopup.action = #selector(paletteChanged(_:))

        maxColorsField.setAccessibilityLabel("Maximum colors")
        maxColorsField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        maxColorsStepper.setAccessibilityLabel("Maximum colors stepper")
        maxColorsStepper.minValue = 2
        maxColorsStepper.maxValue = 256
        maxColorsStepper.increment = 1
        maxColorsStepper.integerValue = 256
        maxColorsStepper.target = self
        maxColorsStepper.action = #selector(maxColorsStepped(_:))

        let customScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        customScroll.hasVerticalScroller = true
        customScroll.borderType = .bezelBorder
        customScroll.documentView = customTextView
        customTextView.isEditable = true
        customTextView.isRichText = false
        customTextView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customTextView.setAccessibilityLabel("Custom palette colors")
        let customHint = NSTextField(labelWithString: "One #RRGGBB color per line; blank lines are ignored.")
        customHint.setAccessibilityLabel("Custom palette hint")
        customHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let customStack = NSStackView(views: [customScroll, customHint])
        customStack.orientation = .vertical
        customStack.spacing = 2

        removeUnusedBox.setAccessibilityLabel("Remove unused colors")
        ditherPopup.addItems(withTitles: IndexedFormLogic.ditherChoices.map(\.title))
        ditherPopup.selectItem(at: 0)
        ditherPopup.setAccessibilityLabel("Dithering")
        ditherAlphaBox.setAccessibilityLabel("Dither transparency")
        ditherTextBox.setAccessibilityLabel("Dither text")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Palette:"), palettePopup],
            [NSTextField(labelWithString: "Maximum colors:"), maxColorsField, maxColorsStepper],
            [NSTextField(labelWithString: "Custom colors:"), customStack],
            [NSGridCell.emptyContentView, removeUnusedBox],
            [NSTextField(labelWithString: "Dithering:"), ditherPopup],
            [NSGridCell.emptyContentView, ditherAlphaBox],
            [NSGridCell.emptyContentView, ditherTextBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        messageLabel.setAccessibilityLabel("Indexed conversion message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0

        convertButton.setAccessibilityLabel("Convert")
        convertButton.target = self
        convertButton.action = #selector(apply(_:))
        convertButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        let formButtons = NSStackView(views: [convertButton, cancelButton])
        formButtons.orientation = .horizontal
        formButtons.spacing = 8
        formButtons.setAccessibilityLabel("Indexed actions")

        confirmationText.stringValue = "This image holds editable text, vector or linked layers. "
            + "Converting with Dither text rasterizes them inside the one undo step."
        confirmationText.setAccessibilityLabel("Rasterization confirmation text")
        confirmationText.lineBreakMode = .byWordWrapping
        confirmationText.maximumNumberOfLines = 0
        rasterizeButton.setAccessibilityLabel("Rasterize and Convert")
        rasterizeButton.target = self
        rasterizeButton.action = #selector(confirmRasterize(_:))
        backButton.setAccessibilityLabel("Back")
        backButton.target = self
        backButton.action = #selector(back(_:))
        consentCancelButton.setAccessibilityLabel("Cancel")
        consentCancelButton.target = self
        consentCancelButton.action = #selector(cancel(_:))
        let consentButtons = NSStackView(views: [rasterizeButton, backButton, consentCancelButton])
        consentButtons.orientation = .horizontal
        consentButtons.spacing = 8
        let consentStack = NSStackView(views: [confirmationText, consentButtons])
        consentStack.orientation = .vertical
        consentStack.spacing = 8
        consentStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        confirmationBox.boxType = .separator
        confirmationBox.borderType = .lineBorder
        confirmationBox.title = "Rasterization needed"
        confirmationBox.setAccessibilityLabel("Rasterization confirmation")
        confirmationBox.contentView = consentStack
        confirmationBox.isHidden = true

        let stack = NSStackView(views: [infoLabel, grid, confirmationBox, formButtons, messageLabel])
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
    }

    // MARK: Reload, error and close routing (called by the owning window)

    /// The document's cached state changed: refresh the control gates only
    /// — no engine call happens here.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// A refusal the document reports: show it in the sheet too.
    func showError(_ message: String) {
        guard !isInvalidated else { return }
        refuse(message)
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback or completion may update the
    /// sheet, and no action may queue more work.
    func invalidate() {
        isInvalidated = true
        panel.endEditing(for: nil)
    }

    // MARK: Control state

    private var selectedPalette: EngineSession.IndexedPalette {
        let index = palettePopup.indexOfSelectedItem
        return IndexedFormLogic.paletteChoices.indices.contains(index)
            ? IndexedFormLogic.paletteChoices[index].value : .generated
    }

    private var selectedDither: EngineSession.IndexedDither {
        let index = ditherPopup.indexOfSelectedItem
        return IndexedFormLogic.ditherChoices.indices.contains(index)
            ? IndexedFormLogic.ditherChoices[index].value : .none
    }

    /// The form's controls follow the phase and the cached busy state:
    /// only the editing phase mutates, and only while the document accepts
    /// edits. `removeUnused` is meaningful for Web and Custom only; the
    /// maximum colors field only for Generated; the custom text only for
    /// Custom.
    private func updateControlStates() {
        let canEdit = !isInvalidated && phase == .editing && document.acceptsEdits
        let palette = selectedPalette
        palettePopup.isEnabled = canEdit
        maxColorsField.isEnabled = canEdit && palette == .generated
        maxColorsStepper.isEnabled = canEdit && palette == .generated
        customTextView.isEditable = canEdit && palette == .custom
        removeUnusedBox.isEnabled = canEdit && (palette == .web || palette == .custom)
        ditherPopup.isEnabled = canEdit
        ditherAlphaBox.isEnabled = canEdit
        ditherTextBox.isEnabled = canEdit
        convertButton.isEnabled = canEdit
        cancelButton.isEnabled = !isInvalidated && phase == .editing
        let confirmVisible = phase == .awaitingConsent
        confirmationBox.isHidden = !confirmVisible
        rasterizeButton.isEnabled = confirmVisible && document.acceptsEdits
        backButton.isEnabled = confirmVisible
        consentCancelButton.isEnabled = confirmVisible
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

    private func capturedValues() -> IndexedFormLogic.FormValues {
        IndexedFormLogic.FormValues(
            palette: selectedPalette,
            maxColors: maxColorsField.integerValue,
            removeUnused: removeUnusedBox.state == .on,
            dither: selectedDither,
            ditherAlpha: ditherAlphaBox.state == .on,
            ditherText: ditherTextBox.state == .on,
            customText: customTextView.string)
    }

    // MARK: Actions

    @objc private func paletteChanged(_ sender: NSPopUpButton) {
        guard !isInvalidated, phase == .editing else { return }
        clearMessage()
        updateControlStates()
    }

    @objc private func maxColorsStepped(_ sender: NSStepper) {
        maxColorsField.integerValue = sender.integerValue
    }

    /// Apply: validates the form locally first — invalid input shows an
    /// inline error, mutates nothing and keeps the sheet open — then runs
    /// the captured document's counted exclusive conversion with
    /// `preserveEditable`, always.
    @objc private func apply(_ sender: Any?) {
        guard !isInvalidated, phase == .editing else { return }
        guard document.acceptsEdits else {
            refuse(document.isClosing
                ? ImageDocument.DocumentError.closed.localizedDescription
                : ImageDocument.DocumentError.busy.localizedDescription)
            updateControlStates()
            return
        }
        panel.endEditing(for: nil)
        let values = capturedValues()
        let built = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable)
        guard case .success(let settings) = built else {
            if case .failure(let error) = built { refuse(error.localizedDescription) }
            return
        }
        capturedSettings = settings
        phase = .running
        clearMessage()
        updateControlStates()
        run(settings)
    }

    /// Confirm in the consent region: re-runs the captured validated
    /// settings — only the preservation policy becomes `allowRasterize` —
    /// on the captured document. The controls stay disabled and no Cancel
    /// is offered while the accepted work runs.
    @objc private func confirmRasterize(_ sender: Any?) {
        guard !isInvalidated, phase == .awaitingConsent, let settings = capturedSettings else { return }
        guard document.acceptsEdits else {
            refuse(document.isClosing
                ? ImageDocument.DocumentError.closed.localizedDescription
                : ImageDocument.DocumentError.busy.localizedDescription)
            updateControlStates()
            return
        }
        var rasterizing = settings
        rasterizing.preservation = .allowRasterize
        phase = .running
        clearMessage()
        updateControlStates()
        run(rasterizing)
    }

    /// Back: returns to the form with the validated settings preserved.
    @objc private func back(_ sender: Any?) {
        guard !isInvalidated, phase == .awaitingConsent else { return }
        phase = .editing
        clearMessage()
        updateControlStates()
    }

    /// Cancel: in the form or the consent region nothing has mutated (the
    /// first attempt only ever refuses before mutating), so closing the
    /// sheet changes nothing. While accepted work runs the button is
    /// disabled — no false promise of cancellation.
    @objc private func cancel(_ sender: Any?) {
        guard !isInvalidated, phase != .running else { return }
        hostWindow?.endSheet(panel)
    }

    /// Runs one attempt on the captured document and handles its
    /// exactly-once completion: success closes the sheet; a rasterization
    /// refusal opens the inline consent region; every other error stays
    /// visible and returns to the form.
    private func run(_ settings: EngineSession.IndexedSettings) {
        let owner = document
        owner.convertToIndexed(settings: settings) { [weak self] result in
            // The document delivers exactly one completion per attempt;
            // record it even after invalidation, but touch no UI then.
            self?.lastResult = result
            guard let self, !self.isInvalidated else { return }
            switch result {
            case .success:
                self.hostWindow?.endSheet(self.panel)
            case .failure(let error):
                let engineError = error as? EngineSession.EngineError
                if settings.preservation == .preserveEditable, engineError?.requiresRasterization == true {
                    self.phase = .awaitingConsent
                    self.confirmationText.stringValue = "This image holds editable text, vector or linked layers that the indexed conversion would rasterize. "
                        + "Rasterize and Convert applies the conversion in one undo step; undo restores the editable layers."
                    self.clearMessage()
                    self.updateControlStates()
                } else {
                    self.phase = .editing
                    self.refuse(error.localizedDescription)
                    self.updateControlStates()
                }
            }
        }
    }
}
