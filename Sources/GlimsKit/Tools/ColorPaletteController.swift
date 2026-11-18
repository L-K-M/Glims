import AppKit
import RigiUI

/// Photoshop's color bar: a spectrum to click or drag in. A click picks
/// the color under the pointer for the palette's active color; an
/// Option-click picks it for the other one.
final class ColorBarView: NSView {
    enum Pick: Equatable {
        case active(Swatch)
        case inactive(Swatch)
    }

    var onPick: ((Pick) -> Void)?

    override var isFlipped: Bool { true }

    /// The color at `point` (view coordinates).
    func color(at point: NSPoint) -> Swatch {
        guard bounds.width > 0, bounds.height > 0 else { return Swatch(red: 0, green: 0, blue: 0) }
        return ColorSliderState.colorBar(x: Double(point.x / bounds.width), y: Double(point.y / bounds.height))
    }

    /// Draws exactly what `ColorSliderState.colorBar` returns: pure hues
    /// are linear in sRGB between the six 60-degree stops, and the white
    /// and black overlays are linear in saturation and brightness.
    override func draw(_ dirtyRect: NSRect) {
        let stops = stride(from: 0.0, through: 360, by: 60).map {
            HSBComponents(hue: $0, saturation: 1, brightness: 1).color.color
        }
        let locations = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        let hues = NSGradient(colors: stops, atLocations: locations, colorSpace: .sRGB)
        hues?.draw(in: bounds, angle: 0)

        let half = bounds.height / 2
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        // In a flipped view, angle 90 runs from the top edge down.
        NSGradient(starting: white, ending: white.withAlphaComponent(0))?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: half), angle: 90)
        NSGradient(starting: black.withAlphaComponent(0), ending: black)?
            .draw(in: NSRect(x: 0, y: half, width: bounds.width, height: bounds.height - half), angle: 90)

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clamped = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        let color = color(at: clamped)
        onPick?(event.modifierFlags.contains(.option) ? .inactive(color) : .active(color))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Color bar" }
    override func accessibilityHelp() -> String? {
        "Click to choose the active color; Option-click to choose the other one. The sliders set the same colors."
    }
}

/// The foreground and background squares, overlapped as in the Tools
/// palette, with the active one outlined. A click on a square makes it
/// active; a double-click opens the numeric color editor for it.
final class ColorPairView: NSView {
    var foreground = NSColor.black { didSet { needsDisplay = true } }
    var background = NSColor.white { didSet { needsDisplay = true } }
    var active = ToolColorTarget.foreground { didSet { needsDisplay = true } }
    var onSelect: ((ToolColorTarget, _ edit: Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 26) }

    private var square: CGFloat { min(bounds.width, bounds.height) * 0.7 }
    var foregroundRect: NSRect { NSRect(x: 0, y: 0, width: square, height: square) }
    var backgroundRect: NSRect {
        NSRect(x: bounds.width - square, y: bounds.height - square, width: square, height: square)
    }

