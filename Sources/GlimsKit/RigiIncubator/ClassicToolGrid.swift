import AppKit
import RigiUI

// Incubating Rigi code. This file is generic — AppKit and RigiUI only, no
// Glims or engine types — because it belongs in Rigi's RigiUI module once it
// proves itself in the app; the move is a file copy minus `import RigiUI`.

/// The pure geometry and per-slot "which tool is shown" logic behind
/// ClassicToolGrid, kept in a value type so tests exercise it without a
/// window. Frames use a top-left origin (the control is flipped): slot 0 is
/// the top-left cell and slots fill rows left to right.
public struct ClassicToolGridLayout {

    /// Columns per row; clamped to at least 1.
    public var columns: Int { didSet { columns = max(1, columns) } }
    public var cellSize: CGSize
    public var gap: CGFloat

    /// One entry per slot: the tool the slot currently shows — a group's last
    /// pick, defaulting to its first tool.
    public private(set) var currentToolIndexes: [Int] = []

    public init(columns: Int = 2,
                cellSize: CGSize = ClassicToolGrid.cellSize,
                gap: CGFloat = ClassicToolGrid.cellGap) {
        self.columns = max(1, columns)
        self.cellSize = cellSize
        self.gap = gap
    }

    /// Rows needed for `slotCount` slots in `columns` columns.
    public func rowCount(forSlotCount slotCount: Int) -> Int {
        guard slotCount > 0 else { return 0 }
        return (slotCount + columns - 1) / columns
    }

    /// The grid's intrinsic size for `slotCount` slots.
    public func size(forSlotCount slotCount: Int) -> CGSize {
        let rows = rowCount(forSlotCount: slotCount)
        guard rows > 0 else { return .zero }
        return CGSize(width: CGFloat(columns) * cellSize.width + CGFloat(columns - 1) * gap,
                      height: CGFloat(rows) * cellSize.height + CGFloat(rows - 1) * gap)
    }

    /// The cell rect of slot `index` in the grid's coordinate space.
    public func frame(forSlot index: Int) -> CGRect {
        let column = index % columns, row = index / columns
        return CGRect(x: CGFloat(column) * (cellSize.width + gap),
                      y: CGFloat(row) * (cellSize.height + gap),
                      width: cellSize.width, height: cellSize.height)
    }

    /// The slot whose cell contains `point`, or nil in a gap or outside the
    /// grid. Cells are half-open: a point on a cell's right or bottom edge
    /// lands in the gap after it.
    public func hitTest(_ point: CGPoint, slotCount: Int) -> Int? {
        let strideX = cellSize.width + gap, strideY = cellSize.height + gap
        guard strideX > 0, strideY > 0 else { return nil }
        let size = size(forSlotCount: slotCount)
        guard point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height else { return nil }
        let column = Int(point.x / strideX), row = Int(point.y / strideY)
        guard point.x - CGFloat(column) * strideX < cellSize.width,
              point.y - CGFloat(row) * strideY < cellSize.height else { return nil }
        let index = row * columns + column
        return index < slotCount ? index : nil
    }

    /// Keeps one current-tool index per slot; call when the slot list changes.
    /// Surviving slots keep their current tool.
    public mutating func setSlotCount(_ count: Int) {
        currentToolIndexes = (0..<max(0, count)).map {
            currentToolIndexes.indices.contains($0) ? currentToolIndexes[$0] : 0
        }
    }

    /// Which tool slot `slot` shows; an out-of-range slot reports 0.
    public func currentToolIndex(forSlot slot: Int) -> Int {
        currentToolIndexes.indices.contains(slot) ? currentToolIndexes[slot] : 0
    }

    public mutating func setCurrentTool(_ toolIndex: Int, forSlot slot: Int) {
        guard currentToolIndexes.indices.contains(slot) else { return }
        currentToolIndexes[slot] = toolIndex
    }

    /// The tool index a cycle forward from slot `slot` lands on.
    public func nextToolIndex(forSlot slot: Int, toolCount: Int) -> Int {
        guard toolCount > 0 else { return 0 }
        return (currentToolIndex(forSlot: slot) + 1) % toolCount
    }

    /// Cycles slot `slot`'s current tool forward, wrapping, and returns the
    /// new index.
    @discardableResult
    public mutating func cycleTool(forSlot slot: Int, toolCount: Int) -> Int {
        let next = nextToolIndex(forSlot: slot, toolCount: toolCount)
        setCurrentTool(next, forSlot: slot)
        return next
    }
}

