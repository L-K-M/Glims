import AppKit
import RigiUI

/// What a click in the swatch grid does, from its modifiers, as in
/// Photoshop's Swatches palette.
enum SwatchClick: Equatable {
    case chooseForeground(Int)
    case chooseBackground(Int)
    case replace(Int)
    case delete(Int)
    case addForeground
    case none

    /// `index` is the swatch under the pointer, or nil for empty space.
    static func action(index: Int?, flags: NSEvent.ModifierFlags) -> SwatchClick {
        let flags = flags.intersection([.shift, .option, .command, .control])
        guard let index else { return flags.isEmpty ? .addForeground : .none }
        switch flags {
        case []: return .chooseForeground(index)
        case [.option]: return .chooseBackground(index)
        case [.shift]: return .replace(index)
        case [.command]: return .delete(index)
        default: return .none
        }
    }
}

/// The swatch grid: equal cells in rows that wrap to the view's width.
/// Each swatch is an accessibility button, so VoiceOver and Full
/// Keyboard Access users can choose colors without a pointer.
final class SwatchGridView: NSView, NSViewToolTipOwner {
    static let cell: CGFloat = 14
    static let gap: CGFloat = 2
    private static var pitch: CGFloat { cell + gap }

    var swatches: [Swatch] = [] {
        didSet {
            guard swatches != oldValue else { return }
            invalidateIntrinsicContentSize()
            rebuildAccessibility()
            needsDisplay = true
        }
    }
    var onClick: ((SwatchClick) -> Void)?

    override var isFlipped: Bool { true }

    private var columns: Int { max(1, Int((bounds.width + Self.gap) / Self.pitch)) }

    /// Rows for every swatch plus the empty cell that adds one.
    override var intrinsicContentSize: NSSize {
        let rows = (swatches.count + columns) / columns
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * Self.pitch)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = columns
        super.setFrameSize(newSize)
        if columns != before {
            invalidateIntrinsicContentSize()
            rebuildAccessibility()
        }
    }

    func rect(at index: Int) -> NSRect {
        NSRect(x: CGFloat(index % columns) * Self.pitch, y: CGFloat(index / columns) * Self.pitch,
               width: Self.cell, height: Self.cell)
    }

    /// The swatch under `point` (view coordinates), or nil.
    func index(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / Self.pitch), row = Int(point.y / Self.pitch)
        guard column < columns else { return nil }
        let index = row * columns + column
        guard swatches.indices.contains(index), rect(at: index).contains(point) else { return nil }
        return index
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, swatch) in swatches.enumerated() {
            let cell = rect(at: index)
            guard cell.intersects(dirtyRect) else { continue }
            swatch.color.setFill()
            cell.fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?(SwatchClick.action(index: index(at: point), flags: event.modifierFlags))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        for index in swatches.indices {
            addToolTip(rect(at: index), owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map { swatches[$0].hex } ?? ""
    }

    private var swatchElements: [NSAccessibilityElement] = []

    private func rebuildAccessibility() {
        swatchElements = swatches.indices.map { index in
            let element = SwatchAccessibilityElement(grid: self, index: index)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Swatch \(index + 1), \(swatches[index].hex)")
            element.setAccessibilityParent(self)
            return element
        }
        window?.invalidateCursorRects(for: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Swatches" }
    override func accessibilityChildren() -> [Any]? { swatchElements }

    fileprivate func accessibilityFrame(of index: Int) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect(at: index), to: nil))
    }
}

/// One swatch as an accessibility button: pressing it chooses the
/// foreground color, as a click does.
private final class SwatchAccessibilityElement: NSAccessibilityElement {
    private weak var grid: SwatchGridView?
    private let index: Int

    init(grid: SwatchGridView, index: Int) {
        self.grid = grid
        self.index = index
        super.init()
    }

    override func accessibilityFrame() -> NSRect { grid?.accessibilityFrame(of: index) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard let grid, grid.swatches.indices.contains(index) else { return false }
        grid.onClick?(.chooseForeground(index))
        return true
    }
}

/// Window ▸ Swatches: Photoshop's Swatches palette. Click a swatch for
/// the foreground color and Option-click for the background; click the
/// empty space after the last swatch to add the foreground color,
/// Shift-click to replace a swatch with it and Command-click to delete
/// one. The swatches are app-wide and persist; they never change an
/// image, so the palette ignores its target.
@MainActor
final class SwatchesPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.swatches"), title: "Swatches",
        contentSize: NSSize(width: 240, height: 170),
        sizing: .resizable(minimumContentSize: NSSize(width: 160, height: 110)),
        frameAutosaveName: "Glims.palette.swatches")

    let grid = SwatchGridView()
    private let store: SwatchStore
    private let tools: ToolState
    private var storeObserver: UUID?

    /// nil means the shared store and tool state.
    init(store: SwatchStore? = nil, tools: ToolState? = nil) {
        self.store = store ?? .shared
        self.tools = tools ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let storeObserver {
            MainActor.assumeIsolated { store.removeObserver(storeObserver) }
        }
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])

        let hint = NSTextField(wrappingLabelWithString:
            "Click: foreground. Option-click: background. Click empty space to add the foreground; "
            + "Shift-click replaces, Command-click deletes.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8),
        ])
        view = stack

        grid.swatches = store.list.swatches
        grid.onClick = { [weak self] click in self?.perform(click) }
        storeObserver = store.observe { [weak self] in
            guard let self else { return }
            self.grid.swatches = self.store.list.swatches
        }
    }

    func retarget(to target: ImageDocument?) {}

    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Swatches")
        let add = NSMenuItem(title: "Add Foreground Color", action: #selector(addForeground(_:)), keyEquivalent: "")
        let reset = NSMenuItem(title: "Reset Swatches", action: #selector(resetSwatches(_:)), keyEquivalent: "")
        for item in [add, reset] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc func addForeground(_ sender: Any?) { perform(.addForeground) }

    @objc func resetSwatches(_ sender: Any?) { store.update { $0.reset(); return true } }

    /// Applies a grid click. Choosing a color changes only the tool
    /// colors; the other clicks edit the stored swatches.
    func perform(_ click: SwatchClick) {
        let swatches = store.list.swatches
        switch click {
        case .chooseForeground(let index) where swatches.indices.contains(index):
            tools.foreground = swatches[index].color
            tools.notifyChange()
        case .chooseBackground(let index) where swatches.indices.contains(index):
            tools.background = swatches[index].color
            tools.notifyChange()
        case .replace(let index):
            guard let swatch = Swatch(tools.foreground) else { return NSSound.beep() }
            store.update { $0.replace(at: index, with: swatch) }
        case .delete(let index):
            store.update { $0.remove(at: index) }
        case .addForeground:
            guard let swatch = Swatch(tools.foreground), store.update({ $0.add(swatch) }) else { return NSSound.beep() }
        default:
            break
        }
    }
}

/// A flipped document view, so the grid starts at the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
