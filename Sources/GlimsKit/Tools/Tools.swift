import AppKit

/// The editor's tools and their arrangement in the Tools palette
/// (docs/design.md, section 2): two columns, related tools grouped behind
/// one cell, a single-letter shortcut per group (Shift-letter cycles).
enum ToolID: String, CaseIterable {
    case rectangleSelect, ellipseSelect, lasso
    case magicWand, selectByColor
    case eyedropper
    case paintbrush, pencil, airbrush
    case eraser
    case clone, heal
    case smudge, blur, sharpen
    case dodge, burn
    case hand, zoom

    var name: String {
        switch self {
        case .rectangleSelect: return "Rectangle Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso"
        case .magicWand: return "Magic Wand"
        case .selectByColor: return "Select by Color"
        case .eyedropper: return "Eyedropper"
        case .paintbrush: return "Brush"
        case .pencil: return "Pencil"
        case .airbrush: return "Airbrush"
        case .eraser: return "Eraser"
        case .clone: return "Clone"
        case .heal: return "Heal"
        case .smudge: return "Smudge"
        case .blur: return "Blur"
        case .sharpen: return "Sharpen"
        case .dodge: return "Dodge"
        case .burn: return "Burn"
        case .hand: return "Hand"
        case .zoom: return "Zoom"
        }
    }

    /// The key that picks the tool's group; repeated with Shift it cycles.
    var shortcut: String {
        switch self {
        case .rectangleSelect, .ellipseSelect: return "M"
        case .lasso: return "L"
        case .magicWand, .selectByColor: return "W"
        case .eyedropper: return "I"
        case .paintbrush, .pencil, .airbrush: return "B"
        case .eraser: return "E"
        case .clone, .heal: return "S"
        case .smudge, .blur, .sharpen: return "R"
        case .dodge, .burn: return "O"
        case .hand: return "H"
        case .zoom: return "Z"
        }
    }

    /// SF Symbols names, first available wins; a letter otherwise.
    private var symbolNames: [String] {
        switch self {
        case .rectangleSelect: return ["rectangle.dashed"]
        case .ellipseSelect: return ["circle.dashed"]
        case .lasso: return ["lasso"]
        case .magicWand: return ["wand.and.stars"]
        case .selectByColor: return ["paintpalette", "drop.triangle"]
        case .eyedropper: return ["eyedropper"]
        case .paintbrush: return ["paintbrush.pointed", "paintbrush"]
        case .pencil: return ["pencil"]
        case .airbrush: return ["aqi.medium", "sparkles"]
        case .eraser: return ["eraser", "eraser.line.dashed"]
        case .clone: return ["plus.square.on.square"]
        case .heal: return ["bandage"]
        case .smudge: return ["hand.point.up.left"]
        case .blur: return ["drop"]
        case .sharpen: return ["triangle"]
        case .dodge: return ["sun.max"]
        case .burn: return ["flame"]
        case .hand: return ["hand.raised"]
        case .zoom: return ["magnifyingglass"]
        }
    }

    var image: NSImage {
        for name in symbolNames {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: self.name) {
                image.isTemplate = true
                return image
            }
        }
        return Self.letterImage(String(name.prefix(1)))
    }

    private static func letterImage(_ letter: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The engine paint tool behind a painting tool, or nil.
    var paintTool: EngineSession.Brush.Tool? {
        switch self {
        case .paintbrush: return .paintbrush
        case .pencil: return .pencil
        case .airbrush: return .airbrush
        case .eraser: return .eraser
        case .clone: return .clone
        case .heal: return .heal
        case .smudge: return .smudge
        case .blur: return .blur
        case .sharpen: return .sharpen
        case .dodge: return .dodge
        case .burn: return .burn
        default: return nil
        }
    }

    var isSelectionTool: Bool {
        [.rectangleSelect, .ellipseSelect, .lasso, .magicWand, .selectByColor].contains(self)
    }

    /// The palette's cells, row by row; a cell with several tools is a group.
    static let paletteSlots: [[ToolID]] = [
        [.rectangleSelect, .ellipseSelect], [.lasso],
        [.magicWand, .selectByColor], [.eyedropper],
        [.paintbrush, .pencil, .airbrush], [.eraser],
        [.clone, .heal], [.smudge, .blur, .sharpen],
        [.dodge, .burn], [.hand],
        [.zoom],
    ]

    /// The group a shortcut letter picks.
    static func group(forShortcut key: String) -> [ToolID]? {
        paletteSlots.first { $0.first?.shortcut.caseInsensitiveCompare(key) == .orderedSame }
    }
}

/// The current tool and every tool's settings, shared by the Tools and Tool
/// Options palettes and the canvas. One per app, like GIMP's user context.
@MainActor
final class ToolState {
    static let shared = ToolState()

    private(set) var current: ToolID = .paintbrush
    /// The tool each group shows, so a shortcut returns to the last one used.
    private var lastInGroup: [Int: ToolID] = [:]

    /// Brush settings per painting tool; `brush(for:)` fills in the tool.
    private var brushes: [ToolID: EngineSession.Brush] = [:]
    var selectOptions = EngineSession.SelectOptions()
    var foreground = NSColor.black
    /// Where clone and heal copy from; set with Option-click on the canvas.
    var cloneSource: EngineSession.Brush.Source?

    private var observers: [UUID: () -> Void] = [:]

    func select(_ tool: ToolID) {
        current = tool
        if let index = ToolID.paletteSlots.firstIndex(where: { $0.contains(tool) }) {
            lastInGroup[index] = tool
        }
        notify()
    }

    /// The shortcut letter's tool: the group's last-used tool, or with
    /// `cycle` the next one in the group.
    func select(shortcut key: String, cycle: Bool) {
        guard let group = ToolID.group(forShortcut: key),
              let index = ToolID.paletteSlots.firstIndex(of: group) else { return }
        let last = lastInGroup[index] ?? group[0]
        if cycle, group.contains(current), let position = group.firstIndex(of: current) {
            select(group[(position + 1) % group.count])
        } else {
            select(last)
        }
    }

    func brush(for tool: ToolID) -> EngineSession.Brush {
        var brush = brushes[tool] ?? Self.defaultBrush(for: tool)
        if let paintTool = tool.paintTool { brush.tool = paintTool }
        let color = foreground.usingColorSpace(.sRGB) ?? .black
        brush.red = Double(color.redComponent)
        brush.green = Double(color.greenComponent)
        brush.blue = Double(color.blueComponent)
        brush.source = cloneSource
        return brush
    }

    func update(_ tool: ToolID, _ change: (inout EngineSession.Brush) -> Void) {
        var brush = brushes[tool] ?? Self.defaultBrush(for: tool)
        change(&brush)
        brushes[tool] = brush
        notify()
    }

    func notifyChange() { notify() }

    private static func defaultBrush(for tool: ToolID) -> EngineSession.Brush {
        var brush = EngineSession.Brush()
        switch tool {
        case .pencil: brush.size = 3
        case .eraser: brush.size = 20
        case .clone, .heal: brush.size = 20
        case .smudge, .blur, .sharpen, .dodge, .burn: brush.size = 24
        case .airbrush: brush.size = 30
        default: break
        }
        return brush
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        observers.values.forEach { $0() }
    }
}
