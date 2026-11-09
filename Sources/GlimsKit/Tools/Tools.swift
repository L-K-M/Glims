import AppKit

/// The editor's tools and their arrangement in the Tools palette
/// (docs/design.md, section 2): two columns, related tools grouped behind
/// one cell, a single-letter shortcut per group (Shift-letter cycles).
enum ToolID: String, CaseIterable {
    case move, transform, crop
    case rectangleSelect, ellipseSelect, lasso
    case magicWand, selectByColor
    case eyedropper, text, path
    case paintbrush, pencil, airbrush
    case eraser
    case clone, heal
    case smudge, blur, sharpen
    case dodge, burn
    case gradient, bucketFill
    case hand, zoom

    var name: String {
        switch self {
        case .move: return "Move"
        case .transform: return "Transform"
        case .crop: return "Crop"
        case .gradient: return "Gradient"
        case .bucketFill: return "Paint Bucket"
        case .rectangleSelect: return "Rectangle Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso"
        case .magicWand: return "Magic Wand"
        case .selectByColor: return "Select by Color"
        case .eyedropper: return "Eyedropper"
        case .text: return "Text"
        case .path: return "Path"
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
        case .move, .transform: return "V"
        case .crop: return "C"
        case .gradient, .bucketFill: return "G"
        case .rectangleSelect, .ellipseSelect: return "M"
        case .lasso: return "L"
        case .magicWand, .selectByColor: return "W"
        case .eyedropper: return "I"
        case .text: return "T"
        case .path: return "P"
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
        case .move: return ["arrow.up.and.down.and.arrow.left.and.right", "move.3d"]
        case .transform: return ["arrow.up.left.and.arrow.down.right", "rotate.right"]
        case .crop: return ["crop"]
        case .gradient: return ["square.lefthalf.filled", "circle.lefthalf.filled"]
        case .bucketFill: return ["drop.fill", "paintbrush.fill"]
        case .rectangleSelect: return ["rectangle.dashed"]
        case .ellipseSelect: return ["circle.dashed"]
        case .lasso: return ["lasso"]
        case .magicWand: return ["wand.and.stars"]
        case .selectByColor: return ["paintpalette", "drop.triangle"]
        case .eyedropper: return ["eyedropper"]
        case .text: return ["textformat", "character"]
        case .path: return ["point.topleft.down.to.point.bottomright.curvepath", "scribble"]
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
        [.rectangleSelect, .ellipseSelect], [.move, .transform],
        [.lasso], [.crop],
        [.magicWand, .selectByColor], [.eyedropper],
        [.paintbrush, .pencil, .airbrush], [.eraser],
        [.clone, .heal], [.smudge, .blur, .sharpen],
        [.dodge, .burn], [.gradient, .bucketFill],
        [.text], [.path],
        [.hand], [.zoom],
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

    /// Where the per-tool brush identities persist; tests inject a suite.
    var brushStore: BrushSelectionStore
    /// Where the gradient tool's preferences persist; tests inject a suite.
    var gradientStore: GradientToolStore

    private(set) var current: ToolID = .paintbrush
    /// The tool each group shows, so a shortcut returns to the last one used.
    private var lastInGroup: [Int: ToolID] = [:]

    /// Brush settings per painting tool; `brush(for:)` fills in the tool.
    private var brushes: [ToolID: EngineSession.Brush] = [:]

    init(brushStore: BrushSelectionStore = .shared, gradientStore: GradientToolStore = .shared) {
        self.brushStore = brushStore
        self.gradientStore = gradientStore
    }
    var selectOptions = EngineSession.SelectOptions()
    var foreground = NSColor.black
    var background = NSColor.white

    /// The gradient tool's live preferences, read through the store so an
    /// injected store (tests) takes effect immediately.
    private var gradientPrefs: GradientToolPreferences { gradientStore.preferences }
    /// The chosen gradient resource; nil is the Foreground-to-Background
    /// Default (the built-in persistent identity).
    var gradientResource: EngineSession.ResourceIdentity? { gradientPrefs.identity }
    var gradientShape: EngineSession.GradientShape {
        get { gradientPrefs.shape }
        set { updateGradientPrefs { $0.shape = newValue } }
    }
    var gradientReverse: Bool {
        get { gradientPrefs.reverse }
        set { updateGradientPrefs { $0.reverse = newValue } }
    }
    var gradientBlendSpace: EngineSession.GradientBlendSpace {
        get { gradientPrefs.blendSpace }
        set { updateGradientPrefs { $0.blendSpace = newValue } }
    }
    var gradientOpacity: Double {
        get { gradientPrefs.opacity }
        set { updateGradientPrefs { $0.opacity = newValue } }
    }
    var transformInterpolation = EngineSession.Interpolation.cubic
    /// How Stroke Path draws; its color is the foreground color.
    var pathLineWidth: Double = 2
    var pathLine: EngineSession.LineSettings {
        EngineSession.LineSettings(width: pathLineWidth, color: foreground)
    }
    /// How Fill Path fills; its color is the foreground color.
    var pathFillOpacity: Double = 1
    var pathFillAntialias = true
    var pathFill: EngineSession.PathFillSettings {
        EngineSession.PathFillSettings(color: foreground, opacity: pathFillOpacity,
                                        antialias: pathFillAntialias)
    }
    /// The look of the next text; its color is the foreground color.
    var textSettings = EngineSession.TextSettings()
    /// The fonts a person can pick, once the engine's have loaded (in the
    /// background, at the first document); see `setEngineFonts(_:)`.
    private(set) var fontNames: [String] = []

    /// Takes the engine's font list. It names some fonts twice and includes
    /// macOS's private fonts (names starting with "."), which font menus
    /// leave out. When the current text font is not among them, the first
    /// font takes its place.
    func setEngineFonts(_ names: [String]) {
        fontNames = Self.pickableFontNames(names)
        if let first = fontNames.first, !fontNames.contains(textSettings.font) {
            textSettings.font = first
        }
    }

    /// Each name once, in the engine's order, without private fonts.
    static func pickableFontNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.hasPrefix(".") && seen.insert($0).inserted }
    }
    /// Paint bucket: similar colors around the click, or the whole selection.
    var fillMode = EngineSession.FillMode.similarColors
    var fillThreshold: Double = 15.0 / 255.0
    var fillSampleMerged = false
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

