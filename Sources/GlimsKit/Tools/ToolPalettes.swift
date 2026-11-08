import AppKit
import RigiUI

/// The Tools palette: the tool grid and the foreground/background color pair.
@MainActor
final class ToolsPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    private enum Metrics {
        static let margin: CGFloat = 6
        static let gridToColors: CGFloat = 8
    }

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.tools"),
        title: "Tools",
        contentSize: NSSize(
            width: 61,
            height: Metrics.margin + ClassicToolGridLayout().size(forSlotCount: ToolID.paletteSlots.count).height
                + Metrics.gridToColors + ClassicColorPairLayout.size.height + Metrics.margin),
        sizing: .fixed,
        frameAutosaveName: "Glims.palette.tools")

    private let grid = ClassicToolGrid(slots: ToolID.paletteSlots.map { group in
        ClassicToolGrid.Slot(tools: group.map {
            ClassicToolGrid.Tool(id: $0.rawValue, name: $0.name, shortcut: $0.shortcut, image: $0.image)
        })
    })
    private let colors = ClassicColorPair()
    /// Which color the shared color panel is editing for this palette.
    private var editedColor: ReferenceWritableKeyPath<ToolState, NSColor>?
    private var observer: UUID?

    override func loadView() {
        let root = NSView()
        grid.target = self
        grid.action = #selector(toolChosen(_:))
        grid.setAccessibilityLabel("Tools")
        colors.swapShortcut = "X"
        colors.resetShortcut = "D"
        colors.onSwap = { ToolState.shared.swapColors() }
        colors.onReset = { ToolState.shared.resetColors() }
        colors.onEditForeground = { [weak self] in self?.editColor(\.foreground) }
        colors.onEditBackground = { [weak self] in self?.editColor(\.background) }

        for view in [grid, colors] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.margin),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            colors.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Metrics.gridToColors),
            colors.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
        view = root
        grid.selectTool(id: ToolState.shared.current.rawValue)
        stateChanged()
        observer = ToolState.shared.observe { [weak self] in self?.stateChanged() }
    }

    func retarget(to target: ImageDocument?) {}

    private func stateChanged() {
        if grid.selectedToolID != ToolState.shared.current.rawValue {
            grid.selectTool(id: ToolState.shared.current.rawValue)
        }
        if colors.foreground != ToolState.shared.foreground {
            colors.foreground = ToolState.shared.foreground
        }
        if colors.background != ToolState.shared.background {
            colors.background = ToolState.shared.background
        }
    }

    @objc private func toolChosen(_ sender: ClassicToolGrid) {
        guard let id = sender.selectedToolID, let tool = ToolID(rawValue: id) else { return }
        ToolState.shared.select(tool)
    }

    /// Opens the shared color panel on one of the two colors; its changes
    /// go straight to `ToolState`.
    private func editColor(_ keyPath: ReferenceWritableKeyPath<ToolState, NSColor>) {
        editedColor = keyPath
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = ToolState.shared[keyPath: keyPath]
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let keyPath = editedColor else { return }
        ToolState.shared[keyPath: keyPath] = sender.color
        ToolState.shared.notifyChange()
    }
}

