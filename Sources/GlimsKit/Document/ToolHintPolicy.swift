import AppKit

/// Frontend-only affordances. No engine readiness or mutable tool settings
/// are consulted here; a captured drag supplies its own tool and phase.
enum ToolHintPolicy {
    enum Phase: Equatable {
        case idle, dragging, textEditing, transformReady
        case cropReady(width: Int, height: Int)
    }
    enum Refresh: Equatable { case context, afterAction, stateChange }

    static func hint(tool: ToolID, phase: Phase, flags: NSEvent.ModifierFlags,
                     mode: EngineSession.ColorMode = .rgb) -> String {
        if mode.usesInkChannels {
            guard tool.isAvailable(in: mode) else {
                return "Choose a painting, selection, Hand or Zoom tool for this ink document."
            }
            if phase == .idle, tool.paintTool != nil {
                return flags.contains(.option)
                    ? "Release Option to paint the selected ink channel."
                    : "Paint the selected ink channel. Black adds ink; white removes it; [ ] changes size."
            }
        }
        switch phase {
        case .textEditing: return "Type text. Escape or clicking outside applies it."
        case .transformReady: return "Return applies the transform; Escape cancels it."
        case .cropReady(let width, let height):
            return "Return crops to \(width) × \(height) px; Escape cancels."
        default: break
        }
        if phase == .idle, tool.paintTool != nil, flags.contains(.option) {
            return tool == .clone || tool == .heal
                ? "Option-click to set the \(tool.name.lowercased()) source."
                : "Option-click or drag to sample the foreground color."
        }
        switch tool {
        case .rectangleSelect, .ellipseSelect:
            if phase == .dragging {
                let shape = tool == .rectangleSelect ? "rectangle" : "ellipse"
                let constrain = flags.contains(.shift) ? "Constrained \(shape)" : "Drag a \(shape)"
                let center = flags.contains(.option) ? " from its center" : ""
                return "\(constrain)\(center). Shift constrains; Option draws from the center."
            }
            return selection(tool == .rectangleSelect ? "rectangle" : "ellipse", flags: flags)
        case .lasso:
            return phase == .dragging ? "Trace the selection; release to finish. Escape cancels."
                : selection("freehand area", flags: flags)
        case .magicWand:
            return phase == .dragging ? "Release, then click to select connected colors." : selection("connected colors", flags: flags)
        case .selectByColor:
            return phase == .dragging ? "Release, then click to select matching colors." : selection("matching colors", flags: flags)
        case .move: return "Drag a layer or guide. Arrows nudge 1 px; Shift-arrows nudge 10 px."
        case .transform:
            return phase == .dragging && flags.contains(.shift)
                ? "Constrained transform. Release Shift for a free transform."
                : "Drag transform handles. Shift constrains."
        case .crop: return "Drag the area to keep."
        case .eyedropper: return "Click or drag to sample the foreground color."
        case .text: return "Click to add or edit text."
        case .path:
            if phase == .dragging { return "Drag an anchor or handle. Shift mirrors a dragged handle." }
            if flags.contains(.shift) { return "Shift-click toggles an anchor or starts a new subpath." }
            if flags.contains(.option) { return "Option-drag an anchor to pull out its handles." }
            return "Click to add an anchor; drag for handles. Shift-click selects or starts a subpath."
        case .spongeDesaturate, .spongeSaturate:
            return "Drag to change saturation on RGB pixels; Opacity sets strength; [ ] changes size."
        case .paintbrush, .pencil, .airbrush, .eraser, .smudge, .blur, .sharpen, .dodge, .burn:
            return phase == .dragging ? "Drag to apply \(tool.name.lowercased()); release to finish."
                : "Drag to apply \(tool.name.lowercased()). Option samples color; [ ] changes size."
        case .clone, .heal:
            return phase == .dragging ? "Drag to \(tool.name.lowercased()); release to finish."
                : "Option-click sets the \(tool.name.lowercased()) source; drag to paint."
        case .gradient: return "Drag the gradient endpoints; release to apply."
        case .bucketFill: return "Click to fill using the Paint Bucket options."
        case .hand: return "Drag to pan the view."
        case .zoom:
            return flags.contains(.option) ? "Click to zoom out. Release Option to zoom in."
                : "Click to zoom in. Option-click zooms out."
        }
    }

    private static func selection(_ subject: String, flags: NSEvent.ModifierFlags) -> String {
        let verb: String
        switch (flags.contains(.shift), flags.contains(.option)) {
        case (true, true): verb = "Intersect the selection with"
        case (true, false): verb = "Add to the selection with"
        case (false, true): verb = "Subtract from the selection with"
        default: verb = "Select"
        }
        return "\(verb) \(subject). Shift adds; Option subtracts; Shift-Option intersects."
    }

    /// Hint refreshes preserve the exact protected message. Explicit action
    /// feedback survives its own trailing pointer/key refresh, while a later
    /// context change may show the next affordance. State changes retain the
    /// existing activity-label priority over ordinary idle presentation.
    static func status(current: String, isError: Bool, progressActive: Bool,
                       activity: String?, actionIsVisible: Bool, refresh: Refresh,
                       hint: String, summary: String) -> String {
        if isError || progressActive { return current }
        if let activity {
            return refresh == .stateChange ? "\(activity)…" : current
        }
        if refresh == .afterAction, actionIsVisible { return current }
        return hint.isEmpty ? summary : "\(hint) · \(summary)"
    }
}
