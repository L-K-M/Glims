import AppKit

/// The cached-state policy behind the floating-selection controls (Edit ▸
/// Paste Into, the Layers palette's floating row and its Anchor / New
/// Layer / Discard commands). Every entry point is pure: it reads only
/// state the document cached at its last reload, so menu validation and
/// palette reloads never call the engine. The engine revalidates
/// everything again when the queued command runs.
enum FloatingControlsLogic {
    /// Whether a floating control may run now, and why not otherwise.
    struct Readiness: Equatable {
        let allowed: Bool
        let reason: String?
        static func allowed() -> Readiness { Readiness(allowed: true, reason: nil) }
        static func refused(_ reason: String) -> Readiness { Readiness(allowed: false, reason: reason) }
    }

    /// Edit ▸ Paste Into's explicit target, from cached state only.
    struct PasteIntoTarget: Equatable {
        /// The drawable the paste would attach to; nil when refused.
        let drawable: Int32?
        let reason: String?
        var allowed: Bool { drawable != nil }
    }

    /// Select ▸ Float Selected Pixels / Float a Copy's explicit target,
    /// from cached state only.
    struct FloatTarget: Equatable {
        /// The drawable the float would take its pixels from; nil when
        /// refused.
        let drawable: Int32?
        let reason: String?
        var allowed: Bool { drawable != nil }
    }

    /// The resolve-first reason: while a floating selection is active,
    /// commands that would implicitly anchor it (target switches,
    /// structural layer/mask/channel changes, an ordinary Paste) are
    /// refused with this instead.
    static let resolveFirstReason =
        "A floating selection is active — anchor it, turn it into a new layer or discard it first."

    /// Honest New Layer copy: detaching removes the selection clipping
    /// and reveals the full pasted payload; the composite is not
    /// promised to be identical to the clipped preview.
    static let newLayerTooltip =
        "Detach the floating selection as a new layer. The selection clipping is removed and the full pasted pixels are revealed, so the result is not necessarily the same as the clipped preview."
    static let anchorTooltip = "Merge the floating selection into the drawable it is attached to."
    static let discardTooltip = "Remove the floating selection without merging it."

    /// Float Selected Pixels (MOVE) tooltip: a cut, and the float clears
    /// the selection — stated, never silently.
    static let floatMoveTooltip =
        "Cut the selected pixels out of the target and float them as a floating selection. "
        + "The target keeps a transparent hole where they were, and the selection is cleared."
    /// Float a Copy (COPY) tooltip: non-destructive, and the selection is
    /// still cleared.
    static let floatCopyTooltip =
        "Float a copy of the selected pixels as a floating selection. "
        + "The target is unchanged, and the selection is cleared."

    /// The resolve-first gate for structural commands while a floating
    /// selection is active; nil when none is.
    static func resolveFirstGate(_ state: EngineSession.FloatingState) -> String? {
        state.isActive ? resolveFirstReason : nil
    }

    /// Whether moving the active floating selection's pixels may be
    /// queued now, from cached state only — the same gates the pointer
    /// and keyboard paths check before capturing. Moving never resolves
    /// the floating selection, so the resolve-first gate does not apply
    /// here; the document's ordinary move guard still refuses floating
    /// for `moveActiveLayer`.
    static func floatingMoveReadiness(_ state: EngineSession.FloatingState,
                                      acceptsEdits: Bool, pendingTarget: Bool) -> Readiness {
        if !acceptsEdits {
            return .refused("Wait for the current image operation to finish.")
        }
        if pendingTarget {
            return .refused("The paint target is changing; wait for it to settle.")
        }
        guard state.isActive else {
            return .refused("There is no floating selection in this image.")
        }
        return .allowed()
    }

    /// The worker-side identity check for a captured floating move: the
    /// state read fresh immediately before the move must still be exactly
    /// the captured `expected` state — same floating id, same attachment
    /// target, same target kind. A Detach (New Layer) that turned the id
    /// into an ordinary layer reports no active floating selection at
    /// all, so the same id is never moved after it stopped floating.
    static func floatingStateStillMatches(expected: EngineSession.FloatingState,
                                          fresh: EngineSession.FloatingState) -> Bool {
        expected == fresh
    }

    /// The whole-image-pixel translation a captured move commits: the
    /// preview rect's offset from the captured bounds, rounded to whole
    /// pixels — the same delta the local preview showed.
    static func wholePixelDelta(bounds: CGRect, proposed: CGRect) -> CGSize {
        CGSize(width: (proposed.minX - bounds.minX).rounded(),
               height: (proposed.minY - bounds.minY).rounded())
    }

