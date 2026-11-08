import AppKit
import CGlimsEngine

/// The pure rules behind the Vector Style sheet: the number and color
/// guards that mirror the facade's own checks, and the change a set of
/// control values makes against the style the sheet captured. No windows,
/// no engine — unit tests drive this directly.
enum VectorStyleFormValidation {

    /// Why a control set cannot become a change.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// The raw control values of one sheet.
    struct Values: Equatable {
        var fillEnabled: Bool
        var fillColor: NSColor
        var fillAntialias: Bool
        var strokeEnabled: Bool
        var strokeColor: NSColor
        var strokeAntialias: Bool
        var strokeWidthText: String
        var strokeCap: EngineSession.VectorCapStyle
        var strokeJoin: EngineSession.VectorJoinStyle
        var strokeMiterText: String
    }

    /// Parses a finite decimal number from a text field; nil for empty
    /// text, junk, NaN and infinity ("nan" and "inf" parse as doubles, so
    /// the finiteness check is what rejects them).
    static func finiteNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// The facade's stroke width guard: finite, above 0 and at most 2000
    /// image pixels.
    static func validStrokeWidth(_ width: Double) -> Bool {
        width.isFinite && width > 0 && width <= 2000
    }

    /// The facade's miter limit guard: finite, 0 ... 100.
    static func validMiterLimit(_ limit: Double) -> Bool {
        limit.isFinite && limit >= 0 && limit <= 100
    }

    /// The facade's color component guard: finite, 0 ... 1.
    static func validColorComponent(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }

    /// The sRGB components of `color`, nil when any is not finite or
    /// outside 0 ... 1 — exactly the range the facade accepts for a style
    /// color.
    static func colorComponents(_ color: NSColor)
        -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [Double(rgb.redComponent), Double(rgb.greenComponent),
                          Double(rgb.blueComponent), Double(rgb.alphaComponent)]
        guard components.allSatisfy(validColorComponent) else { return nil }
        return (components[0], components[1], components[2], components[3])
    }

    /// Builds the change `values` make against `captured`, the style the
    /// sheet read when it opened. Only an enabled section's fields are
    /// read, validated and flagged — a disabled section's controls may
    /// hold anything and are neither validated nor sent, so the engine
    /// keeps its own state for them. A field whose value equals the
    /// captured one is not flagged; empty `properties` is the no-op.
    /// Opacity, paint mode, dashes and patterns are not part of the native
    /// style and never appear here.
    static func change(from captured: EngineSession.VectorStyle,
                       _ values: Values) -> Result<EngineSession.VectorStyleChange, Rejection> {
        var change = EngineSession.VectorStyleChange()
        var flags: EngineSession.VectorStyleProperty = []

        if values.fillEnabled {
            guard let fill = colorComponents(values.fillColor) else {
                return .failure(Rejection(message: "The fill color must have finite sRGB components from 0 to 1."))
            }
            change.fillEnabled = true
            change.fillColor = values.fillColor
            change.fillAntialias = values.fillAntialias
            if !captured.fillEnabled { flags.insert(.enableFill) }
            if let capturedFill = colorComponents(captured.fillColor), !sameColor(fill, capturedFill) {
                flags.insert(.fillColor)
            } else if colorComponents(captured.fillColor) == nil {
                flags.insert(.fillColor)
            }
            if captured.fillAntialias != values.fillAntialias { flags.insert(.fillAntialias) }
        } else if captured.fillEnabled {
            change.fillEnabled = false
            flags.insert(.enableFill)
        }

        if values.strokeEnabled {
            guard let stroke = colorComponents(values.strokeColor) else {
                return .failure(Rejection(message: "The stroke color must have finite sRGB components from 0 to 1."))
            }
            guard let width = finiteNumber(values.strokeWidthText), validStrokeWidth(width) else {
                return .failure(Rejection(message: "Enter a stroke width above 0 and at most 2000 pixels."))
            }
            guard let miter = finiteNumber(values.strokeMiterText), validMiterLimit(miter) else {
                return .failure(Rejection(message: "Enter a miter limit from 0 to 100."))
            }
            change.strokeEnabled = true
            change.strokeColor = values.strokeColor
            change.strokeAntialias = values.strokeAntialias
            change.strokeWidth = width
            change.strokeCap = values.strokeCap
            change.strokeJoin = values.strokeJoin
            change.strokeMiterLimit = miter
            if !captured.strokeEnabled { flags.insert(.enableStroke) }
            if let capturedStroke = colorComponents(captured.strokeColor), !sameColor(stroke, capturedStroke) {
                flags.insert(.strokeColor)
            } else if colorComponents(captured.strokeColor) == nil {
                flags.insert(.strokeColor)
            }
            if captured.strokeAntialias != values.strokeAntialias { flags.insert(.strokeAntialias) }
            if captured.strokeWidth != width { flags.insert(.strokeWidth) }
            if captured.strokeCap != values.strokeCap { flags.insert(.strokeCap) }
            if captured.strokeJoin != values.strokeJoin { flags.insert(.strokeJoin) }
            if captured.strokeMiterLimit != miter { flags.insert(.strokeMiter) }
        } else if captured.strokeEnabled {
            change.strokeEnabled = false
            flags.insert(.enableStroke)
        }

        change.properties = flags
        return .success(change)
    }

    private static func sameColor(
        _ a: (red: Double, green: Double, blue: Double, alpha: Double),
        _ b: (red: Double, green: Double, blue: Double, alpha: Double)) -> Bool {
        abs(a.red - b.red) < 1e-6 && abs(a.green - b.green) < 1e-6
            && abs(a.blue - b.blue) < 1e-6 && abs(a.alpha - b.alpha) < 1e-6
    }
}

