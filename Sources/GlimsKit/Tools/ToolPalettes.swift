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
                + Metrics.gridToColors + ClassicColorPairLayout.size.height + 8 + 18 + Metrics.margin),
        sizing: .fixed,
        frameAutosaveName: "Glims.palette.tools")

    private let grid = ClassicToolGrid(slots: ToolID.paletteSlots.map { group in
        ClassicToolGrid.Slot(tools: group.map {
            ClassicToolGrid.Tool(id: $0.rawValue, name: $0.name, shortcut: $0.shortcut, image: $0.image)
        })
    })
    private let colors = ClassicColorPair()
    private let screenModes = NSSegmentedControl(labels: DocumentScreenMode.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil)
    private weak var targetDocument: ImageDocument?
    private var showsInkTools = false
    /// The owned modeless color editor; a Foreground/Background click
    /// captures that global `ToolState` target in it.
    private var colorEditor: ToolColorEditorController { .shared }
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
        colors.onEditForeground = { [weak self] in self?.colorEditor.open(target: .foreground) }
        colors.onEditBackground = { [weak self] in self?.colorEditor.open(target: .background) }

        screenModes.controlSize = .small
        screenModes.setAccessibilityLabel("Screen mode")
        screenModes.target = self
        screenModes.action = #selector(screenModeChosen(_:))
        let symbols = ["macwindow", "menubar.rectangle", "rectangle.inset.filled"]
        for mode in DocumentScreenMode.allCases {
            screenModes.setWidth(16, forSegment: mode.rawValue)
            screenModes.setToolTip(mode.title, forSegment: mode.rawValue)
            screenModes.setImage(NSImage(systemSymbolName: symbols[mode.rawValue],
                accessibilityDescription: mode.title), forSegment: mode.rawValue)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenModeChanged(_:)),
            name: DocumentWindowController.screenModeDidChange, object: nil)
        for view in [grid, colors, screenModes] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.margin),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            colors.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Metrics.gridToColors),
            colors.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            screenModes.topAnchor.constraint(equalTo: colors.bottomAnchor, constant: 8),
            screenModes.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            screenModes.heightAnchor.constraint(equalToConstant: 18),
        ])
        view = root
        grid.selectTool(id: ToolState.shared.current.rawValue)
        stateChanged()
        refreshScreenMode()
        observer = ToolState.shared.observe { [weak self] in self?.stateChanged() }
    }

    func retarget(to target: ImageDocument?) {
        targetDocument = target
        let ink = target?.colorInfo.mode.usesInkChannels == true
        if showsInkTools != ink {
            showsInkTools = ink
            grid.slots = ToolID.paletteSlots.map { group in
                ClassicToolGrid.Slot(tools: group.map {
                    ClassicToolGrid.Tool(id: $0.rawValue, name: $0.name, shortcut: $0.shortcut,
                        image: $0.image, isEnabled: $0.isAvailable(in: target?.colorInfo.mode))
                })
            }
        }
        if !ToolState.shared.current.isAvailable(in: target?.colorInfo.mode) {
            ToolState.shared.select(.paintbrush)
        }
        stateChanged()
        refreshScreenMode()
    }

    private var targetWindowController: DocumentWindowController? {
        guard let targetDocument else { return nil }
        return NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.imageDocument === targetDocument }
    }

    private func refreshScreenMode() {
        guard isViewLoaded else { return }
        let owner = targetWindowController
        screenModes.isEnabled = owner?.canChangeScreenMode == true
        screenModes.selectedSegment = owner?.screenMode.rawValue ?? 0
    }

    @objc private func screenModeChanged(_ notification: Notification) { refreshScreenMode() }

    @objc private func screenModeChosen(_ sender: NSSegmentedControl) {
        guard let mode = DocumentScreenMode(rawValue: sender.selectedSegment),
              let owner = targetWindowController else { return }
        owner.setScreenMode(mode)
        refreshScreenMode()
    }

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
        guard tool.isAvailable(in: targetDocument?.colorInfo.mode) else { stateChanged(); return }
        ToolState.shared.select(tool)
    }

}

