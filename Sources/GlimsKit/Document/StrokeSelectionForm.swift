import AppKit

/// The pure, UI-free rules behind Edit ▸ Stroke Selection…: strict finite
/// whole-string parsing of the size and opacity fields with inline
/// reasons, and building the stroke's `EngineSession.Brush` by value from
/// the settings captured when the sheet opened plus the sheet's local
/// field values. No windows, no engine — unit tests drive this directly.
enum StrokeSelectionFormValidation {
    /// Why a field's text cannot become a value; the message is shown
    /// inline in the sheet.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The paint tools the sheet offers, in pop-up order.
    static let offeredTools: [ToolID] = [.paintbrush, .pencil, .eraser]

    /// The largest brush size the interface offers (Tool Options' cap).
    static let maximumSize: Double = 500

    /// Parses a finite decimal number from a whole string: empty text,
    /// any embedded whitespace and a numeric prefix before junk all fail
    /// (`Double` already refuses trailing junk), and "nan"/"inf" parse as
    /// doubles, so the finiteness check is what rejects them.
    static func parseFinite(_ text: String) -> Double? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// The facade's brush size guard: finite, above 0 and at most the
    /// interface's maximum, with the reason a field shows inline.
    static func validateSize(_ text: String) -> Result<Double, Rejection> {
        guard let value = parseFinite(text) else {
            return .failure(Rejection(message: "Enter the brush size in pixels — digits with at most one decimal point, no other characters."))
        }
        guard value > 0 else { return .failure(Rejection(message: "The brush size must be above 0 pixels.")) }
        guard value <= maximumSize else { return .failure(Rejection(message: "The brush size must be at most \(Int(maximumSize)) pixels.")) }
        return .success(value)
    }

    /// Opacity as a whole percentage, finite and within 0 ... 100,
    /// returned as the facade's 0 ... 1.
    static func validateOpacity(_ text: String) -> Result<Double, Rejection> {
        guard let value = parseFinite(text) else {
            return .failure(Rejection(message: "Enter the opacity in percent — digits with at most one decimal point, no other characters."))
        }
        guard (0...100).contains(value) else { return .failure(Rejection(message: "The opacity must be from 0 to 100%.")) }
        return .success(value / 100)
    }

    /// The display name of the captured brush resource choice: the
    /// identity's own name, or "Default" for the native default brush
    /// (nil identity). Never a session handle.
    static func brushDisplayName(_ identity: EngineSession.ResourceIdentity?) -> String {
        identity?.name ?? "Default"
    }

    /// Builds the stroke's brush by value: the chosen tool, the captured
    /// resource identity (resolved later on the engine worker — a stale
    /// one fails there, never replaced silently here) and the sheet's
    /// local size, opacity and color. The color must convert to finite
    /// sRGB components in 0 ... 1 — exactly the range the facade accepts.
    static func brush(tool: EngineSession.Brush.Tool,
                      capturedResource: EngineSession.ResourceIdentity?,
                      sizeText: String, opacityText: String, color: NSColor) -> Result<EngineSession.Brush, Rejection> {
        let size: Double
        switch validateSize(sizeText) {
        case .success(let value): size = value
        case .failure(let reason): return .failure(reason)
        }
        let opacity: Double
        switch validateOpacity(opacityText) {
        case .success(let value): opacity = value
        case .failure(let reason): return .failure(reason)
        }
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return .failure(Rejection(message: "The stroke color must be an sRGB color."))
        }
        let components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return .failure(Rejection(message: "The stroke color's components must be finite and within 0 to 1."))
        }
        var brush = EngineSession.Brush()
        brush.tool = tool
        brush.size = size
        brush.opacity = opacity
        brush.red = components[0]
        brush.green = components[1]
        brush.blue = components[2]
        brush.resource = capturedResource
        return .success(brush)
    }
}

/// Edit ▸ Stroke Selection…: this document's sheet. It captures the
/// document and each offered paint tool's brush — resource identity,
/// size, opacity, color — BY VALUE at open, so opening, editing or
/// cancelling the sheet never mutates the global ToolState and a later
/// global change cannot redirect an accepted stroke. The owning window
/// controller retains this controller for the sheet's lifetime and routes
/// reload, error and close feedback through the document's existing
/// callbacks; late callbacks after invalidation do nothing.
///
/// Stroke accepts once (one-shot): it validates the local fields and the
/// cached gates with inline reasons — keeping the sheet open on invalid
/// input — and on success enqueues one counted input job through
/// `ImageDocument.strokeSelection` and closes. Cancel closes with no
/// mutation at all.
@MainActor
final class StrokeSelectionSheetController: NSObject {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    /// Each offered tool's brush captured by value at open; the accept
    /// reads only this snapshot, never the live ToolState.
    private let capturedBrushes: [ToolID: EngineSession.Brush]
    /// Whether the color panel was already visible when the sheet opened;
    /// the sheet then leaves it alone on close.
    private let colorPanelWasVisible: Bool