    /// The release decision for a captured floating move: nil when the
    /// gesture was cancelled (Escape, tool change, window close) or its
    /// capture is no longer valid — the release then commits nothing at
    /// all and never falls through to an ordinary/raw move; otherwise
    /// exactly one whole-pixel delta of the captured floating id.
    static func commitDelta(cancelled: Bool, stillValid: Bool,
                            bounds: CGRect, proposed: CGRect) -> CGSize? {
        guard !cancelled, stillValid else { return nil }
        return wholePixelDelta(bounds: bounds, proposed: proposed)
    }

    /// A rect usable as the captured floating-move geometry: finite with
    /// strictly positive size. An unusable capture refuses the gesture
    /// instead of planning or committing on bad bounds.
    static func usableMoveBounds(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    /// Whether `drawable` — the paint target captured for Paste Into —
    /// is a valid explicit attachment target, from cached state. The id
    /// is never 0: no layer-0 / front-document fallback reaches the
    /// engine.
    static func pasteIntoTarget(_ drawable: Int32?, state: EngineSession.FloatingState,
                                layers: [EngineSession.Layer], maskStates: [Int32: EngineSession.MaskState],
                                channels: [EngineSession.Channel], sources: [Int32: EngineSession.LayerSource],
                                locks: [Int32: EngineSession.LayerLockState],
                                acceptsEdits: Bool, pendingTarget: Bool) -> PasteIntoTarget {
        if !acceptsEdits {
            return PasteIntoTarget(drawable: nil, reason: "Wait for the current image operation to finish.")
        }
        if pendingTarget {
            return PasteIntoTarget(drawable: nil, reason: "The paint target is changing; wait for it to settle.")
        }
        if let reason = resolveFirstGate(state) {
            return PasteIntoTarget(drawable: nil, reason: reason)
        }
        guard let drawable, drawable != 0 else {
            return PasteIntoTarget(drawable: nil, reason: "Select a layer, mask or channel to paste into.")
        }
        if channels.contains(where: { $0.id == drawable }) {
            return PasteIntoTarget(drawable: drawable, reason: nil)
        }
        if let owner = maskStates.first(where: { $0.value.mask != 0 && $0.value.mask == drawable })?.key {
            if locks[owner]?.effective.contains(.pixels) == true {
                return PasteIntoTarget(drawable: nil, reason: "The mask's layer has its pixels locked.")
            }
            return PasteIntoTarget(drawable: drawable, reason: nil)
        }
        if let layer = layers.first(where: { $0.id == drawable }) {
            if layer.kind == .group {
                return PasteIntoTarget(drawable: nil,
                                       reason: "Cannot paste into a layer group; choose one of its layers, its mask or a channel.")
            }
            if isGenuineEditableSource(sources[drawable]) {
                return PasteIntoTarget(drawable: nil,
                    reason: "The target is a genuine editable text, link or vector layer; rasterize it before pasting into the selection.")
            }
            if locks[drawable]?.effective.contains(.pixels) == true {
                return PasteIntoTarget(drawable: nil, reason: "The target's pixels are locked.")
            }
            return PasteIntoTarget(drawable: drawable, reason: nil)
        }
        return PasteIntoTarget(drawable: nil,
                               reason: "The selected layer, mask or channel changed. Select a paint target again.")
    }

    /// Whether Select ▸ Float … may take the current selection off
    /// `drawable` in `mode`, from cached state. The id is never 0: no
    /// layer-0 / front-document fallback reaches the engine. The gates
    /// mirror the native preflight in `glims_selection_float`: an
    /// existing floating selection (resolve-first, never a silent
    /// anchor), a real selection, a non-group target that is not a
    /// genuine editable text/link/vector layer (rasterize first — the
    /// source gate applies to the layer's own pixels only, never to its
    /// mask or a channel), and for MOVE the target's content and alpha
    /// locks (COPY is non-destructive and checks no locks). Mask and
    /// channel targets carry no structured source of their own, matching
    /// the native check, which only reads the source of a layer target.
    static func floatTarget(_ drawable: Int32?, mode: EngineSession.FloatMode, hasSelection: Bool,
                            state: EngineSession.FloatingState,
                            layers: [EngineSession.Layer], maskStates: [Int32: EngineSession.MaskState],
                            channels: [EngineSession.Channel], sources: [Int32: EngineSession.LayerSource],
                            locks: [Int32: EngineSession.LayerLockState],
                            acceptsEdits: Bool, pendingTarget: Bool) -> FloatTarget {
        if !acceptsEdits {
            return FloatTarget(drawable: nil, reason: "Wait for the current image operation to finish.")
        }
        if pendingTarget {
            return FloatTarget(drawable: nil, reason: "The paint target is changing; wait for it to settle.")
        }
        if let reason = resolveFirstGate(state) {
            return FloatTarget(drawable: nil, reason: reason)
        }
        guard let drawable, drawable != 0 else {
            return FloatTarget(drawable: nil, reason: "Select a layer, mask or channel to float.")
        }
        if !hasSelection {
            return FloatTarget(drawable: nil, reason: "There is no selection to float; select an area first.")
        }
        if channels.contains(where: { $0.id == drawable }) {
            // Channel locks are not exposed by the cached channel model.
            // Native MOVE rechecks content locks and reports any refusal;
            // COPY remains non-destructive. Channels have no layer source.
            return FloatTarget(drawable: drawable, reason: nil)
        }
        if let owner = maskStates.first(where: { $0.value.mask != 0 && $0.value.mask == drawable })?.key {
            // MOVE cuts through the mask; the owning layer's content
            // lock gates it, as the native inherited-lock check does.
            if mode == .move, locks[owner]?.effective.contains(.pixels) == true {
                return FloatTarget(drawable: nil, reason: "The mask's layer has its pixels locked.")
            }
            return FloatTarget(drawable: drawable, reason: nil)
        }
        if let layer = layers.first(where: { $0.id == drawable }) {
            if layer.kind == .group {
                return FloatTarget(drawable: nil,
                                   reason: "Cannot float from a layer group; choose one of its layers, its mask or a channel.")
            }
            if isGenuineEditableSource(sources[drawable]) {
                return FloatTarget(drawable: nil,
                    reason: "The target is a genuine editable text, link or vector layer; rasterize it before floating the selection.")
            }
            if mode == .move {
                let effective = locks[drawable]?.effective ?? []
                if effective.contains(.pixels) {
                    return FloatTarget(drawable: nil,
                                       reason: "The target's pixels are locked; unlock them before cutting the selection out.")
                }
                if effective.contains(.alpha) {
                    return FloatTarget(drawable: nil,
                                       reason: "The target's transparency is locked; unlock it before cutting the selection out.")
                }
            }
            return FloatTarget(drawable: drawable, reason: nil)
        }
        return FloatTarget(drawable: nil,
                           reason: "The selected layer, mask or channel changed. Select a paint target again.")
    }

    /// Whether resolving the active floating selection with `command`
    /// may run now, from cached state. Anchor rechecks the target's
    /// pixel locks (the merge writes them); New Layer is unavailable for
    /// mask/channel attachments and refuses genuine editable structured
    /// targets with the rasterize-first reason; Discard is always
    /// available while the document accepts edits.
    static func resolution(_ command: EngineSession.FloatingCommand, state: EngineSession.FloatingState,
                           layers: [EngineSession.Layer], maskStates: [Int32: EngineSession.MaskState],
                           sources: [Int32: EngineSession.LayerSource],
                           locks: [Int32: EngineSession.LayerLockState],
                           acceptsEdits: Bool, pendingTarget: Bool) -> Readiness {
        if !acceptsEdits {
            return .refused("Wait for the current image operation to finish.")
        }
        if pendingTarget {
            return .refused("The paint target is changing; wait for it to settle.")
        }
        guard state.isActive else {
            return .refused("There is no floating selection in this image.")
        }
        switch command {
        case .discard:
            return .allowed()
        case .anchor:
            if let reason = targetPixelLockReason(state, maskStates: maskStates, locks: locks) {
                return .refused(reason)
            }
            return .allowed()
        case .toLayer:
            switch state.targetKind {
            case .layerMask, .channel, nil:
                return .refused("A floating selection attached to a mask or channel cannot become a new layer; "
                                + "anchor it or discard it instead.")
            case .layer:
                if isGenuineEditableSource(sources[state.target]) {
                    return .refused("The target is a genuine editable text, link or vector layer; rasterize it first.")
                }
                return .allowed()
            }
        }
    }

    /// A genuine editable structured source: the layer still carries its
    /// text/link/vector source and currently behaves as an editable
    /// object rather than pixels.
    static func isGenuineEditableSource(_ source: EngineSession.LayerSource?) -> Bool {
        guard let source, source.hasSource, !source.isRasterized else { return false }
        return source.kind != .pixel && source.kind != .group
    }

    /// The cached pixel-lock reason for anchoring into the floating
    /// selection's target: the layer itself, or the layer owning a mask
    /// target. Channel locks are revalidated by the engine; this cache has
    /// no channel-lock state.
    private static func targetPixelLockReason(_ state: EngineSession.FloatingState,
                                              maskStates: [Int32: EngineSession.MaskState],
                                              locks: [Int32: EngineSession.LayerLockState]) -> String? {
        let owner: Int32?
        switch state.targetKind {
        case .layer:
            owner = state.target
        case .layerMask:
            owner = maskStates.first(where: { $0.value.mask != 0 && $0.value.mask == state.target })?.key
        case .channel, nil:
            owner = nil
        }
        if let owner, locks[owner]?.effective.contains(.pixels) == true {
            return "The target's pixels are locked; unlock them before anchoring."
        }
        return nil
    }
}

/// A cached-state refusal of a floating-selection control, shown as-is.
enum FloatingError: LocalizedError {
    case refused(String)
    var errorDescription: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// The Layers palette's floating-selection footer: Anchor / New Layer /
/// Discard, shown only while the shown document has an active floating
/// selection. Enabled state and tooltips come from the document's cached
/// readiness — updating the bar never calls the engine — and each button
/// resolves the floating selection through the document, with the
/// expected floating id the document cached.
@MainActor
final class FloatingSelectionBar: NSStackView {
    let anchorButton: NSButton
    let newLayerButton: NSButton
    let discardButton: NSButton
    /// The document the bar acts on; set on every palette reload.
    private weak var document: ImageDocument?