/// The Tool Options palette: the current tool's settings. Its rows are
/// rebuilt when the tool changes; every change goes to `ToolState`.
@MainActor
final class ToolOptionsPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.toolOptions"),
        title: "Tool Options",
        contentSize: NSSize(width: 250, height: 190),
        sizing: .resizable(minimumContentSize: NSSize(width: 220, height: 120)),
        frameAutosaveName: "Glims.palette.toolOptions")

    private let stack = NSStackView()
    private var shownTool: ToolID?
    private var shownFontCount = 0
    private var shownBrushResource: EngineSession.ResourceIdentity?
    private var shownMissingBrush: EngineSession.ResourceIdentity?
    private var shownBrushPresentationRevision = 0
    private var shownGradient: GradientPresentation?
    private var observer: UUID?
    /// The front document, retained (weakly) as the resource choosers'
    /// session and loading source.
    private weak var document: ImageDocument?

    /// Everything the gradient rows show, so a change rebuilds them.
    private struct GradientPresentation: Equatable {
        let resource: EngineSession.ResourceIdentity?
        let missing: EngineSession.ResourceIdentity?
        let revision: Int
        let shape: EngineSession.GradientShape
        let reverse: Bool
        let blendSpace: EngineSession.GradientBlendSpace
        let opacity: Double
    }

    private static func gradientPresentation(of state: ToolState) -> GradientPresentation {
        GradientPresentation(resource: state.gradientResource,
                             missing: GradientChooser.shared.missingIdentity(choice: state.gradientResource),
                             revision: GradientChooser.shared.presentationRevision,
                             shape: state.gradientShape, reverse: state.gradientReverse,
                             blendSpace: state.gradientBlendSpace, opacity: state.gradientOpacity)
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        view = stack
        rebuild()
        observer = ToolState.shared.observe { [weak self] in
            guard let self else { return }
            let state = ToolState.shared
            let fontsArrived = self.shownTool == .text && self.shownFontCount != state.fontNames.count
            let brushChanged = state.current.paintTool != nil
                && (self.shownBrushResource != state.brush(for: state.current).resource
                    || self.shownBrushPresentationRevision != BrushChooser.shared.presentationRevision
                    || self.shownMissingBrush != BrushChooser.shared.missingIdentity(
                        for: state.current, choice: state.brush(for: state.current).resource))
            let gradientChanged = state.current == .gradient
                && self.shownGradient != Self.gradientPresentation(of: state)
            guard self.shownTool != state.current || fontsArrived || brushChanged || gradientChanged else { return }
            self.rebuild()
        }
    }

    func retarget(to target: ImageDocument?) {
        // A different (or closing) document invalidates an open chooser, so
        // its late native results cannot restore a stale sheet.
        if target !== document {
            document = target
            if BrushChooser.shared.isOpen { BrushChooser.shared.close() }
            if GradientChooser.shared.isOpen { GradientChooser.shared.close() }
        }
    }

    func paletteDidDismiss(_ presentation: PalettePresentation) {
        if BrushChooser.shared.isOpen { BrushChooser.shared.close() }
        if GradientChooser.shared.isOpen { GradientChooser.shared.close() }
    }

    private func rebuild() {
        let state = ToolState.shared
        let tool = state.current
        shownTool = tool
        shownFontCount = state.fontNames.count
        shownBrushResource = tool.paintTool != nil ? state.brush(for: tool).resource : nil
        shownMissingBrush = BrushChooser.shared.missingIdentity(for: tool, choice: shownBrushResource)
        shownBrushPresentationRevision = BrushChooser.shared.presentationRevision
        shownGradient = tool == .gradient ? Self.gradientPresentation(of: state) : nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionBindings.removeAll()

        let title = NSTextField(labelWithString: tool.name)
        title.font = .boldSystemFont(ofSize: 11)
        stack.addArrangedSubview(title)

        if tool.paintTool != nil {
            addPaintRows(for: tool, brush: state.brush(for: tool))
        } else if tool.isSelectionTool {
            addSelectionRows(for: tool)
        } else if tool == .gradient {
            addGradientRows(state)
        } else if tool == .text {
            addTextRows(state.textSettings)
        } else if tool == .transform {
            let methods = EngineSession.Interpolation.allCases
            stack.addArrangedSubview(popUp("Resample", methods.map(\.name),
                                           selected: methods.firstIndex(of: state.transformInterpolation) ?? 2) { index in
                ToolState.shared.transformInterpolation = methods[index]
            })
            stack.addArrangedSubview(hint("Drag a corner or edge to scale (Shift keeps the proportions), "
                + "inside to move, outside to rotate (Shift: 15° steps). Return applies; Escape cancels."))
        } else if tool == .path {
            stack.addArrangedSubview(slider("Stroke", 1...200, state.pathLineWidth, unit: "px", fractionDigits: 1) { value in
                ToolState.shared.pathLineWidth = value
            })
            stack.addArrangedSubview(slider("Fill opacity", 0...100, state.pathFillOpacity * 100, unit: "%") { value in
                ToolState.shared.pathFillOpacity = value / 100
            })
            stack.addArrangedSubview(checkbox("Antialias fill", state.pathFillAntialias) { on in
                ToolState.shared.pathFillAntialias = on
            })
            stack.addArrangedSubview(hint("Click to add corners, drag for curves; click the first anchor to "
                + "close. Drag anchors and handles to reshape (Option-drag an anchor pulls out handles). "
                + "Shift-click starts a new subpath; Return ends one; Delete removes the selected anchor."))
        } else if tool == .bucketFill {
            stack.addArrangedSubview(popUp("Fill", ["Similar colors", "Whole selection"],
                                           selected: state.fillMode == .similarColors ? 0 : 1) { index in
                ToolState.shared.fillMode = index == 0 ? .similarColors : .selection
            })
            stack.addArrangedSubview(slider("Threshold", 0...255, state.fillThreshold * 255, unit: "") { value in
                ToolState.shared.fillThreshold = value / 255
            })
            stack.addArrangedSubview(checkbox("Sample merged", state.fillSampleMerged) { on in
                ToolState.shared.fillSampleMerged = on
            })
        } else {
            let hints: [ToolID: String] = [
                .move: "Drag to move the selected layer. Arrow keys nudge it 1 pixel, Shift-arrow 10.",
                .crop: "Drag the area to keep, then press Return to crop or Escape to cancel.",
                .eyedropper: "Click the image to pick the foreground color.",
                .hand: "Drag to scroll. Hold Space with any tool for the hand.",
                .zoom: "Click to zoom in; Option-click to zoom out.",
            ]
            stack.addArrangedSubview(hint(hints[tool] ?? ""))
        }
    }

    // MARK: Rows

    /// The next text's look. The text takes the foreground color; Return
    /// starts a new line and Escape applies, in the canvas editor.
    private func addTextRows(_ settings: EngineSession.TextSettings) {
        let fonts = ToolState.shared.fontNames
        if fonts.isEmpty {
            stack.addArrangedSubview(hint("Loading the engine's fonts…"))
        } else {
            stack.addArrangedSubview(popUp("Font", fonts, selected: fonts.firstIndex(of: settings.font) ?? 0) { index in
                ToolState.shared.textSettings.font = fonts[index]
            })
        }
        stack.addArrangedSubview(slider("Size", 1...1000, settings.size, unit: "px", fractionDigits: 1) { value in
            ToolState.shared.textSettings.size = value
        })
        let alignments = EngineSession.TextSettings.Justify.allCases
        stack.addArrangedSubview(popUp("Align", alignments.map(\.name),
                                       selected: alignments.firstIndex(of: settings.justify) ?? 0) { index in
            ToolState.shared.textSettings.justify = alignments[index]
        })
        stack.addArrangedSubview(slider("Lines", -100...200, settings.lineSpacing, unit: "px", fractionDigits: 1) { value in
            ToolState.shared.textSettings.lineSpacing = value
        })
        stack.addArrangedSubview(slider("Letters", -50...100, settings.letterSpacing, unit: "px", fractionDigits: 1) { value in
            ToolState.shared.textSettings.letterSpacing = value
        })
        stack.addArrangedSubview(checkbox("Antialias", settings.antialias) { on in
            ToolState.shared.textSettings.antialias = on
        })
        stack.addArrangedSubview(hint("Click the image to type new text in the foreground color, or a text "
            + "layer to edit it. Escape or a click outside applies."))
    }

    private func addPaintRows(for tool: ToolID, brush: EngineSession.Brush) {
        stack.addArrangedSubview(brushRow(for: tool, brush: brush))
        stack.addArrangedSubview(slider("Size", 1...500, brush.size, unit: "px", fractionDigits: 1) { value in
            ToolState.shared.update(tool) { $0.size = value }
        })
        stack.addArrangedSubview(slider("Opacity", 0...100, brush.opacity * 100, unit: "%") { value in
            ToolState.shared.update(tool) { $0.opacity = value / 100 }
        })
        stack.addArrangedSubview(slider("Hardness", 0...100, (brush.hardness ?? 0.5) * 100, unit: "%") { value in
            ToolState.shared.update(tool) { $0.hardness = value / 100 }
        })

        switch tool {
        case .airbrush, .smudge:
            stack.addArrangedSubview(slider("Rate", 0...100, brush.rate ?? 50, unit: "") { value in
                ToolState.shared.update(tool) { $0.rate = value }
            })
            stack.addArrangedSubview(slider("Flow", 0...100, brush.flow ?? (tool == .airbrush ? 10 : 0), unit: "") { value in
                ToolState.shared.update(tool) { $0.flow = value }
            })
        case .blur, .sharpen:
            stack.addArrangedSubview(slider("Rate", 0...100, brush.rate ?? 50, unit: "") { value in
                ToolState.shared.update(tool) { $0.rate = value }
            })
        case .dodge, .burn:
            stack.addArrangedSubview(slider("Exposure", 0...100, brush.exposure ?? 50, unit: "") { value in
                ToolState.shared.update(tool) { $0.exposure = value }
            })
            stack.addArrangedSubview(popUp("Range", ["Shadows", "Midtones", "Highlights"],
                                           selected: [.shadows: 0, .midtones: 1, .highlights: 2][brush.tones] ?? 1) { index in
                ToolState.shared.update(tool) { $0.tones = [.shadows, .midtones, .highlights][index] }
            })
        case .eraser:
            stack.addArrangedSubview(checkbox("Anti-erase (restore)", brush.antiErase) { on in
                ToolState.shared.update(tool) { $0.antiErase = on }
            })
        case .clone, .heal:
            stack.addArrangedSubview(hint("Option-click the image to set the source."))
        default:
            break
        }

        stack.addArrangedSubview(checkbox("Pen pressure sets size", brush.pressureSize) { on in
            ToolState.shared.update(tool) { $0.pressureSize = on }
        })
        stack.addArrangedSubview(presetsRow())
    }

    /// The Presets… entry: opens the one retained presets panel for the global
    /// ToolState. The panel captures and applies the current paint tool's
    /// settings itself; no engine call happens here.
    private func presetsRow() -> NSView {
        let button = NSButton(title: "Presets…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = "Save, rename, update, delete and apply presets of the paint tools' settings"
        button.setAccessibilityLabel("Presets…")
        actionBindings.append(ActionBinding(control: button) { _ in
            PaintToolPresetPanelController.shared.open()
        })
        return row("Presets", button, onChange: nil)
    }

    /// The brush row: a button with the current choice (name and, once the
    /// chooser loaded it, the 32 px thumbnail; a persisted identity that no
    /// longer resolves shows as "Missing: …") that opens the brush chooser,
    /// plus an explicit reset to the native Default brush.
    private func brushRow(for tool: ToolID, brush: EngineSession.Brush) -> NSView {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let missing = BrushChooser.shared.missingIdentity(for: tool, choice: brush.resource) {
            button.title = "Missing: \(missing.name)"
        } else if let resource = brush.resource {
            button.title = resource.name
        } else {
            button.title = "Default"
        }
        if let thumbnail = BrushChooser.shared.thumbnail(for: tool, choice: brush.resource) {
            button.image = thumbnail
            button.imagePosition = .imageLeft
        }
        button.toolTip = "Choose the \(tool.name) brush"
        button.setAccessibilityLabel("Brush for \(tool.name)")
        actionBindings.append(ActionBinding(control: button) { [weak self] _ in
            self?.openBrushChooser(for: tool)
        })
        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)
        reset.toolTip = "Reset to the native Default brush"
        reset.setAccessibilityLabel("Reset brush to Default")
        actionBindings.append(ActionBinding(control: reset) { _ in
            BrushChooser.shared.resetChoice(for: tool)
        })
        let controls = NSStackView(views: [button, reset])
        controls.spacing = 6
        return row("Brush", controls, onChange: nil)
    }

    /// Opens the one brush chooser; it captures `tool` at open and applies
    /// only that tool's selection.
    private func openBrushChooser(for tool: ToolID) {
        BrushChooser.shared.open(document: document, tool: tool)
    }

    /// The Gradient tool's options: the resource row (button with the
    /// current choice's real name and preview, plus an explicit reset to
    /// the Foreground-to-Background Default), then shape, blend, reverse
    /// and opacity. The blend popup offers only Perceptual RGB and Lab —
    /// the backend refuses RGB Linear with UNSUPPORTED, so it is never
    /// offered.
    private func addGradientRows(_ state: ToolState) {
        stack.addArrangedSubview(gradientRow(state))
        stack.addArrangedSubview(popUp("Shape", ["Linear", "Bi-Linear", "Radial"],
                                       selected: Int(state.gradientShape.rawValue)) { index in
            ToolState.shared.gradientShape = EngineSession.GradientShape(rawValue: UInt32(index)) ?? .linear
        })
        let blendSpaces = EngineSession.GradientBlendSpace.selectable
        stack.addArrangedSubview(popUp("Blend", blendSpaces.map(\.name),
                                       selected: blendSpaces.firstIndex(of: state.gradientBlendSpace) ?? 0) { index in
            ToolState.shared.gradientBlendSpace = blendSpaces[index]
        })
        stack.addArrangedSubview(checkbox("Reverse", state.gradientReverse) { on in
            ToolState.shared.gradientReverse = on
        })
        stack.addArrangedSubview(slider("Opacity", 0...100, state.gradientOpacity * 100, unit: "%") { value in
            ToolState.shared.gradientOpacity = value / 100
        })
        stack.addArrangedSubview(hint("Drag across the image to draw the gradient. "
            + "The default is foreground to background."))
    }

    /// The gradient row: a button with the current choice (name and, once
    /// the chooser rendered it, the preview; a persisted identity that no
    /// longer resolves shows as "Missing: …"; no choice shows the
    /// Foreground-to-Background Default) that opens the gradient chooser,
    /// plus an explicit reset to the Default.
    private func gradientRow(_ state: ToolState) -> NSView {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        if let missing = GradientChooser.shared.missingIdentity(choice: state.gradientResource) {
            button.title = "Missing: \(missing.name)"
        } else if let resource = state.gradientResource {
            button.title = resource.name
        } else {
            button.title = "Foreground to Background"
        }
        if let thumbnail = GradientChooser.shared.thumbnail(choice: state.gradientResource) {
            button.image = thumbnail
            button.imagePosition = .imageLeft
        }
        button.toolTip = "Choose the gradient"
        button.setAccessibilityLabel("Gradient")
        actionBindings.append(ActionBinding(control: button) { [weak self] _ in
            self?.openGradientChooser()
        })
        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)
        reset.toolTip = "Reset to the Foreground-to-Background default gradient"
        reset.setAccessibilityLabel("Reset gradient to Foreground to Background")
        actionBindings.append(ActionBinding(control: reset) { _ in
            GradientChooser.shared.resetChoice()
        })
        let controls = NSStackView(views: [button, reset])
        controls.spacing = 6
        return row("Gradient", controls, onChange: nil)
    }

    /// Opens the one gradient chooser; it captures the document at open.
    private func openGradientChooser() {
        GradientChooser.shared.open(document: document)
    }

    private func addSelectionRows(for tool: ToolID) {
        let options = ToolState.shared.selectOptions
        let modes = NSSegmentedControl(labels: ["New", "Add", "Subtract", "Intersect"],
                                       trackingMode: .selectOne, target: nil, action: nil)
        modes.selectedSegment = Int(options.operation.rawValue)
        modes.controlSize = .small
        modes.toolTip = "Shift adds, Option subtracts, Shift-Option intersects when you start dragging"
        stack.addArrangedSubview(row("Mode", modes) { control in
            ToolState.shared.selectOptions.operation =
                EngineSession.SelectOperation(rawValue: UInt32((control as! NSSegmentedControl).selectedSegment)) ?? .replace
        })
        stack.addArrangedSubview(slider("Feather", 0...100, options.feather, unit: "px", fractionDigits: 1) { value in
            ToolState.shared.selectOptions.feather = value
        })
        stack.addArrangedSubview(checkbox("Antialiasing", options.antialias) { on in
            ToolState.shared.selectOptions.antialias = on
        })
        if tool == .rectangleSelect {
            stack.addArrangedSubview(slider("Corners", 0...100, options.cornerRadius, unit: "px", fractionDigits: 1) { value in
                ToolState.shared.selectOptions.cornerRadius = value
            })
        }
        if tool == .magicWand || tool == .selectByColor {
            stack.addArrangedSubview(slider("Threshold", 0...255, options.threshold * 255, unit: "") { value in
                ToolState.shared.selectOptions.threshold = value / 255
            })
            stack.addArrangedSubview(checkbox("Sample merged", options.sampleMerged) { on in
                ToolState.shared.selectOptions.sampleMerged = on
            })
        }
    }

    // MARK: Controls

    private func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 220
        return label
    }

    /// A labelled slider with a number field beside it (design principle 6).
    /// A labelled slider with its number field: Rigi's ClassicValueSlider.
    /// Tool settings are not undo steps, so every change applies at once.
    /// Pixel measures take tenths, as the engine does; percentages, rates
    /// and thresholds stay whole.
    private func slider(_ label: String, _ range: ClosedRange<Double>, _ value: Double, unit: String,
                        fractionDigits: Int = 0, _ onChange: @escaping (Double) -> Void) -> NSView {
        let slider = ClassicValueSlider(title: label, range: range, value: value, unit: unit,
                                        fractionDigits: fractionDigits)
        slider.titleWidth = Self.labelWidth
        slider.onChange = { value, _ in onChange(value) }
        return slider
    }

    private func checkbox(_ title: String, _ on: Bool, _ onChange: @escaping (Bool) -> Void) -> NSView {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.controlSize = .small
        box.font = .systemFont(ofSize: 11)
        box.state = on ? .on : .off
        let binding = ActionBinding(control: box) { control in onChange((control as! NSButton).state == .on) }
        actionBindings.append(binding)
        return box
    }

    /// `items` must be distinct: NSPopUpButton drops repeated titles,
    /// which would shift every index after them.
    private func popUp(_ label: String, _ items: [String], selected: Int, _ onChange: @escaping (Int) -> Void) -> NSView {
        assert(Set(items).count == items.count, "repeated pop-up titles in \(label)")
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: 11)
        menu.addItems(withTitles: items)
        menu.selectItem(at: selected)
        return row(label, menu) { control in onChange((control as! NSPopUpButton).indexOfSelectedItem) }
    }

    /// The width of the row labels, so the controls line up.
    private static let labelWidth: CGFloat = 62

    private func row(_ label: String, _ control: NSView, onChange: ((NSControl) -> Void)?) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        if let onChange, let control = control as? NSControl {
            actionBindings.append(ActionBinding(control: control, onChange: onChange))
        }
        let row = NSStackView(views: [title, control])
        row.spacing = 6
        return row
    }


    private var actionBindings: [ActionBinding] = []

    @MainActor
    private final class ActionBinding: NSObject {
        let onChange: (NSControl) -> Void

        init(control: NSControl, onChange: @escaping (NSControl) -> Void) {
            self.onChange = onChange
            super.init()
            control.target = self
            control.action = #selector(changed(_:))
        }

        @objc private func changed(_ sender: NSControl) {
            onChange(sender)
        }
    }
}