/// The Tool Options palette: the current tool's settings. Its rows are
/// rebuilt when the tool changes. Shared tool settings live in ToolState;
/// numeric transforms edit the target document's pending canvas session.
@MainActor
final class ToolOptionsPaletteController: NSViewController, PaletteContent, NSTextFieldDelegate {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.toolOptions"),
        title: "Tool Options",
        contentSize: NSSize(width: 250, height: 190),
        sizing: .resizable(minimumContentSize: NSSize(width: 220, height: 120)),
        frameAutosaveName: "Glims.palette.toolOptions")

    private final class OptionsStackView: NSStackView {
        override var isFlipped: Bool { true }
    }
    private let stack = OptionsStackView()
    private var shownTool: ToolID?
    private var shownFontCount = 0
    private var shownBrushResource: EngineSession.ResourceIdentity?
    private var shownMissingBrush: EngineSession.ResourceIdentity?
    private var shownBrushPresentationRevision = 0
    private var shownGradient: GradientPresentation?
    private var shownMoveTargetMode: MoveTargetMode?
    private var observer: UUID?
    /// Existing controls follow external changes without replacing the active
    /// field editor. Resource presentation rebuilds wait for editing to end.
    private var brushRefreshers: [(EngineSession.Brush) -> Void] = []
    /// Like the brush refreshers, for the Transform tool's numeric rows:
    /// updates unfocused fields and readiness without touching a live
    /// draft or its selection.
    private var transformRefreshers: [() -> Void] = []
    /// The Transform tool's editable fields, so edit-start can capture
    /// the target and Apply can resolve a live draft.
    private final class TransformFieldEntry {
        let field: NSTextField
        let kind: TransformNumericInput.Field
        let read: (LayerTransformSession) -> Double
        var draft = TransformNumericDraft(text: "")
        init(field: NSTextField, kind: TransformNumericInput.Field,
             read: @escaping (LayerTransformSession) -> Double) {
            self.field = field
            self.kind = kind
            self.read = read
        }
    }
    private var transformFieldEntries: [TransformFieldEntry] = []
    /// The inline message for a rejected transform draft.
    private var transformErrorLabel: NSTextField?
    /// The canvas controller the transform rows currently observe.
    private weak var transformObservedTools: CanvasToolController?
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
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
        rebuild()
        observer = ToolState.shared.observe { [weak self] in self?.stateChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(fieldEditingEnded(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(transformFieldEditingBegan(_:)),
                                               name: NSControl.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(transformFieldChanged(_:)),
                                               name: NSControl.textDidChangeNotification, object: nil)
    }

    private func stateChanged() {
        let state = ToolState.shared
        let fontsArrived = shownTool == .text && shownFontCount != state.fontNames.count
        let brushChanged = state.current.paintTool != nil
            && (shownBrushResource != state.brush(for: state.current).resource
                || shownBrushPresentationRevision != BrushChooser.shared.presentationRevision
                || shownMissingBrush != BrushChooser.shared.missingIdentity(
                    for: state.current, choice: state.brush(for: state.current).resource))
        let gradientChanged = state.current == .gradient
            && shownGradient != Self.gradientPresentation(of: state)
        let moveTargetChanged = state.current == .move && shownMoveTargetMode != state.moveTargetMode
        let presentationChanged = fontsArrived || brushChanged || gradientChanged || moveTargetChanged
        // Keep presentation rows until the active field finishes its normal
        // commit. A tool switch still replaces the options immediately.
        if shownTool != state.current || (presentationChanged && !Self.hasFieldEditor(in: view)) {
            rebuild()
        } else if state.current.paintTool != nil {
            let brush = state.brush(for: state.current)
            brushRefreshers.forEach { $0(brush) }
        } else if state.current == .transform {
            transformRefreshers.forEach { $0() }
        }
    }

    private static func hasFieldEditor(in root: NSView) -> Bool {
        if let field = root as? NSTextField, field.currentEditor() != nil { return true }
        return root.subviews.contains { hasFieldEditor(in: $0) }
    }

    private static func numberField(in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField, field.isEditable { return field }
        return root.subviews.lazy.compactMap { numberField(in: $0) }.first
    }

    @objc private func fieldEditingEnded(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.isDescendant(of: view) else { return }
        // Rigi owns the parser and commit delegate. Reconcile after it has
        // processed the end event, including invalid drafts that emit no edit.
        DispatchQueue.main.async { [weak self] in self?.stateChanged() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func retarget(to target: ImageDocument?) {
        // A different (or closing) document invalidates an open chooser, so
        // its late native results cannot restore a stale sheet.
        let modeChanged = document?.colorInfo.mode != target?.colorInfo.mode
        if target !== document {
            document = target
            if BrushChooser.shared.isOpen { BrushChooser.shared.close() }
            if GradientChooser.shared.isOpen { GradientChooser.shared.close() }
            rebindTransformObserver()
        }
        if modeChanged && isViewLoaded { rebuild() }
    }

    private var targetWindowController: DocumentWindowController? {
        guard let document else { return nil }
        return NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.imageDocument === document }
    }

    /// The canvas controller owning the front document's transform
    /// session, when this palette retargeted that document.
    private var transformTools: CanvasToolController? {
        targetWindowController?.canvas.tools
    }

    /// Moves the observer while preserving drafts and their original targets.
    private func rebindTransformObserver() {
        transformObservedTools?.onTransformSessionChange = nil
        let tools = transformTools
        tools?.onTransformSessionChange = { [weak self] in self?.transformPreviewChanged() }
        transformObservedTools = tools
        transformPreviewChanged()
    }

    private func transformPreviewChanged() {
        transformRefreshers.forEach { $0() }
    }

    private var transformTarget: TransformNumericTarget? {
        guard let document, let tools = transformTools, let preview = tools.transformPreview else { return nil }
        let route = document.moveTargetRevision
        return TransformNumericTarget(document: ObjectIdentifier(document), layer: preview.layer,
                                      original: preview.original, generation: tools.transformGeneration,
                                      routeRevision: [route.pick, route.layers, route.items, route.command])
    }

    @objc private func transformFieldEditingBegan(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let entry = transformFieldEntries.first(where: { $0.field === field }) else { return }
        entry.draft.begin(target: transformTarget)
    }

    @objc private func transformFieldChanged(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let entry = transformFieldEntries.first(where: { $0.field === field }) else { return }
        entry.draft.update(field.currentEditor()?.string ?? field.stringValue)
        transformPreviewChanged()
    }

    func paletteDidDismiss(_ presentation: PalettePresentation) {
        if BrushChooser.shared.isOpen { BrushChooser.shared.close() }
        if GradientChooser.shared.isOpen { GradientChooser.shared.close() }
    }

    private func rebuild() {
        defer {
            if let scroll = view as? NSScrollView {
                stack.layoutSubtreeIfNeeded()
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let state = ToolState.shared
        let tool = state.current
        shownTool = tool
        shownFontCount = state.fontNames.count
        shownBrushResource = tool.paintTool != nil ? state.brush(for: tool).resource : nil
        shownMissingBrush = BrushChooser.shared.missingIdentity(for: tool, choice: shownBrushResource)
        shownBrushPresentationRevision = BrushChooser.shared.presentationRevision
        shownGradient = tool == .gradient ? Self.gradientPresentation(of: state) : nil
        shownMoveTargetMode = tool == .move ? state.moveTargetMode : nil
        brushRefreshers.removeAll()
        transformRefreshers.removeAll()
        transformFieldEntries.removeAll()
        transformErrorLabel = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionBindings.removeAll()

        let title = NSTextField(labelWithString: tool.name)
        title.font = .boldSystemFont(ofSize: 11)
        stack.addArrangedSubview(title)

        if tool.paintTool != nil {
            addPaintRows(for: tool, brush: state.brush(for: tool))
            if document?.colorInfo.mode.usesInkChannels == true {
                stack.addArrangedSubview(hint("Paint the selected ink channel. Black adds full ink; white removes ink. Gray sets intermediate coverage."))
            }
        } else if tool.isSelectionTool {
            addSelectionRows(for: tool)
        } else if tool == .gradient {
            addGradientRows(state)
        } else if tool == .text {
            addTextRows(state.textSettings)
        } else if tool == .transform {
            addTransformRows(state)
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
        } else if tool == .move {
            let modes: [MoveTargetMode] = [.currentLayer, .pickLayerOrGuide]
            let selectedIndex = modes.firstIndex(of: state.moveTargetMode) ?? 0
            stack.addArrangedSubview(popUp("Move target", modes.map(\.title),
                                           selected: selectedIndex,
                                           identifier: "move-target-mode") { index in
                guard index >= 0 && index < modes.count else { return }
                ToolState.shared.setMoveTargetMode(modes[index])
            })
            let message = state.moveTargetMode == .currentLayer
                ? "Drag to move the selected layer. Arrow keys nudge it 1 pixel, Shift-arrow 10. Guides take priority."
                : "Drag to move the layer under the pointer. A press on another layer anchors a floating selection on release. Empty space does nothing. Guides take priority."
            stack.addArrangedSubview(hint(message))
        } else {
            let hints: [ToolID: String] = [
                .crop: "Drag the area to keep, then press Return to crop or Escape to cancel.",
                .eyedropper: "Click the image to pick the foreground color.",
                .hand: "Drag to scroll. Hold Space with any tool for the hand.",
                .zoom: "Click to zoom in; Option-click to zoom out.",
            ]
            stack.addArrangedSubview(hint(hints[tool] ?? ""))
        }
    }

    // MARK: Rows

    /// The Transform tool's options: numeric X/Y/Width/Height (image
    /// pixels) and Angle (clockwise degrees) fields for the pending
    /// session, an inline error for rejected drafts, explicit Apply and
    /// Cancel, then Resample. Field commits edit only the per-document
    /// preview; nothing reaches the engine until Apply, which uses the
    /// canvas's native transform path and its single undo step.
    private func addTransformRows(_ state: ToolState) {
        let modes = LayerTransformSession.Mode.allCases
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        mode.identifier = NSUserInterfaceItemIdentifier("transformMode")
        mode.setAccessibilityLabel("Transform mode")
        mode.addItems(withTitles: modes.map(\.title))
        stack.addArrangedSubview(row("Mode", mode) { [weak self] control in
            guard let self, let menu = control as? NSPopUpButton,
                  modes.indices.contains(menu.indexOfSelectedItem) else { return }
            let selected = modes[menu.indexOfSelectedItem]
            for entry in self.transformFieldEntries where entry.field.currentEditor() != nil || entry.draft.hasDraft {
                guard self.commitTransformField(entry) else {
                    self.transformPreviewChanged()
                    return
                }
            }
            _ = self.transformTools?.setTransformMode(selected)
            self.transformPreviewChanged()
        })
        transformRefreshers.append { [weak self, weak mode] in
            let tools = self?.transformTools
            mode?.selectItem(at: modes.firstIndex(of: tools?.transformPreview?.mode ?? .scaleRotate) ?? 0)
            mode?.isEnabled = tools?.transformNumericEditsAllowed == true
        }
        for (label, kind, read): (String, TransformNumericInput.Field,
                                  (LayerTransformSession) -> Double) in [
            ("X", .x, { $0.box.minX }),
            ("Y", .y, { $0.box.minY }),
            ("Width", .width, { $0.box.width }),
            ("Height", .height, { $0.box.height }),
            ("Angle", .angle, { $0.angle * 180 / .pi }),
        ] {
            stack.addArrangedSubview(transformRow(label, kind: kind, read: read))
        }

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = 220
        errorLabel.isHidden = true
        transformErrorLabel = errorLabel
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(transformButtonsRow())

        let methods = EngineSession.Interpolation.allCases
        stack.addArrangedSubview(popUp("Resample", methods.map(\.name),
                                       selected: methods.firstIndex(of: state.transformInterpolation) ?? 2) { index in
            ToolState.shared.transformInterpolation = methods[index]
        })
        let instructions = NSTextField(wrappingLabelWithString: "")
        instructions.font = .systemFont(ofSize: 11)
        instructions.textColor = .secondaryLabelColor
        instructions.preferredMaxLayoutWidth = 220
        stack.addArrangedSubview(instructions)
        transformRefreshers.append { [weak self, weak instructions] in
            let mode = self?.transformTools?.transformPreview?.mode ?? .scaleRotate
            let gesture: String
            switch mode {
            case .scaleRotate:
                gesture = "Drag a corner or edge to scale; Shift keeps the proportions."
            case .skew:
                gesture = "Drag an edge handle along its edge to skew."
            case .distort:
                gesture = "Drag a corner independently, or an edge to move both corners."
            case .perspective:
                gesture = "Drag a corner horizontally or vertically to move its pair symmetrically. The first movement fixes the direction."
            }
            instructions?.stringValue = gesture + " Drag inside to move or outside to rotate (Shift: 15° steps). "
                + "Position, size and angle control the frame and preserve any warp. Apply commits; Escape cancels."
        }
        transformRefreshers.forEach { $0() }
    }

    /// One numeric transform field. Committing parses the draft strictly;
    /// a rejected value keeps the draft and shows the reason inline —
    /// nothing is clamped or reverted.
    private func transformRow(_ label: String, kind: TransformNumericInput.Field,
                              read: @escaping (LayerTransformSession) -> Double) -> NSView {
        let field = NSTextField(frame: .zero)
        field.isEditable = true
        field.delegate = self
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel("Transform \(label)")
        field.widthAnchor.constraint(equalToConstant: 95).isActive = true
        field.toolTip = kind == .angle ? "Clockwise rotation in degrees" : "Image pixels"
        let entry = TransformFieldEntry(field: field, kind: kind, read: read)
        transformFieldEntries.append(entry)
        transformRefreshers.append { [weak self, weak entry] in
            guard let self, let entry else { return }
            let field = entry.field
            let tools = self.transformTools
            let preview = tools?.transformPreview
            let editor = field.currentEditor()
            if let editor { entry.draft.update(editor.string) }
            let current = preview.map { Self.transformText(read($0)) } ?? ""
            entry.draft.refresh(current, target: self.transformTarget, editing: editor != nil)
            // Keep a rejected or stale draft editable so it can be corrected
            // or explicitly cancelled even after its old target disappears.
            field.isEnabled = tools?.transformNumericEditsAllowed == true || entry.draft.hasDraft
            if let editor {
                if editor.string != entry.draft.text {
                    let selection = editor.selectedRange
                    editor.string = entry.draft.text
                    let count = (entry.draft.text as NSString).length
                    let location = min(selection.location, count)
                    editor.selectedRange = NSRange(location: location, length: min(selection.length, count - location))
                }
            } else {
                field.stringValue = entry.draft.text
            }
        }
        let result = row(label, field) { [weak self, weak entry] _ in
            guard let entry else { return }
            _ = self?.commitTransformField(entry)
        }
        let unit = NSTextField(labelWithString: kind == .angle ? "°" : "px")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor
        (result as? NSStackView)?.addArrangedSubview(unit)
        return result
    }

    private static func transformText(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// The commit behind a transform field's action (Return or end of
    /// editing). Validates the draft, then applies all five values
    /// atomically to the pending session through the canvas.
    @discardableResult
    private func commitTransformField(_ entry: TransformFieldEntry) -> Bool {
        let field = entry.field
        entry.draft.update(field.currentEditor()?.string ?? field.stringValue)
        func refuse(_ message: String) -> Bool {
            entry.draft.reject(message)
            showTransformError(message)
            transformPreviewChanged()
            return false
        }
        // An untouched field has no command to route. Focus/target refreshes
        // must not manufacture a stale draft that blocks mode changes.
        guard entry.draft.hasDraft else { return true }
        guard let tools = transformTools, let preview = tools.transformPreview else {
            return refuse("Select a layer to transform, or Cancel to discard this draft.")
        }
        guard entry.draft.canCommit(to: transformTarget) else {
            return refuse("The transform target changed. Cancel this draft, then edit the new target.")
        }
        guard let value = TransformNumericInput.parse(entry.draft.text) else {
            return refuse("Enter a number, for example 12.5.")
        }
        if let problem = TransformNumericInput.problem(value, for: entry.kind) { return refuse(problem) }
        var origin = preview.box.origin
        var width = preview.box.width, height = preview.box.height
        var degrees = preview.angle * 180 / .pi
        switch entry.kind {
        case .x: origin.x = value
        case .y: origin.y = value
        case .width: width = value
        case .height: height = value
        case .angle: degrees = value
        }
        guard tools.setTransformGeometry(origin: origin, width: width, height: height,
                                         degrees: degrees, expectedLayer: preview.layer,
                                         expectedOriginal: preview.original),
              let accepted = tools.transformPreview else {
            return refuse("The layer is unavailable or the transform exceeds its supported bounds.")
        }
        entry.draft.accept(text: Self.transformText(entry.read(accepted)), target: transformTarget)
        field.stringValue = entry.draft.text
        field.currentEditor()?.string = entry.draft.text
        showTransformError(transformFieldEntries.compactMap { $0.draft.error }.first)
        transformPreviewChanged()
        return true
    }

    private func showTransformError(_ message: String?) {
        transformErrorLabel?.stringValue = message ?? ""
        transformErrorLabel?.isHidden = message == nil
    }

    /// The Apply and Cancel buttons. Apply first resolves a focused
    /// field's valid draft so its value joins the committed transform; a
    /// draft that fails validation blocks Apply instead of being dropped.
    private func transformButtonsRow() -> NSView {
        let apply = NSButton(title: "Apply", target: nil, action: nil)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        for button in [apply, cancel] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        apply.setAccessibilityLabel("Apply transform")
        cancel.setAccessibilityLabel("Cancel transform")
        actionBindings.append(ActionBinding(control: apply) { [weak self] _ in
            self?.applyTransformFromOptions()
        })
        actionBindings.append(ActionBinding(control: cancel) { [weak self] _ in
            self?.cancelTransformFromOptions()
        })
        transformRefreshers.append { [weak self, weak apply, weak cancel] in
            let tools = self?.transformTools
            let busy = tools?.transformDragInProgress == true || tools?.transformCommitIsPending == true
            let hasDraft = self?.transformFieldEntries.contains { $0.draft.hasDraft } == true
            apply?.isEnabled = tools?.transformNumericEditsAllowed == true
                && (tools?.transformIsApplicable == true || hasDraft) && !busy
            cancel?.isEnabled = (tools?.transformSession != nil || hasDraft) && !busy
        }
        let controls = NSStackView(views: [apply, cancel])
        controls.spacing = 6
        return row("", controls, onChange: nil)
    }

    private func applyTransformFromOptions() {
        guard let tools = transformTools, tools.transformNumericEditsAllowed else { return }
        for entry in transformFieldEntries where entry.field.currentEditor() != nil || entry.draft.hasDraft {
            guard commitTransformField(entry) else { return }
        }
        // End the accepted field edit before Apply starts a new transform
        // lifetime. A button click can otherwise leave the same editor alive
        // with its previous generation captured for the next typed value.
        guard view.window?.makeFirstResponder(nil) != false else { return }
        tools.applyPendingTransform()
        transformPreviewChanged()
    }

    private func cancelTransformFromOptions() {
        let current = transformTarget
        let hasForeignDraft = transformFieldEntries.contains {
            $0.draft.hasDraft && !$0.draft.canCommit(to: current)
        }
        // Cancelling A's stale draft after retargeting must not discard B's
        // unrelated pending transform.
        if !hasForeignDraft { transformTools?.cancelPendingTransform() }
        let preview = transformTools?.transformPreview
        for entry in transformFieldEntries {
            entry.draft.cancel(text: preview.map { Self.transformText(entry.read($0)) } ?? "")
            entry.draft.begin(target: transformTarget)
            entry.field.stringValue = entry.draft.text
            entry.field.currentEditor()?.string = entry.draft.text
        }
        showTransformError(nil)
        transformPreviewChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let entry = transformFieldEntries.first(where: { $0.field === control }) else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            let text = transformTools?.transformPreview.map { Self.transformText(entry.read($0)) } ?? ""
            entry.draft.cancel(text: text)
            entry.draft.begin(target: transformTarget)
            entry.field.stringValue = text
            textView.string = text
            showTransformError(transformFieldEntries.compactMap { $0.draft.error }.first)
            transformPreviewChanged()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            _ = commitTransformField(entry)
            return true
        }
        return false
    }

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
        stack.addArrangedSubview(slider("Size", 1...PaintToolPresetLimits.maxSize, brush.size,
                                       unit: "px", fractionDigits: 1, readBrush: { $0.size }) { value in
            ToolState.shared.update(tool) { $0.size = value }
        })
        stack.addArrangedSubview(slider("Opacity", 0...100, brush.opacity * 100, unit: "%",
                                       readBrush: { $0.opacity * 100 }) { value in
            ToolState.shared.update(tool) { $0.opacity = value / 100 }
        })
        stack.addArrangedSubview(slider("Hardness", 0...100, (brush.hardness ?? 0.5) * 100, unit: "%",
                                       readBrush: { ($0.hardness ?? 0.5) * 100 }) { value in
            ToolState.shared.update(tool) { $0.hardness = value / 100 }
        })

        switch tool {
        case .airbrush, .smudge:
            stack.addArrangedSubview(slider("Rate", 0...100, brush.rate ?? 50, unit: "",
                                           readBrush: { $0.rate ?? 50 }) { value in
                ToolState.shared.update(tool) { $0.rate = value }
            })
            stack.addArrangedSubview(slider("Flow", 0...100, brush.flow ?? (tool == .airbrush ? 10 : 0), unit: "",
                                           readBrush: { $0.flow ?? (tool == .airbrush ? 10 : 0) }) { value in
                ToolState.shared.update(tool) { $0.flow = value }
            })
        case .blur, .sharpen:
            stack.addArrangedSubview(slider("Rate", 0...100, brush.rate ?? 50, unit: "",
                                           readBrush: { $0.rate ?? 50 }) { value in
                ToolState.shared.update(tool) { $0.rate = value }
            })
        case .dodge, .burn:
            stack.addArrangedSubview(slider("Exposure", 0...100, brush.exposure ?? 50, unit: "",
                                           readBrush: { $0.exposure ?? 50 }) { value in
                ToolState.shared.update(tool) { $0.exposure = value }
            })
            stack.addArrangedSubview(popUp("Range", ["Shadows", "Midtones", "Highlights"],
                                           selected: [.shadows: 0, .midtones: 1, .highlights: 2][brush.tones] ?? 1,
                                           readBrush: { [.shadows: 0, .midtones: 1, .highlights: 2][$0.tones] ?? 1 }) { index in
                ToolState.shared.update(tool) { $0.tones = [.shadows, .midtones, .highlights][index] }
            })
        case .spongeDesaturate, .spongeSaturate:
            stack.addArrangedSubview(hint("Changes saturation on RGB pixels while preserving hue and transparency. Opacity sets the strength."))
        case .eraser:
            stack.addArrangedSubview(checkbox("Anti-erase (restore)", brush.antiErase,
                                             readBrush: { $0.antiErase }) { on in
                ToolState.shared.update(tool) { $0.antiErase = on }
            })
        case .clone, .heal:
            stack.addArrangedSubview(hint("Option-click the image to set the source."))
        default:
            break
        }

        stack.addArrangedSubview(checkbox("Pen pressure sets size", brush.pressureSize,
                                         readBrush: { $0.pressureSize }) { on in
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
        modes.setAccessibilityLabel("Selection mode")
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
        if tool == .rectangleSelect || tool == .ellipseSelect {
            stack.addArrangedSubview(hint("While dragging, Shift keeps equal sides and Option draws from the center. Escape cancels."))
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
                        fractionDigits: Int = 0, readBrush: ((EngineSession.Brush) -> Double)? = nil,
                        _ onChange: @escaping (Double) -> Void) -> NSView {
        let slider = ClassicValueSlider(title: label, range: range, value: value, unit: unit,
                                        fractionDigits: fractionDigits)
        slider.titleWidth = Self.labelWidth
        slider.onChange = { value, _ in onChange(value) }
        if let readBrush {
            // Capture Rigi's actual committed formatting, including its
            // precision. A focused but untouched field can follow the model;
            // partial, invalid and numerically equivalent drafts stay intact.
            var committedValue = slider.value
            var committedText = Self.numberField(in: slider)?.stringValue ?? ""
            brushRefreshers.append { [weak slider] brush in
                guard let slider, let field = Self.numberField(in: slider) else { return }
                if slider.value != committedValue {
                    // Rigi committed a local edit before invoking onChange.
                    committedValue = slider.value
                    committedText = field.stringValue
                }
                let editor = field.currentEditor()
                let rawText = editor?.string
                let hasDraft = rawText.map { $0 != committedText } ?? false
                let selection = editor?.selectedRange
                let selectedAll = selection == NSRange(location: 0, length: (editor?.string as NSString?)?.length ?? 0)
                // Advance Rigi's silent baseline even under a preserved draft:
                // an explicit commit equal to the old value must still emit
                // onChange when the external model has changed meanwhile.
                slider.value = readBrush(brush)
                committedValue = slider.value
                committedText = field.stringValue
                if let editor, let selection {
                    let text = hasDraft ? rawText ?? committedText : committedText
                    editor.string = text
                    let count = (text as NSString).length
                    let start = min(selection.location, count)
                    editor.selectedRange = selectedAll ? NSRange(location: 0, length: count)
                        : NSRange(location: start, length: min(selection.length, count - start))
                }
            }
        }
        return slider
    }

    private func checkbox(_ title: String, _ on: Bool, readBrush: ((EngineSession.Brush) -> Bool)? = nil,
                          _ onChange: @escaping (Bool) -> Void) -> NSView {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.controlSize = .small
        box.font = .systemFont(ofSize: 11)
        box.state = on ? .on : .off
        let binding = ActionBinding(control: box) { control in onChange((control as! NSButton).state == .on) }
        actionBindings.append(binding)
        if let readBrush {
            brushRefreshers.append { [weak box] brush in box?.state = readBrush(brush) ? .on : .off }
        }
        return box
    }

    /// `items` must be distinct: NSPopUpButton drops repeated titles,
    /// which would shift every index after them.
    private func popUp(_ label: String, _ items: [String], selected: Int,
                       identifier: String? = nil,
                       readBrush: ((EngineSession.Brush) -> Int)? = nil,
                       _ onChange: @escaping (Int) -> Void) -> NSView {
        assert(Set(items).count == items.count, "repeated pop-up titles in \(label)")
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: 11)
        if let identifier {
            menu.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        menu.setAccessibilityLabel(label)
        menu.addItems(withTitles: items)
        menu.selectItem(at: selected)
        if let readBrush {
            brushRefreshers.append { [weak menu] brush in menu?.selectItem(at: readBrush(brush)) }
        }
        return row(label, menu) { control in onChange((control as! NSPopUpButton).indexOfSelectedItem) }
    }

    /// The width of the row labels, so the controls line up.
    private static let labelWidth: CGFloat = 62

    private func row(_ label: String, _ control: NSView, onChange: ((NSControl) -> Void)?) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        if let control = control as? NSControl {
            control.setAccessibilityTitleUIElement(title)
        }
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