/// The native Layer ▸ Vector Style… sheet: the fill and stroke of a
/// selected genuine vector layer — enable, solid color and antialias for
/// each, plus width, cap, join and miter limit for the stroke. One sheet
/// captures one document, one layer id and the style it read; nothing is
/// shared between sheets and no retarget can redirect an apply. The style
/// read runs off the main thread through the global engine activity after
/// accepted input drains; the getter is never called on the main thread.
@MainActor
enum VectorStyleForm {

    static func present(in document: ImageDocument, layer: Int32, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil else {
            if !document.acceptsEdits {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
            }
            return
        }
        // Cached-state gates only — the engine is never asked here: the
        // layer must be a genuine vector layer in the last reload's list,
        // and the engine known to have native vector styles (GIMP 3.2+).
        // An unknown version stays admitted and the facade's own
        // UNSUPPORTED reports the rest. No raster fallback, ever.
        guard document.layers.contains(where: { $0.id == layer && $0.kind == .vector }),
              document.supportsVectorLayers != false else { return }

        let fillEnabled = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
        fillEnabled.setAccessibilityLabel("Fill the path")
        let fillColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        fillColor.setAccessibilityLabel("Fill color")
        let fillAntialias = NSButton(checkboxWithTitle: "Antialias", target: nil, action: nil)
        fillAntialias.setAccessibilityLabel("Antialias the fill edge")

        let strokeEnabled = NSButton(checkboxWithTitle: "Stroke", target: nil, action: nil)
        strokeEnabled.setAccessibilityLabel("Stroke the path")
        let strokeColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        strokeColor.setAccessibilityLabel("Stroke color")
        let strokeAntialias = NSButton(checkboxWithTitle: "Antialias", target: nil, action: nil)
        strokeAntialias.setAccessibilityLabel("Antialias the stroke edge")
        let strokeWidth = NSTextField(string: "")
        strokeWidth.setAccessibilityLabel("Stroke width, pixels")
        strokeWidth.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let strokeMiter = NSTextField(string: "")
        strokeMiter.setAccessibilityLabel("Miter limit")
        strokeMiter.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let strokeCap = NSPopUpButton(frame: .zero, pullsDown: false)
        strokeCap.addItems(withTitles: EngineSession.VectorCapStyle.allCases.map(\.name))
        strokeCap.setAccessibilityLabel("Stroke cap")
        strokeCap.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let strokeJoin = NSPopUpButton(frame: .zero, pullsDown: false)
        strokeJoin.addItems(withTitles: EngineSession.VectorJoinStyle.allCases.map(\.name))
        strokeJoin.setAccessibilityLabel("Stroke join")
        strokeJoin.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let state = VectorStyleFormState(fillEnabled: fillEnabled, fillColor: fillColor,
                                         fillAntialias: fillAntialias,
                                         strokeEnabled: strokeEnabled, strokeColor: strokeColor,
                                         strokeAntialias: strokeAntialias, strokeWidth: strokeWidth,
                                         strokeCap: strokeCap, strokeJoin: strokeJoin,
                                         strokeMiter: strokeMiter)
        fillEnabled.target = state
        fillEnabled.action = #selector(VectorStyleFormState.sectionToggled(_:))
        strokeEnabled.target = state
        strokeEnabled.action = #selector(VectorStyleFormState.sectionToggled(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Fill:"), fillEnabled, fillColor, fillAntialias],
            [NSTextField(labelWithString: "Stroke:"), strokeEnabled, strokeColor, strokeAntialias],
            [NSTextField(labelWithString: "Width (px):"), strokeWidth,
             NSTextField(labelWithString: "Miter limit:"), strokeMiter],
            [NSTextField(labelWithString: "Cap:"), strokeCap,
             NSTextField(labelWithString: "Join:"), strokeJoin],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Vector Style"
        alert.informativeText = "Change the selected vector layer’s fill and outline. You can undo the change."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        state.applyButton = alert.buttons.first
        // Until the off-main read lands there is no captured style, so
        // Apply stays disabled and cannot send a half-seeded change.
        alert.buttons.first?.isEnabled = false
        alert.window.initialFirstResponder = fillEnabled
        let sheetWindow = alert.window
        let colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible

        // The one engine call of the sheet: a small read, but never on the
        // main thread — the engine may be busy. The global activity admits
        // it after every document's accepted input has drained.
        let session = document.session
        let image = document.image
        alert.beginSheetModal(for: window) { [state] response in
            sheetWindow.endEditing(for: nil)
            // Color panel cleanup, only for this sheet's own activation: a
            // panel that was already visible when the sheet opened stays.
            let ownActivation = state.fillColor?.isActive == true || state.strokeColor?.isActive == true
            if ownActivation && !colorPanelWasVisible { NSColorPanel.shared.orderOut(nil) }
            state.fillColor?.deactivate()
            state.strokeColor?.deactivate()
            guard response == .alertFirstButtonReturn else { return }
            guard document.acceptsEdits else {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            // Target guard: the captured layer must still be a genuine
            // vector layer of this document — deleted or rasterized meanwhile
            // is refused, never applied to whatever replaced it.
            guard document.layers.contains(where: { $0.id == layer && $0.kind == .vector }) else {
                document.onError?(ImageDocument.DocumentError.targetChanged.localizedDescription)
                return
            }
            guard let captured = state.captured else { return }
            switch VectorStyleFormValidation.change(from: captured, state.values()) {
            case .failure(let rejection):
                document.onError?(rejection.message)
            case .success(let change):
                // An empty `properties` is a no-op: the document queues
                // nothing and no undo is pushed.
                document.changeVectorLayerStyle(layer, change)
            }
        }

        EngineActivity.shared.performWhenReady(label: "Reading the vector layer's style") {
            let result = Result { try session.vectorLayerStyle(layer, image: image) }
            DispatchQueue.main.async {
                Self.readDidFinish(result, document: document, layer: layer,
                                   window: window, sheet: sheetWindow, state: state)
            }
        }
    }

    /// The off-main read landed. Window guard: the sheet must still be this
    /// window's attached sheet; close guard: a closing document's answer is
    /// dropped; target guard: the captured layer must still be a cached
    /// genuine vector layer. A pattern style or a pre-3.2 engine reports
    /// UNSUPPORTED and the sheet closes with the reason.
    private static func readDidFinish(_ result: Result<EngineSession.VectorStyle, Error>,
                                      document: ImageDocument, layer: Int32, window: NSWindow,
                                      sheet: NSWindow, state: VectorStyleFormState) {
        guard window.attachedSheet === sheet, !document.isClosing else { return }
        switch result {
        case .success(let style):
            guard document.layers.contains(where: { $0.id == layer && $0.kind == .vector }) else {
                document.onError?(ImageDocument.DocumentError.targetChanged.localizedDescription)
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                return
            }
            state.seed(style)
        case .failure(let error):
            document.onError?(readErrorMessage(error))
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
    }

    private static func readErrorMessage(_ error: Error) -> String {
        if let engineError = error as? EngineSession.EngineError,
           engineError.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) {
            return "This vector layer uses an unsupported fill or outline."
        }
        return String(describing: error)
    }
}

/// One sheet's controls and captured style, retained by the sheet's own
/// completion — never shared, never retargeted.
@MainActor
private final class VectorStyleFormState: NSObject {
    weak var fillEnabled: NSButton?
    weak var fillColor: NSColorWell?
    weak var fillAntialias: NSButton?
    weak var strokeEnabled: NSButton?
    weak var strokeColor: NSColorWell?
    weak var strokeAntialias: NSButton?
    weak var strokeWidth: NSTextField?
    weak var strokeCap: NSPopUpButton?
    weak var strokeJoin: NSPopUpButton?
    weak var strokeMiter: NSTextField?
    weak var applyButton: NSButton?
    /// The style the sheet read, captured per sheet.
    var captured: EngineSession.VectorStyle?