/// A grid of classic-bezel tool cells: the tool palette. Each cell shows one
/// tool; a slot holding several tools is a *group* and draws a small corner
/// triangle. Click picks the slot's current tool; press-and-hold or drag on a
/// group opens a flyout of its tools; Option-click a group cycles it.
///
/// Tool ids are unique across the grid — `selectTool(id:)` looks a tool up by
/// id, not by slot and index. Selection is radio-style: `selectedToolID`
/// names one tool, and every user pick (click, flyout choice, Option-click,
/// VoiceOver press) reports the action to the target exactly once.
public final class ClassicToolGrid: NSControl, NSViewToolTipOwner {

    /// One tool in the palette. `name` feeds tool tips, the flyout and
    /// VoiceOver; `shortcut` is the key that picks the tool from the
    /// keyboard, shown as the "(B)" hint. Template images draw tinted in the
    /// chrome's glyph gray.
    public struct Tool {
        public let id: String
        public let name: String
        public let shortcut: String?
        public let image: NSImage

        public init(id: String, name: String, shortcut: String? = nil, image: NSImage) {
            self.id = id
            self.name = name
            self.shortcut = shortcut
            self.image = image
        }
    }

    /// One cell of the grid; a slot holding more than one tool is a group.
    public struct Slot {
        public var tools: [Tool]
        public init(tools: [Tool]) { self.tools = tools }
        public var isGroup: Bool { tools.count > 1 }
    }

    public static let cellSize = CGSize(width: 24, height: 24)
    public static let cellGap: CGFloat = 1
    private static let iconSize: CGFloat = 16
    private static let flyoutHoldDelay: TimeInterval = 0.3

    /// The palette's slots in row-major order; setting replaces every cell.
    public var slots: [Slot] = [] {
        didSet { syncAfterModelChange() }
    }

    /// Columns per row; the grid is always at least one column wide.
    public var columns: Int {
        get { gridLayout.columns }
        set {
            gridLayout.columns = newValue
            syncAfterModelChange()
        }
    }

    /// The selected tool's id, or nil. Setting only marks the selection;
    /// `selectTool(id:)` also makes the tool its slot's current tool.
    public var selectedToolID: String? {
        didSet {
            needsDisplay = true
            syncAccessibility()
        }
    }

    private var gridLayout = ClassicToolGridLayout()
    private var pressedSlot: Int?
    private var flyoutSlot: Int?
    private var toolTipTags: [NSView.ToolTipTag: Int] = [:]
    private var accessibilityCells: [CellAccessibilityElement] = []

    public init(slots: [Slot] = [], columns: Int = 2) {
        super.init(frame: .zero)
        gridLayout.columns = columns
        self.slots = slots              // didSet does not fire during init
        syncAfterModelChange()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        gridLayout.size(forSlotCount: slots.count)
    }

    public override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Selection

    /// Selects `id` without sending the action — the keyboard path, or
    /// reflecting a selection the app already made. The tool also becomes its
    /// slot's current tool.
    public func selectTool(id: String) {
        guard let slot = slotIndex(containing: id),
              let tool = toolIndex(id, inSlot: slot) else { return }
        select(tool, inSlot: slot, sendsAction: false)
    }

    /// Advances the group containing `id` to its next tool (wrapping) and
    /// selects it, without sending the action — Option-click sends it itself.
    public func cycleGroup(containing id: String) {
        guard let slot = slotIndex(containing: id) else { return }
        cycleTool(inSlot: slot, sendsAction: false)
    }

    /// The tool a slot currently shows.
    func currentTool(inSlot slot: Int) -> Tool? {
        guard slots.indices.contains(slot) else { return nil }
        let tools = slots[slot].tools
        let index = gridLayout.currentToolIndex(forSlot: slot)
        return tools.indices.contains(index) ? tools[index] : tools.first
    }

    /// The single commit every user pick funnels through — click, flyout
    /// choice and Option-click alike — so the action goes out exactly once.
    /// The tool becomes its slot's current tool and the grid's selection.
    func select(_ toolIndex: Int, inSlot slot: Int, sendsAction: Bool) {
        guard slots.indices.contains(slot),
              slots[slot].tools.indices.contains(toolIndex) else { return }
        gridLayout.setCurrentTool(toolIndex, forSlot: slot)
        selectedToolID = slots[slot].tools[toolIndex].id
        needsDisplay = true
        syncAccessibility()
        if sendsAction { sendAction(action, to: target) }
    }

