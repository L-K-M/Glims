import AppKit

/// Pure decisions for the canvas keyboard model (docs/design.md, section 4),
/// plus the held-modifier state behind the temporary tools. Keeping the
/// decisions here lets them be tested without an engine, a window or a
/// document.
enum CanvasKeyboardPolicy {
    /// The Space bar's virtual key code.
    static let spaceKeyCode = 49
    /// Command and Option, left and right, whose key events track held state.
    static let commandKeyCodes: Set<Int> = [54, 55]
    static let optionKeyCodes: Set<Int> = [58, 61]

    /// Command and Option are temporary-tool modifiers; their own key events
    /// are consumed by the canvas and never reach the plain-key handling.
    static func isTemporaryModifierKey(keyCode: Int) -> Bool {
        commandKeyCodes.contains(keyCode) || optionKeyCodes.contains(keyCode)
    }

    /// Plain tool keys ignore Command, Control and Option, but Shift stays
    /// available (Shift-[ ], Shift-arrow, Shift-letter).
    static func allowsPlainKey(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option]).isEmpty
    }

    /// Digits 1-9 set 10-90% paint opacity; 0 sets 100%.
    static func paintOpacity(for key: String) -> Double? {
        guard key.count == 1, let digit = Int(key), (0...9).contains(digit) else { return nil }
        return digit == 0 ? 1 : Double(digit) / 10
    }

    /// The bracket keys, including the shifted brace characters a synthetic
    /// event may report as the unmodified character.
    static func isLeftBracket(_ key: String) -> Bool { key == "[" || key == "{" }
    static func isRightBracket(_ key: String) -> Bool { key == "]" || key == "}" }

    /// The hardness step for Shift-[ and Shift-]; 0.1 matches the Tool Options
    /// slider's 0-100 percent range.
    static let hardnessStep: Double = 0.1

    /// Shift-[ decreases hardness and Shift-] increases it; nil hardness is
    /// the engine's 0.5 default. The result stays within 0...1.
    static func hardness(_ hardness: Double?, increased: Bool) -> Double {
        let step = increased ? hardnessStep : -hardnessStep
        return min(1, max(0, (hardness ?? 0.5) + step))
    }

    /// Arrow keys and the direction each nudges. The canvas is flipped, so
    /// Up moves the layer towards negative image y.
    enum Arrow: String {
        case left, right, up, down

        init?(keyCode: Int) {
            switch keyCode {
            case 123: self = .left
            case 124: self = .right
            case 125: self = .down
            case 126: self = .up
            default: return nil
            }
        }

        var offset: CGSize {
            switch self {
            case .left: return CGSize(width: -1, height: 0)
            case .right: return CGSize(width: 1, height: 0)
            case .up: return CGSize(width: 0, height: -1)
            case .down: return CGSize(width: 0, height: 1)
            }
        }
    }

    /// Arrows nudge the active layer 1 px, Shift-arrow 10 px.
    static func nudge(_ arrow: Arrow, shift: Bool) -> CGSize {
        let offset = arrow.offset
        let step: CGFloat = shift ? 10 : 1
        return CGSize(width: offset.width * step, height: offset.height * step)
    }

    /// Only painting tools have opacity and brush settings to adjust.
    static func adjustsBrush(_ tool: ToolID) -> Bool { tool.paintTool != nil }

    /// Option with an ordinary paint tool samples the foreground color.
    /// Clone and heal keep their Option source behavior.
    static func optionSamplesForeground(_ tool: ToolID) -> Bool {
        guard let paint = tool.paintTool else { return false }
        return paint != .clone && paint != .heal
    }
}

/// Held temporary-tool modifiers (Space, Command, Option). The canvas
/// controller owns one and asks it which tool a pointer press uses.
struct CanvasKeyboardState {
    private(set) var spaceHeld = false
    private(set) var commandHeld = false
    private(set) var optionHeld = false

    mutating func keyDown(_ keyCode: Int) {
        if keyCode == CanvasKeyboardPolicy.spaceKeyCode { spaceHeld = true }
        if CanvasKeyboardPolicy.commandKeyCodes.contains(keyCode) { commandHeld = true }
        if CanvasKeyboardPolicy.optionKeyCodes.contains(keyCode) { optionHeld = true }
    }

    mutating func keyUp(_ keyCode: Int) {
        if keyCode == CanvasKeyboardPolicy.spaceKeyCode { spaceHeld = false }
        if CanvasKeyboardPolicy.commandKeyCodes.contains(keyCode) { commandHeld = false }
        if CanvasKeyboardPolicy.optionKeyCodes.contains(keyCode) { optionHeld = false }
    }

    /// Space is the temporary hand, Command moves the layer, otherwise the
    /// current tool. The pointer's own flags also count, so a press reports
    /// the modifier even when its key event went elsewhere.
    func pointerTool(current: ToolID, flags: NSEvent.ModifierFlags) -> ToolID {
        if spaceHeld { return .hand }
        if commandHeld || flags.contains(.command) { return .move }
        return current
    }

    func optionIsDown(flags: NSEvent.ModifierFlags) -> Bool {
        optionHeld || flags.contains(.option)
    }
}