    init(fillEnabled: NSButton, fillColor: NSColorWell, fillAntialias: NSButton,
         strokeEnabled: NSButton, strokeColor: NSColorWell, strokeAntialias: NSButton,
         strokeWidth: NSTextField, strokeCap: NSPopUpButton, strokeJoin: NSPopUpButton,
         strokeMiter: NSTextField) {
        self.fillEnabled = fillEnabled
        self.fillColor = fillColor
        self.fillAntialias = fillAntialias
        self.strokeEnabled = strokeEnabled
        self.strokeColor = strokeColor
        self.strokeAntialias = strokeAntialias
        self.strokeWidth = strokeWidth
        self.strokeCap = strokeCap
        self.strokeJoin = strokeJoin
        self.strokeMiter = strokeMiter
        super.init()
    }

    @objc func sectionToggled(_ sender: NSButton) {
        updateEnablement()
    }

    /// A disabled section's controls are disabled too, so its stale values
    /// are visibly inert — and the validation never reads them.
    private func updateEnablement() {
        let fill = fillEnabled?.state == .on
        fillColor?.isEnabled = fill
        fillAntialias?.isEnabled = fill
        let stroke = strokeEnabled?.state == .on
        strokeColor?.isEnabled = stroke
        strokeAntialias?.isEnabled = stroke
        strokeWidth?.isEnabled = stroke
        strokeCap?.isEnabled = stroke
        strokeJoin?.isEnabled = stroke
        strokeMiter?.isEnabled = stroke
    }