    func selectCurrentTool(inSlot slot: Int, sendsAction: Bool) {
        select(gridLayout.currentToolIndex(forSlot: slot), inSlot: slot, sendsAction: sendsAction)
    }

    func cycleTool(inSlot slot: Int, sendsAction: Bool) {
        guard slots.indices.contains(slot) else { return }
        select(gridLayout.nextToolIndex(forSlot: slot, toolCount: slots[slot].tools.count),
               inSlot: slot, sendsAction: sendsAction)
    }

    private func slotIndex(containing id: String) -> Int? {
        slots.firstIndex { $0.tools.contains { $0.id == id } }
    }

    private func toolIndex(_ id: String, inSlot slot: Int) -> Int? {
        slots.indices.contains(slot) ? slots[slot].tools.firstIndex { $0.id == id } : nil
    }

    // MARK: Tracking

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled, let slot = slotIndex(for: event) else { return }
        // Option-click on a group cycles it: an instant pick, no press.
        if event.modifierFlags.contains(.option), slots[slot].isGroup {
            cycleTool(inSlot: slot, sendsAction: true)
            return
        }
        pressedSlot = slot
        needsDisplay = true
        if slots[slot].isGroup {
            perform(#selector(holdElapsed), with: nil, afterDelay: Self.flyoutHoldDelay)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let slot = pressedSlot,
              slots.indices.contains(slot), slots[slot].isGroup else { return }
        cancelHold()
        openFlyout(for: slot)
    }

    public override func mouseUp(with event: NSEvent) {
        cancelHold()
        defer {
            pressedSlot = nil
            needsDisplay = true
        }
        guard let slot = pressedSlot, slotIndex(for: event) == slot else { return }
        selectCurrentTool(inSlot: slot, sendsAction: true)
    }

    private func slotIndex(for event: NSEvent) -> Int? {
        gridLayout.hitTest(convert(event.locationInWindow, from: nil), slotCount: slots.count)
    }

    // MARK: Flyout

    @objc private func holdElapsed() {
        guard let slot = pressedSlot,
              slots.indices.contains(slot), slots[slot].isGroup else { return }
        openFlyout(for: slot)
    }

    private func cancelHold() {
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(holdElapsed), object: nil)
    }