    override init(frame: NSRect) {
        let anchor = NSButton(title: "Anchor", target: nil, action: nil)
        anchor.setAccessibilityLabel("Anchor floating selection")
        anchor.setAccessibilityHelp(FloatingControlsLogic.anchorTooltip)
        anchor.toolTip = FloatingControlsLogic.anchorTooltip
        anchor.bezelStyle = .rounded
        anchor.controlSize = .small
        anchor.font = .systemFont(ofSize: 11)
        self.anchorButton = anchor

        let newLayer = NSButton(title: "New Layer", target: nil, action: nil)
        newLayer.setAccessibilityLabel("New layer from floating selection")
        newLayer.setAccessibilityHelp(FloatingControlsLogic.newLayerTooltip)
        newLayer.toolTip = FloatingControlsLogic.newLayerTooltip
        newLayer.bezelStyle = .rounded
        newLayer.controlSize = .small
        newLayer.font = .systemFont(ofSize: 11)
        self.newLayerButton = newLayer

        let discard = NSButton(title: "Discard", target: nil, action: nil)
        discard.setAccessibilityLabel("Discard floating selection")
        discard.setAccessibilityHelp(FloatingControlsLogic.discardTooltip)
        discard.toolTip = FloatingControlsLogic.discardTooltip
        discard.bezelStyle = .rounded
        discard.controlSize = .small
        discard.font = .systemFont(ofSize: 11)
        self.discardButton = discard

        super.init(frame: frame)
        // The palette can be only 200 points wide. The native button
        // bezels exceed that width in a single row even with small
        // controls; a vertical stack preserves every complete label.
        orientation = .vertical
        alignment = .leading
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for button in [anchor, newLayer, discard] {
            addArrangedSubview(button)
        }
        anchor.target = self
        anchor.action = #selector(runAnchor(_:))
        newLayer.target = self
        newLayer.action = #selector(runNewLayer(_:))
        discard.target = self
        discard.action = #selector(runDiscard(_:))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Refreshes the bar from the document's cached state only.
    func update(document: ImageDocument) {
        self.document = document
        anchorButton.isEnabled = document.floatingResolutionReadiness(.anchor).allowed
        discardButton.isEnabled = document.floatingResolutionReadiness(.discard).allowed
        let toLayer = document.floatingResolutionReadiness(.toLayer)
        newLayerButton.isEnabled = toLayer.allowed
        newLayerButton.toolTip = toLayer.allowed ? FloatingControlsLogic.newLayerTooltip
            : (toLayer.reason ?? FloatingControlsLogic.newLayerTooltip)
        if !toLayer.allowed, let reason = toLayer.reason {
            newLayerButton.setAccessibilityHelp(reason)
        } else {
            newLayerButton.setAccessibilityHelp(FloatingControlsLogic.newLayerTooltip)
        }
    }

    @objc private func runAnchor(_ sender: Any?) { command(.anchor) }
    @objc private func runNewLayer(_ sender: Any?) { command(.toLayer) }
    @objc private func runDiscard(_ sender: Any?) { command(.discard) }

    private func command(_ command: EngineSession.FloatingCommand) {
        document?.resolveFloatingSelection(command, completion: { _ in })
    }
}