    /// The stored brush of `tool`: an in-session edit if there is one,
    /// otherwise the default seeded with the persisted resource identity
    /// (restored after a restart; nil means the native default brush).
    private func baseBrush(for tool: ToolID) -> EngineSession.Brush {
        if let existing = brushes[tool] { return existing }
        var brush = Self.defaultBrush(for: tool)
        brush.resource = brushStore.identity(for: tool)
        return brush
    }

    func brush(for tool: ToolID) -> EngineSession.Brush {
        var brush = baseBrush(for: tool)
        if let paintTool = tool.paintTool { brush.tool = paintTool }
        let color = foreground.usingColorSpace(.sRGB) ?? .black
        brush.red = Double(color.redComponent)
        brush.green = Double(color.greenComponent)
        brush.blue = Double(color.blueComponent)
        brush.source = cloneSource
        return brush
    }

    func update(_ tool: ToolID, _ change: (inout EngineSession.Brush) -> Void) {
        var brush = baseBrush(for: tool)
        change(&brush)
        brushes[tool] = brush
        notify()
    }

    /// Sets the tool's brush resource choice and persists its identity (nil
    /// resets to the native default brush). Only the identity crosses into
    /// UserDefaults — never a session `ResourceID`; the stroke resolves the
    /// identity fresh on the engine worker.
    func setBrushResource(_ identity: EngineSession.ResourceIdentity?, for tool: ToolID) {
        brushStore.set(identity, for: tool)
        update(tool) { $0.resource = identity }
    }

    /// Sets the gradient resource choice and persists it (nil resets to the
    /// Foreground-to-Background Default). Only the identity plus the tool's
    /// own primitive settings cross into UserDefaults — never a session
    /// `ResourceID`, a rendered image or the FG/BG colors; the gesture
    /// resolves the identity fresh on the engine worker.
    func setGradientResource(_ identity: EngineSession.ResourceIdentity?) {
        updateGradientPrefs { $0.identity = identity }
    }

    /// Compare-and-swap stored references, then reconcile only cached brushes
    /// still carrying the old choice. A newer persisted choice wins.
    func migrateResourceIdentity(kind: EngineSession.ResourceKind,
                                 from old: EngineSession.ResourceIdentity,
                                 to new: EngineSession.ResourceIdentity) throws {
        switch kind {
        case .brush:
            _ = try brushStore.migrateIdentity(from: old, to: new)
            for tool in Array(brushes.keys) where brushes[tool]?.resource == old {
                brushes[tool]?.resource = brushStore.identity(for: tool)
            }
        case .gradient: _ = try gradientStore.migrateIdentity(from: old, to: new)
        case .pattern: break
        }
        notify()
    }

    /// Captures one canvas gradient gesture as pure values: the identity
    /// (the choice, or the built-in Foreground-to-Background identity for
    /// the Default), shape, reverse, blend space, opacity, the global
    /// foreground/background colors as an opaque per-gesture snapshot, and
    /// the endpoints. Later UI, tool, preference or color changes cannot
    /// redirect the queued work from this snapshot.
    func gradientSnapshot(from: CGPoint, to: CGPoint) -> GradientGestureSnapshot {
        let prefs = gradientPrefs
        return GradientGestureSnapshot.capture(identity: prefs.identity, shape: prefs.shape,
                                               reverse: prefs.reverse, blendSpace: prefs.blendSpace,
                                               opacity: prefs.opacity,
                                               foreground: foreground, background: background,
                                               from: from, to: to)
    }

    private func updateGradientPrefs(_ change: (inout GradientToolPreferences) -> Void) {
        var prefs = gradientPrefs
        change(&prefs)
        gradientStore.set(prefs)
        notify()
    }

    func notifyChange() { notify() }

    /// X: the foreground and background colors trade places.
    func swapColors() {
        (foreground, background) = (background, foreground)
        notify()
    }

    /// D: black on white.
    func resetColors() {
        foreground = .black
        background = .white
        notify()
    }

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