    override func draw(_ dirtyRect: NSRect) {
        for target in [ToolColorTarget.background, .foreground] {
            let rect = target == .foreground ? foregroundRect : backgroundRect
            (target == .foreground ? foreground : background).setFill()
            rect.fill()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            if target == active {
                NSColor.controlAccentColor.setStroke()
                outline.lineWidth = 2
            } else {
                NSColor.separatorColor.setStroke()
            }
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The foreground square is drawn on top, so it wins where they overlap.
        let target: ToolColorTarget
        if foregroundRect.contains(point) {
            target = .foreground
        } else if backgroundRect.contains(point) {
            target = .background
        } else {
            return
        }
        onSelect?(target, event.clickCount >= 2)
    }

    // The segmented control beside it offers the same choice to
    // assistive technologies.
    override func isAccessibilityElement() -> Bool { false }
}

/// Window ▸ Color: Photoshop's Color palette. Sliders in RGB, HSB or
/// Grayscale (the palette menu) edit the active tool color, the
/// foreground or the background, and the color bar picks from a
/// spectrum. The palette edits only the global tool colors, never an
/// image, so it ignores its target.
@MainActor
final class ColorPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.color"), title: "Color",
        contentSize: NSSize(width: 240, height: 150),
        sizing: .resizable(minimumContentSize: NSSize(width: 210, height: 150)),
        frameAutosaveName: "Glims.palette.color")

    static let modeKey = "Glims.colorPalette.sliders"

    let targetControl = NSSegmentedControl(labels: ["Foreground", "Background"], trackingMode: .selectOne,
                                           target: nil, action: nil)
    let pair = ColorPairView()
    let colorBar = ColorBarView()
    private(set) var sliders: [NSSlider] = []
    private(set) var fields: [NSTextField] = []
    private var labels: [NSTextField] = []
    private var units: [NSTextField] = []
    private var rows: [NSStackView] = []

    private let tools: ToolState
    private let defaults: UserDefaults
    private var toolsObserver: UUID?
    private var states: [ToolColorTarget: ColorSliderState]

    private(set) var target = ToolColorTarget.foreground
    private(set) var mode: ColorSliderMode

    /// nil means the shared tool state and the standard user defaults.
    init(tools: ToolState? = nil, defaults: UserDefaults? = nil) {
        let tools = tools ?? .shared
        let defaults = defaults ?? .standard
        self.tools = tools
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(ColorSliderMode.init(rawValue:)) ?? .rgb
        states = [.foreground: ColorSliderState(color: Self.swatch(tools.foreground)),
                  .background: ColorSliderState(color: Self.swatch(tools.background))]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let toolsObserver {
            MainActor.assumeIsolated { tools.removeObserver(toolsObserver) }
        }
    }

    override func loadView() {
        targetControl.target = self
        targetControl.action = #selector(targetChanged(_:))
        targetControl.controlSize = .small
        targetControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetControl.setAccessibilityLabel("Color to edit")
        pair.onSelect = { [weak self] target, edit in self?.select(target, edit: edit) }
        let header = NSStackView(views: [pair, targetControl])
        header.spacing = 8

        for index in 0..<3 {
            let label = NSTextField(labelWithString: "")
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 255, target: self, action: #selector(sliderChanged(_:)))
            slider.tag = index
            slider.controlSize = .small
            slider.isContinuous = true
            slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let field = NSTextField(string: "")
            field.tag = index
            field.target = self
            field.action = #selector(fieldChanged(_:))
            field.controlSize = .small
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 40).isActive = true
            let unit = NSTextField(labelWithString: "")
            unit.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let row = NSStackView(views: [label, slider, field, unit])
            row.spacing = 4
            labels.append(label); sliders.append(slider); fields.append(field); units.append(unit); rows.append(row)
        }

        colorBar.onPick = { [weak self] pick in self?.pick(pick) }
        colorBar.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [header] + rows + [colorBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        colorBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        view = stack

        toolsObserver = tools.observe { [weak self] in self?.toolsChanged() }
        // The colors may have changed since init took its snapshot.
        toolsChanged()
    }

    func retarget(to target: ImageDocument?) {}

    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Color")
        for (index, sliders) in ColorSliderMode.allCases.enumerated() {
            let item = NSMenuItem(title: sliders.menuTitle, action: #selector(modeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = sliders == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Shows `mode`'s sliders and remembers the choice.
    func setMode(_ mode: ColorSliderMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        refresh()
    }

    /// Makes `target` the color the sliders edit.
    func select(_ target: ToolColorTarget, edit: Bool = false) {
        self.target = target
        refresh()
        if edit { _ = ToolColorEditorController.shared.open(target: target) }
    }

    /// Sets slider `index` to `value` in the slider's units; false (with a
    /// beep from the controls) when the value is out of range.
    @discardableResult
    func setChannel(_ index: Int, to value: Double) -> Bool {
        guard var state = states[target], state.set(value, channel: index, mode: mode) else { return false }
        commit(state, to: target)
        return true
    }

    private func pick(_ pick: ColorBarView.Pick) {
        switch pick {
        case .active(let color): set(color, for: target)
        case .inactive(let color): set(color, for: target == .foreground ? .background : .foreground)
        }
    }

    private func set(_ color: Swatch, for target: ToolColorTarget) {
        guard var state = states[target] else { return }
        state.sync(color)
        commit(state, to: target)
    }

    private func commit(_ state: ColorSliderState, to target: ToolColorTarget) {
        states[target] = state
        tools[keyPath: target.keyPath] = state.color.color
        // The observer sees the same components and keeps the state, so
        // a hue kept for a gray survives the round trip.
        tools.notifyChange()
        refresh()
    }

    private func toolsChanged() {
        for target in ToolColorTarget.allCases {
            states[target]?.sync(Self.swatch(tools[keyPath: target.keyPath]))
        }
        refresh()
    }

    @objc private func targetChanged(_ sender: NSSegmentedControl) {
        select(sender.selectedSegment == 1 ? .background : .foreground)
    }

    @objc private func modeChosen(_ sender: NSMenuItem) {
        guard ColorSliderMode.allCases.indices.contains(sender.tag) else { return }
        setMode(ColorSliderMode.allCases[sender.tag])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        // The palette shows whole units, as Photoshop's does.
        setChannel(sender.tag, to: sender.doubleValue.rounded())
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let value = Double(text), setChannel(sender.tag, to: value) { return }
        NSSound.beep()
        refresh()
    }

    private func refresh() {
        guard isViewLoaded, let state = states[target] else { return }
        targetControl.selectedSegment = target == .foreground ? 0 : 1
        pair.foreground = tools.foreground
        pair.background = tools.background
        pair.active = target

        let channels = mode.channels
        let values = state.values(mode)
        for index in rows.indices {
            guard channels.indices.contains(index) else {
                rows[index].isHidden = true
                continue
            }
            let channel = channels[index]
            rows[index].isHidden = false
            labels[index].stringValue = channel.label
            units[index].stringValue = channel.unit
            sliders[index].maxValue = channel.maximum
            sliders[index].doubleValue = values[index]
            sliders[index].setAccessibilityLabel("\(target.title) \(channel.name)")
            fields[index].setAccessibilityLabel("\(target.title) \(channel.name) value")
            // Also when the field has focus: refresh runs only when the
            // color, target or mode changes, never while a value is typed.
            fields[index].stringValue = String(Int(values[index].rounded()))
        }
    }

    private static func swatch(_ color: NSColor) -> Swatch {
        Swatch(color) ?? Swatch(red: 0, green: 0, blue: 0)
    }
}