    private let toolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let brushNameLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider(value: 12, minValue: 1, maxValue: 500, target: nil, action: nil)
    private let sizeField = NSTextField(string: "12")
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityField = NSTextField(string: "100")
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let strokeButton = NSButton(title: "Stroke", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")

    /// Set on close; late reload/error callbacks then do nothing.
    private var isInvalidated = false
    /// Set before any accept work that can call back into the UI — ending
    /// field edits, ending pending input — so a duplicate or reentrant
    /// acceptance is blocked before it can mutate anything. Once an
    /// accept enqueued its job the flag stays set: the sheet closes.
    private var isAccepting = false
    /// The last validation or refusal reason shown inline.
    private(set) var lastError: String?

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        let state = ToolState.shared
        let initialTool: ToolID = state.current.paintTool != nil ? state.current : .paintbrush
        self.capturedBrushes = Dictionary(uniqueKeysWithValues:
            StrokeSelectionFormValidation.offeredTools.map { ($0, state.brush(for: $0)) })
        self.colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Stroke Selection"
        buildContent(initialTool: initialTool)
        updateControlStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var selectedTool: ToolID {
        StrokeSelectionFormValidation.offeredTools[min(toolPopup.indexOfSelectedItem,
                                                       StrokeSelectionFormValidation.offeredTools.count - 1)]
    }

    /// The captured brush identity's display name for `tool`, with the
    /// chooser's verified "Missing:" marker when it no longer resolves —
    /// shown, never silently replaced by the default.
    private func brushLabelText(for tool: ToolID) -> String {
        let identity = capturedBrushes[tool]?.resource
        if let missing = BrushChooser.shared.missingIdentity(for: tool, choice: identity) {
            return "Missing: \(missing.name)"
        }
        return StrokeSelectionFormValidation.brushDisplayName(identity)
    }

    private func buildContent(initialTool: ToolID) {
        toolPopup.addItems(withTitles: StrokeSelectionFormValidation.offeredTools.map(\.name))
        toolPopup.controlSize = .small
        toolPopup.setAccessibilityLabel("Stroke paint tool")
        toolPopup.selectItem(at: StrokeSelectionFormValidation.offeredTools.firstIndex(of: initialTool) ?? 0)
        brushNameLabel.setAccessibilityLabel("Captured brush name")
        brushNameLabel.font = .systemFont(ofSize: 11)
        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.setAccessibilityLabel("Stroke size slider")
        sizeSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        sizeField.setAccessibilityLabel("Stroke size, pixels")
        sizeField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.setAccessibilityLabel("Stroke opacity slider")
        opacitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        opacityField.setAccessibilityLabel("Stroke opacity, percent")
        opacityField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        colorWell.setAccessibilityLabel("Stroke color")
        strokeButton.setAccessibilityLabel("Stroke selection")
        strokeButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel stroke selection")
        messageLabel.setAccessibilityLabel("Stroke selection message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        toolPopup.target = self
        toolPopup.action = #selector(toolChanged(_:))
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged(_:))
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged(_:))
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))
        opacityField.target = self
        opacityField.action = #selector(opacityFieldChanged(_:))
        strokeButton.target = self
        strokeButton.action = #selector(stroke(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        // Seed the local fields from the captured values by value.
        synchronizeFields(with: capturedBrushes[initialTool] ?? EngineSession.Brush())

        let sizeStack = NSStackView(views: [sizeSlider, sizeField])
        sizeStack.orientation = .horizontal
        sizeStack.spacing = 8
        sizeStack.alignment = .centerY
        let opacityStack = NSStackView(views: [opacitySlider, opacityField])
        opacityStack.orientation = .horizontal
        opacityStack.spacing = 8
        opacityStack.alignment = .centerY
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Tool:"), toolPopup],
            [NSTextField(labelWithString: "Brush:"), brushNameLabel],
            [NSTextField(labelWithString: "Size (px):"), sizeStack],
            [NSTextField(labelWithString: "Opacity (%):"), opacityStack],
            [NSTextField(labelWithString: "Color:"), colorWell],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let buttonRow = NSStackView(views: [strokeButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [grid, buttonRow, messageLabel])
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
        panel.initialFirstResponder = toolPopup
    }

    // MARK: Control state

    /// Reseeds the local fields from the captured brush of `tool`; a pure
    /// read of the open-time snapshot, never a ToolState write.
    private func synchronizeFields(with brush: EngineSession.Brush) {
        brushNameLabel.stringValue = brushLabelText(for: selectedTool)
        sizeSlider.doubleValue = min(max(brush.size, sizeSlider.minValue), sizeSlider.maxValue)
        sizeField.stringValue = String(format: "%.1f", brush.size)
        opacitySlider.doubleValue = brush.opacity * 100
        opacityField.stringValue = String(Int((brush.opacity * 100).rounded()))
        if let rgb = brush.sRGBColor { colorWell.color = rgb }
    }

    private func updateControlStates() {
        // Cached busy/closing state only — no native call here.
        strokeButton.isEnabled = !isInvalidated && document.acceptsEdits
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

    // MARK: Reload, error and close routing (called by the owning window)

    /// The document's cached state changed: refresh the cached-gate
    /// enablement only.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the sheet too.
    func showError(_ message: String) {
        guard !isInvalidated else { return }
        refuse(message)
    }

    /// Commits an in-flight field edit (the window's endPendingEdits).
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update or reopen the sheet,
    /// and the sheet's own color panel activation is released.
    func invalidate() {
        isInvalidated = true
        panel.endEditing(for: nil)
        if colorWell.isActive && !colorPanelWasVisible { NSColorPanel.shared.orderOut(nil) }
        colorWell.deactivate()
    }

    // MARK: Actions

    @objc private func toolChanged(_ sender: NSPopUpButton) {
        guard !isInvalidated, let brush = capturedBrushes[selectedTool] else { return }
        clearMessage()
        synchronizeFields(with: brush)
    }

    @objc private func sizeSliderChanged(_ sender: NSSlider) {
        sizeField.stringValue = String(format: "%.1f", sender.doubleValue)
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        guard let value = StrokeSelectionFormValidation.parseFinite(sender.stringValue) else { return }
        sizeSlider.doubleValue = min(max(value, sizeSlider.minValue), sizeSlider.maxValue)
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        opacityField.stringValue = String(Int(sender.doubleValue.rounded()))
    }

    @objc private func opacityFieldChanged(_ sender: NSTextField) {
        guard let value = StrokeSelectionFormValidation.parseFinite(sender.stringValue) else { return }
        opacitySlider.doubleValue = min(max(value, opacitySlider.minValue), opacitySlider.maxValue)
    }

    /// Stroke: one-shot accept. The reentry flag goes up before anything
    /// that can call back into the UI (ending field edits, ending pending
    /// input), so a duplicate or reentrant accept is blocked first. Local
    /// field validation and the cached gates keep the sheet open with an
    /// inline reason; a valid accept enqueues exactly one counted input
    /// job on the owning document and closes the sheet.
    @objc private func stroke(_ sender: Any?) {
        guard !isInvalidated, !isAccepting else { return }
        isAccepting = true
        panel.endEditing(for: nil)
        let owner = document
        if let reason = owner.strokeSelectionRefusal {
            refuse(reason)
            isAccepting = false
            return
        }
        let tool = selectedTool
        let paintTool = tool.paintTool ?? .paintbrush
        let result = StrokeSelectionFormValidation.brush(
            tool: paintTool,
            capturedResource: capturedBrushes[tool]?.resource,
            sizeText: sizeField.stringValue,
            opacityText: opacityField.stringValue,
            color: colorWell.color)
        switch result {
        case .failure(let reason):
            refuse(reason.message)
            NSSound.beep()
            isAccepting = false
        case .success(let brush):
            clearMessage()
            // Counted input on the document's input queue, off the main
            // thread; native errors come back through the document's
            // onError path. The sheet closes after this one accepted
            // enqueue (one-shot semantics).
            owner.strokeSelection(brush)
            hostWindow?.endSheet(panel)
        }
    }

    /// Cancel: closes the sheet; nothing is enqueued or mutated.
    @objc private func cancel(_ sender: Any?) {
        guard !isInvalidated else { return }
        hostWindow?.endSheet(panel)
    }
}

private extension EngineSession.Brush {
    /// The captured color as an sRGB NSColor, for seeding the color well.
    var sRGBColor: NSColor? {
        guard red.isFinite, green.isFinite, blue.isFinite,
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue) else { return nil }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