    /// Runs the group's flyout under the cell; blocks until a choice or a
    /// dismissal. The cell stays pressed while the menu is up, and the menu
    /// tracks the still-held button so hold-and-slide and drag both work.
    private func openFlyout(for slot: Int) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, tool) in slots[slot].tools.enumerated() {
            let item = NSMenuItem(title: tool.name,
                                  action: #selector(flyoutItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = flyoutImage(for: tool)
            if index == gridLayout.currentToolIndex(forSlot: slot) { item.state = .on }
            if let shortcut = tool.shortcut {
                // Single letters become real key equivalents; anything longer
                // still shows as a "(…)" hint appended to the title.
                if shortcut.count == 1 { item.keyEquivalent = shortcut.lowercased() }
                else { item.title += "  (\(shortcut))" }
            }
            menu.addItem(item)
        }
        flyoutSlot = slot
        let cell = gridLayout.frame(forSlot: slot)
        _ = menu.popUp(positioning: nil, at: NSPoint(x: cell.minX, y: cell.maxY + 1), in: self)
        flyoutSlot = nil
        pressedSlot = nil
        needsDisplay = true
    }

    @objc private func flyoutItemChosen(_ sender: NSMenuItem) {
        guard let slot = flyoutSlot else { return }
        select(sender.tag, inSlot: slot, sendsAction: true)
    }

    private func flyoutImage(for tool: Tool) -> NSImage? {
        guard let copy = tool.image.copy() as? NSImage else { return tool.image }
        copy.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        return copy
    }

    // MARK: Tool tips

    /// A tip per cell, rebuilt when geometry changes; the text resolves at
    /// display time so it always names the slot's current tool.
    private func rebuildToolTips() {
        removeAllToolTips()
        toolTipTags.removeAll()
        for slot in slots.indices {
            let tag = addToolTip(gridLayout.frame(forSlot: slot), owner: self, userData: nil)
            toolTipTags[tag] = slot
        }
    }

    @MainActor
    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                     point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let slot = toolTipTags[tag], let tool = currentTool(inSlot: slot) else { return "" }
        guard let shortcut = tool.shortcut else { return tool.name }
        return "\(tool.name) (\(shortcut))"
    }

    public override func layout() {
        super.layout()
        rebuildToolTips()
        syncAccessibility()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        rebuildToolTips()
        syncAccessibility()
    }

    private func syncAfterModelChange() {
        gridLayout.setSlotCount(slots.count)
        invalidateIntrinsicContentSize()
        rebuildToolTips()
        syncAccessibility()
        needsDisplay = true
    }

    // MARK: Accessibility

    /// One cell of the grid for VoiceOver: a radio button reporting the shown
    /// tool, whose press selects it like a click.
    private final class CellAccessibilityElement: NSAccessibilityElement {
        var onPress: (() -> Void)?

        // A VoiceOver press is a user pick, like a click on the cell.
        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return true
        }
    }

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }

    public override func accessibilityChildren() -> [Any]? { accessibilityCells }

    /// Keeps one element per slot — rebuilt only when the count changes so
    /// element identity stays stable — and resyncs each cell's frame, label
    /// and value with the model.
    private func syncAccessibility() {
        if accessibilityCells.count != slots.count {
            accessibilityCells = slots.indices.map { slot in
                let element = CellAccessibilityElement()
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.radioButton)
                element.onPress = { [weak self] in self?.selectCurrentTool(inSlot: slot, sendsAction: true) }
                return element
            }
        }
        for (slot, element) in accessibilityCells.enumerated() {
            element.setAccessibilityFrameInParentSpace(gridLayout.frame(forSlot: slot))
            let tool = currentTool(inSlot: slot)
            element.setAccessibilityLabel(tool?.name ?? "")
            element.setAccessibilityValue(NSNumber(value: tool != nil && tool?.id == selectedToolID))
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let active = ClassicChrome.active(for: self) && isEnabled
        for slot in slots.indices {
            let rect = gridLayout.frame(forSlot: slot)
            guard rect.intersects(dirtyRect) else { continue }
            drawCell(slot, in: rect, active: active)
        }
    }

    private func drawCell(_ slot: Int, in rect: CGRect, active: Bool) {
        let tool = currentTool(inSlot: slot)
        let state: ClassicChrome.BezelState = pressedSlot == slot ? .pressed
            : (tool?.id == selectedToolID ? .on : .normal)

        let outline = ClassicChrome.bezelOutline(in: rect, radius: 3)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        ClassicChrome.bezelGradient(state, active: active).draw(in: rect, angle: 90)
        ClassicChrome.drawInnerHint(state, in: rect, active: active)
        NSGraphicsContext.restoreGraphicsState()
        ClassicChrome.bezelBorder(active).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        if let tool { drawImage(tool.image, centeredIn: rect, active: active) }
        if slots[slot].isGroup { drawGroupTriangle(in: rect, active: active) }
    }

    /// The 16 pt icon centered in the cell; template images take the chrome's
    /// glyph gray. The tint is applied to a copy of the image, so it never
    /// touches the bezel behind the icon.
    private func drawImage(_ image: NSImage, centeredIn rect: CGRect, active: Bool) {
        let side = Self.iconSize
        let icon = CGRect(x: (rect.midX - side / 2).rounded(),
                          y: (rect.midY - side / 2).rounded(),
                          width: side, height: side)
        let drawn = image.isTemplate ? Self.tinted(image, ClassicChrome.glyphColor(active)) : image
        drawn.draw(in: icon, from: .zero, operation: .sourceOver,
                   fraction: active || image.isTemplate ? 1 : 0.45, respectFlipped: true, hints: nil)
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { bounds in
            image.draw(in: bounds)
            color.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
    }

    /// The small solid triangle marking a group slot's bottom-right corner.
    private func drawGroupTriangle(in rect: CGRect, active: Bool) {
        ClassicChrome.arrowColor(active).setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: rect.maxX - 7, y: rect.maxY - 1))
        triangle.line(to: NSPoint(x: rect.maxX - 1, y: rect.maxY - 1))
        triangle.line(to: NSPoint(x: rect.maxX - 1, y: rect.maxY - 7))
        triangle.close()
        triangle.fill()
    }
}