    func seed(_ style: EngineSession.VectorStyle) {
        captured = style
        fillEnabled?.state = style.fillEnabled ? .on : .off
        fillColor?.color = style.fillColor
        fillAntialias?.state = style.fillAntialias ? .on : .off
        strokeEnabled?.state = style.strokeEnabled ? .on : .off
        strokeColor?.color = style.strokeColor
        strokeAntialias?.state = style.strokeAntialias ? .on : .off
        strokeWidth?.stringValue = "\(style.strokeWidth)"
        if let index = EngineSession.VectorCapStyle.allCases.firstIndex(of: style.strokeCap) {
            strokeCap?.selectItem(at: index)
        }
        if let index = EngineSession.VectorJoinStyle.allCases.firstIndex(of: style.strokeJoin) {
            strokeJoin?.selectItem(at: index)
        }
        strokeMiter?.stringValue = "\(style.strokeMiterLimit)"
        updateEnablement()
        applyButton?.isEnabled = true
    }

    func values() -> VectorStyleFormValidation.Values {
        let caps = EngineSession.VectorCapStyle.allCases
        let joins = EngineSession.VectorJoinStyle.allCases
        let capIndex = strokeCap?.indexOfSelectedItem ?? 0
        let joinIndex = strokeJoin?.indexOfSelectedItem ?? 0
        return VectorStyleFormValidation.Values(
            fillEnabled: fillEnabled?.state == .on,
            fillColor: fillColor?.color ?? .black,
            fillAntialias: fillAntialias?.state == .on,
            strokeEnabled: strokeEnabled?.state == .on,
            strokeColor: strokeColor?.color ?? .black,
            strokeAntialias: strokeAntialias?.state == .on,
            strokeWidthText: strokeWidth?.stringValue ?? "",
            strokeCap: caps.indices.contains(capIndex) ? caps[capIndex] : .butt,
            strokeJoin: joins.indices.contains(joinIndex) ? joins[joinIndex] : .miter,
            strokeMiterText: strokeMiter?.stringValue ?? "")
    }
}
