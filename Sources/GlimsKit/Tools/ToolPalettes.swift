import AppKit
import RigiUI

/// The Tools palette: the tool grid and the foreground color.
@MainActor
final class ToolsPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.tools"),
        title: "Tools",
        contentSize: NSSize(width: 61, height: 194),
        sizing: .fixed,
        frameAutosaveName: "Glims.palette.tools")

    private let grid = ClassicToolGrid(slots: ToolID.paletteSlots.map { group in
        ClassicToolGrid.Slot(tools: group.map {
            ClassicToolGrid.Tool(id: $0.rawValue, name: $0.name, shortcut: $0.shortcut, image: $0.image)
        })
    })
    private let colorWell = NSColorWell()
    private var observer: UUID?

    override func loadView() {
        let root = NSView()
        grid.target = self
        grid.action = #selector(toolChosen(_:))
        grid.setAccessibilityLabel("Tools")
        colorWell.color = ToolState.shared.foreground
        colorWell.target = self
        colorWell.action = #selector(colorChosen(_:))
        colorWell.toolTip = "Foreground color"
        colorWell.setAccessibilityLabel("Foreground color")

        for view in [grid, colorWell] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            colorWell.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            colorWell.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            colorWell.heightAnchor.constraint(equalToConstant: 22),
        ])
        view = root
        grid.selectTool(id: ToolState.shared.current.rawValue)
        observer = ToolState.shared.observe { [weak self] in self?.stateChanged() }
    }

    func retarget(to target: ImageDocument?) {}

    private func stateChanged() {
        if grid.selectedToolID != ToolState.shared.current.rawValue {
            grid.selectTool(id: ToolState.shared.current.rawValue)
        }
        if colorWell.color != ToolState.shared.foreground {
            colorWell.color = ToolState.shared.foreground
        }
    }

    @objc private func toolChosen(_ sender: ClassicToolGrid) {
        guard let id = sender.selectedToolID, let tool = ToolID(rawValue: id) else { return }
        ToolState.shared.select(tool)
    }

    @objc private func colorChosen(_ sender: NSColorWell) {
        ToolState.shared.foreground = sender.color
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
    private var observer: UUID?

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        view = stack
        rebuild()
        observer = ToolState.shared.observe { [weak self] in
            guard let self, self.shownTool != ToolState.shared.current else { return }
            self.rebuild()
        }
    }

    func retarget(to target: ImageDocument?) {}

    private func rebuild() {
        let state = ToolState.shared
        let tool = state.current
        shownTool = tool
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bindings.removeAll()
        actionBindings.removeAll()

        let title = NSTextField(labelWithString: tool.name)
        title.font = .boldSystemFont(ofSize: 11)
        stack.addArrangedSubview(title)

        if tool.paintTool != nil {
            addPaintRows(for: tool, brush: state.brush(for: tool))
        } else if tool.isSelectionTool {
            addSelectionRows(for: tool)
        } else {
            let hints: [ToolID: String] = [
                .eyedropper: "Click the image to pick the foreground color.",
                .hand: "Drag to scroll. Hold Space with any tool for the hand.",
                .zoom: "Click to zoom in; Option-click to zoom out.",
            ]
            stack.addArrangedSubview(hint(hints[tool] ?? ""))
        }
    }

    // MARK: Rows

    private func addPaintRows(for tool: ToolID, brush: EngineSession.Brush) {
        stack.addArrangedSubview(slider("Size", 1...500, brush.size, unit: "px") { value in
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
        stack.addArrangedSubview(slider("Feather", 0...100, options.feather, unit: "px") { value in
            ToolState.shared.selectOptions.feather = value
        })
        stack.addArrangedSubview(checkbox("Antialiasing", options.antialias) { on in
            ToolState.shared.selectOptions.antialias = on
        })
        if tool == .rectangleSelect {
            stack.addArrangedSubview(slider("Corners", 0...100, options.cornerRadius, unit: "px") { value in
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
    private func slider(_ label: String, _ range: ClosedRange<Double>, _ value: Double, unit: String,
                        _ onChange: @escaping (Double) -> Void) -> NSView {
        let slider = NSSlider(value: min(max(value, range.lowerBound), range.upperBound),
                              minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        let field = NSTextField(string: Self.format(slider.doubleValue))
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .systemFont(ofSize: 11)

        let binding = ValueBinding(slider: slider, field: field, range: range, onChange: onChange)
        bindings.append(binding)

        let container = NSStackView(views: [slider, field, unitLabel])
        container.spacing = 4
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return row(label, container, onChange: nil)
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

    private func popUp(_ label: String, _ items: [String], selected: Int, _ onChange: @escaping (Int) -> Void) -> NSView {
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: 11)
        menu.addItems(withTitles: items)
        menu.selectItem(at: selected)
        return row(label, menu) { control in onChange((control as! NSPopUpButton).indexOfSelectedItem) }
    }

    private func row(_ label: String, _ control: NSView, onChange: ((NSControl) -> Void)?) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 11)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 62).isActive = true
        if let onChange, let control = control as? NSControl {
            actionBindings.append(ActionBinding(control: control, onChange: onChange))
        }
        let row = NSStackView(views: [title, control])
        row.spacing = 6
        return row
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var bindings: [ValueBinding] = []
    private var actionBindings: [ActionBinding] = []

    /// Keeps a slider and its field in step and reports each change.
    @MainActor
    private final class ValueBinding: NSObject {
        let slider: NSSlider
        let field: NSTextField
        let range: ClosedRange<Double>
        let onChange: (Double) -> Void

        init(slider: NSSlider, field: NSTextField, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
            self.slider = slider
            self.field = field
            self.range = range
            self.onChange = onChange
            super.init()
            slider.target = self
            slider.action = #selector(sliderMoved)
            field.target = self
            field.action = #selector(fieldEdited)
        }

        @objc private func sliderMoved() {
            field.stringValue = ToolOptionsPaletteController.format(slider.doubleValue.rounded())
            onChange(slider.doubleValue.rounded())
        }

        @objc private func fieldEdited() {
            let value = min(max(field.doubleValue, range.lowerBound), range.upperBound)
            slider.doubleValue = value
            field.stringValue = ToolOptionsPaletteController.format(value)
            onChange(value)
        }
    }

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
