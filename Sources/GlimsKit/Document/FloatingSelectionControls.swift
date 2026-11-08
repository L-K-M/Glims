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

    /// The resolve-first gate for structural commands while a floating
    /// selection is active; nil when none is.
    static func resolveFirstGate(_ state: EngineSession.FloatingState) -> String? {
        state.isActive ? resolveFirstReason : nil
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
        anchor.font = .systemFont(ofSize: 11)
        self.anchorButton = anchor

        let newLayer = NSButton(title: "New Layer", target: nil, action: nil)
        newLayer.setAccessibilityLabel("New layer from floating selection")
        newLayer.setAccessibilityHelp(FloatingControlsLogic.newLayerTooltip)
        newLayer.toolTip = FloatingControlsLogic.newLayerTooltip
        newLayer.bezelStyle = .rounded
        newLayer.font = .systemFont(ofSize: 11)
        self.newLayerButton = newLayer

        let discard = NSButton(title: "Discard", target: nil, action: nil)
        discard.setAccessibilityLabel("Discard floating selection")
        discard.setAccessibilityHelp(FloatingControlsLogic.discardTooltip)
        discard.toolTip = FloatingControlsLogic.discardTooltip
        discard.bezelStyle = .rounded
        discard.font = .systemFont(ofSize: 11)
        self.discardButton = discard

        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
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
