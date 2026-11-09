import AppKit
import CGlimsEngine
import CoreGraphics

/// One open image in the engine, as the interface sees it.
///
/// The document keeps the state the interface shows (size, layers, undo)
/// and routes work to the engine off the main thread: pointer input and
/// filter edits go through one serial queue so they reach the engine in
/// order. File operations and plug-ins use the shared engine activity
/// queue after all documents' accepted input, with new edits visibly
/// refused until the engine can accept them again.
@MainActor
final class ImageDocument {
    let session: EngineSession
    let image: Int32
    /// The display name; a successful native save replaces it with the
    /// file's name.
    private(set) var name: String
    /// The file the image belongs to and whether it needs saving.
    private(set) var fileState: DocumentFileState
    /// This document's page setup, changed by File ▸ Page Setup and read
    /// by Print: per document, like an NSDocument's print info. Editing
    /// it touches neither the image nor the file state.
    var printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()

    private(set) var info: EngineSession.ImageInfo
    private(set) var layers: [EngineSession.Layer] = []
    private(set) var undoInfo = EngineSession.UndoInfo(undoCount: 0, redoCount: 0, nextUndo: "", nextRedo: "")
    /// The undo history last read with the rest of the state: the
    /// revision these rows and the current position were seen with, so a
    /// palette pick can only name a state the engine still holds.
    private(set) var history: EngineSession.History?

    /// The layer painting and filters apply to. It may be a group:
    /// groups cannot be painted on but stay valid metadata and filter
    /// targets. It is always the primary of `selectedLayerIDs`.
    private(set) var activeLayer: Int32?
    /// The image's selected layers, ordered with the primary layer
    /// first — the order the engine's own `selectedLayers` read-back
    /// returns, because the first selected layer is the active one.
    /// Transient: changing it pushes no undo step and dirties nothing.
    /// Reconciled on every reload against the ids that still exist, so
    /// undo/redo and completions can only land on layers still present.
    private(set) var selectedLayerIDs: [Int32] = []
    /// Whether more than one layer is selected: the multi-selection
    /// state that gates every single-layer command.
    var hasMultipleSelectedLayers: Bool { LayerSelectionPolicy.isMulti(selectedLayerIDs.count) }
    /// The cached reason single-layer commands refuse while more than
    /// one layer is selected, or nil for a single selection. Menu and
    /// palette validation read this; no engine call happens here.
    var multiLayerSelectionRefusal: String? {
        guard let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                        action: "This command") else { return nil }
        return reason
    }
    /// Each masked layer's mask state by layer id, read with the rest of
    /// the state. EDITING is transient — the engine keeps no undo for
    /// the edit target and reports no event for it — so the mask
    /// commands and target picks refresh it explicitly.
    private(set) var maskStates: [Int32: EngineSession.MaskState] = [:]
    private(set) var components: EngineSession.ComponentState?
    private(set) var channels: [EngineSession.Channel] = []
    private(set) var quickMaskState: EngineSession.QuickMaskState?
    /// The image's color model, precision and effective profile, read
    /// with the rest of the state. The window title, the Mode checkmarks,
    /// the Precision form and the Image Information sheet all read this
    /// cache; none of them asks the engine while it validates a menu.
    private(set) var colorInfo: EngineSession.ColorInfo
    /// Bumped by every reload; thumbnail caches key on it so a result
    /// read for an older state never lands on a newer row.
    private(set) var stateVersion = 0
    private enum PaintTarget {
        case layer(Int32)
        case mask(layer: Int32, drawable: Int32)
        case channel(Int32)

        var drawable: Int32 {
            switch self {
            case .layer(let id), .channel(let id): return id
            case .mask(_, let id): return id
            }
        }

        var layer: Int32? {
            switch self {
            case .layer(let id), .mask(let id, _): return id
            case .channel: return nil
            }
        }

        var mask: Int32? {
            if case .mask(_, let id) = self { return id }
            return nil
        }
    }

    private struct TargetPick {
        let version: Int
        let target: PaintTarget
    }
    private var targetPickVersion = 0
    private var pendingTargetPick: TargetPick?
    private var rejectedTargetPick = false
    /// A queued multi-selection, mirrored like a target pick: the ids
    /// in primary-first order, captured with the document's own image
    /// handle so the job can never retarget to another document.
    private struct PendingLayerSelection {
        let version: Int
        let ids: [Int32]
    }
    private var layerSelectionVersion = 0
    private var pendingLayerSelection: PendingLayerSelection?
    private struct ComponentIntent {
        let version: Int
        let activeMask: EngineSession.Components
        let activeValues: EngineSession.Components
        let visibleMask: EngineSession.Components
        let visibleValues: EngineSession.Components
    }
    private var componentIntents: [ComponentIntent] = []
    private var nextChannelIntent = 0
    private var channelVisibilityIntents: [Int32: (version: Int, visible: Bool)] = [:]
    private var quickMaskIntent: (version: Int, enabled: Bool)?
    /// Input-queue state: edits already accepted behind a failed pick
    /// must refuse before reaching an implicit native drawable target.
    private nonisolated(unsafe) var paintTargetIsValid = true
    /// The lock state the engine reported per layer id at the last reload:
    /// the item's own locks and the locks enforced on it.
    private(set) var layerLocks: [Int32: EngineSession.LayerLockState] = [:]
    /// Each layer's committed effects by layer id, top first, read with
    /// the rest of the state — metadata only, never per paint. The
    /// Layers palette's effect rows show them; the engine's listing
    /// never counts a live preview session among them.
    private(set) var layerEffects: [Int32: [EngineSession.Effect]] = [:]
    /// Each layer's structured-source state by layer id, read with the
    /// rest of the state: the layer's own class kind (kept after
    /// rasterization, unlike `Layer.kind`), whether it currently behaves
    /// as pixels, and whether its text, link or path source survived.
    private(set) var layerSources: [Int32: EngineSession.LayerSource] = [:]
    /// While the window's filter preview is open, layer changes are
    /// refused — the preview owns its drawable. Set by the controller.
    var filterPreviewIsOpen = false
    /// Queued engine commands whose result becomes or replaces the paint
    /// target — a created, pasted or text layer, an editing mask, or a
    /// command that removes the target. While one is queued the drawable
    /// it lands on is unknown: `activeDrawable` reports none so an edit
    /// accepted now cannot capture the drawable the command is about to
    /// replace, and a reload holds the interface's target rather than a
    /// half-observed native selection. Each token clears when its
    /// completion lands, on success or failure; a valid target pick
    /// clears them all — its mirrored target wins ahead of their
    /// completions.
    private var pendingTargetCommands: Set<Int> = []
    private var nextTargetCommandToken = 0
    /// Bound by the window controller: commits in-flight field and text
    /// edits and ends an active stroke before a user selection or a
    /// structural/lock change.
    var onWillChangeLayers: (() -> Void)?
    /// Called at the start of each user command, so the window can let a
    /// remembered error message go.
    var onUserCommand: (() -> Void)?
    /// The selection outline in image pixels, for marching ants.
    private(set) var selectionOutline: [EngineSession.Segment] = []
    /// Native nonzero coverage also includes selections below the
    /// display outline's 50% threshold.
    private(set) var selectionBounds: CGRect?
    /// The image's ordinary guides, read with the rest of the state.
    /// Guide changes are metadata — they never touch pixels or the
    /// selection — so the cache refreshes with `reload` and on the
    /// deferred guides-changed refresh.
    private(set) var guides: [EngineSession.Guide] = []
    /// The image's display grid, read with the rest of the state. A
    /// grid change is one undo step and metadata — it never touches
    /// pixels or the selection — so the cache refreshes with `reload`,
    /// which the undo-changed event schedules; no dedicated event.
    private(set) var grid = EngineSession.Grid()
    /// The image's floating-selection state, read with the rest of the
    /// state: a Paste Into result before it resolves. Every Paste Into
    /// and resolution is one undo step, so the undo-changed event's
    /// reload refreshes this cache — as do the explicit reloads after
    /// Undo/Redo. The Layers palette, the Edit menu and the paint target
    /// all read this cache; none asks the engine while validating.
    private(set) var floatingState = EngineSession.FloatingState(floating: 0, target: 0, targetKind: nil)
    /// The image's paths, top first.
    private(set) var paths: [EngineSession.PathInfo] = []
    /// The path the Path tool edits and the Paths palette's commands use.
    private(set) var activePath: Int32?
    /// The shapes the canvas draws: visible paths and the active one.
    private(set) var pathShapes: [Int32: VectorPath] = [:]
    /// Edits sent to the engine and not yet done, per path; until they
    /// are, a reload keeps the shape the edit set rather than the engine's
    /// older one.
    private var pendingPathEdits: [Int32: Int] = [:]

    /// Called after layers or undo state changed.
    var onStateChange: (() -> Void)?
    /// Called with the changed area in image pixels.
    var onProjectionChange: ((CGRect) -> Void)?
    /// Called with engine errors that the interface should show.
    var onError: ((String) -> Void)?
    /// Called after the selection changed.
    var onSelectionChange: (() -> Void)?
    /// Called after the image's size changed (crop, canvas size, undo).
    var onSizeChange: (() -> Void)?

    /// The identity this open document's recovery record is filed under.
    let recoveryID = UUID()

    nonisolated let inputQueue = DispatchQueue(label: "ch.lkmc.Glims.document.input", qos: .userInteractive)
    private nonisolated let clipboardQueue = DispatchQueue(label: "ch.lkmc.Glims.document.clipboard", qos: .userInitiated)
    nonisolated let longQueue = DispatchQueue(label: "ch.lkmc.Glims.document.long", qos: .userInitiated)

    /// Engine jobs queued and not yet finished. Touched on the main actor
    /// only: every enqueue happens here and each job reports its end back
    /// here, so a close can wait for the count to reach zero before the
    /// engine image is destroyed.
    private(set) var pendingWork = 0
    /// Input-queue jobs in flight — all of them edits, so each counts as
    /// an unsaved change until the engine's dirty flag comes back.
    private var pendingInput = 0
    /// Once the image starts closing, nothing new is queued.
    private(set) var isClosing = false
    private(set) var isTransferringClipboard = false
    private(set) var isSavingForClose = false
    private var onQueueDrained: (() -> Void)?

    var acceptsEdits: Bool {
        !isClosing && !isSavingForClose && !isTransferringClipboard && !PlugInCommands.isRunning
            && !filterPreviewIsOpen && !EngineActivity.shared.isBusy
    }

    /// A queued target command's drawable is still unknown. Menu
    /// validation reads this cached flag instead of asking the engine.
    var targetCommandIsPending: Bool { !pendingTargetCommands.isEmpty }

    /// Touched only on `inputQueue`.
    private nonisolated(unsafe) var currentStroke: Int32?
    private(set) var strokeIsActive = false

    /// Which plug-in commands can run on the selected layers, by name;
    /// nil until asked for after a change.
    private var procedureSensitivity: [String: Bool]?

    /// `source` is the file the image was opened from — native XCF or a
    /// foreign file it was imported from; `nil` for a new image.
    init(session: EngineSession, image: Int32, name: String, openedFrom source: URL? = nil) throws {
        self.session = session
        self.image = image
        self.name = name
        self.fileState = DocumentFileState(openedFrom: source)
        self.info = try session.info(image)
        self.colorInfo = try session.colorInfo(image)
        try reload()
        refreshSelection()
        EngineActivity.shared.register(self)
    }

    /// Re-reads layers, undo state and size from the engine.
    func reload() throws {
        procedureSensitivity = nil
        stateVersion += 1
        info = try session.info(image)
        fileState.syncDirty(info.isDirty)
        layers = try session.layers(image)
        var locks: [Int32: EngineSession.LayerLockState] = [:]
        var masks: [Int32: EngineSession.MaskState] = [:]
        var effects: [Int32: [EngineSession.Effect]] = [:]
        var sources: [Int32: EngineSession.LayerSource] = [:]
        for layer in layers {
            locks[layer.id] = try? session.layerState(layer.id, image: image)
            sources[layer.id] = try? session.layerSource(layer.id, image: image)
            if layer.hasMask, let state = try? session.layerMask(layer.id, image: image),
               state.mask != 0 {
                masks[layer.id] = state
            }
            if layer.filterCount > 0 {
                effects[layer.id] = (try? session.effects(on: layer.id, image: image)) ?? []
            }
        }
        layerLocks = locks
        layerEffects = effects
        layerSources = sources
        if let pick = pendingTargetPick, let pickedLayer = pick.target.layer {
            for (id, var mask) in masks {
                mask.editing = id == pickedLayer && pick.target.mask != nil
                masks[id] = mask
            }
        }
        maskStates = masks
        components = try session.components(image)
        channels = try session.channels(image)
        quickMaskState = try session.quickMask(image)
        colorInfo = try session.colorInfo(image)
        guides = try session.guides(image)
        grid = try session.grid(image)
        floatingState = try session.floatingSelection(image)
        mirrorChannelIntents()
        if let pick = pendingTargetPick {
            channels = channels.map { row in
                channelRow(row, selected: {
                    if case .channel(let id) = pick.target { return id == row.id }
                    return false
                }())
            }
        }
        undoInfo = try session.undoInfo(image)
        history = try session.history(image)
        // The ordered selected layers, primary first. While a pick or a
        // queued multi-selection mirrors an intended selection, the
        // mirror wins; otherwise the engine's own read-back is
        // authoritative, so undo/redo and command completions only need
        // this reconcile — never a native select of their own. Stale ids
        // (a layer an undo removed) drop out here, order kept.
        let mirroredSelection: [Int32]? = {
            if let pick = pendingTargetPick, let layer = pick.target.layer { return [layer] }
            if let pending = pendingLayerSelection { return pending.ids }
            return nil
        }()
        let targetIsMirrored = pendingTargetPick != nil || pendingLayerSelection != nil
            || !pendingTargetCommands.isEmpty
        let oracle = (try? session.selectedLayers(image)) ?? []
        selectedLayerIDs = LayerSelectionPolicy.reconcile(mirroredSelection ?? oracle,
                                                          existing: Set(layers.map(\.id)))
        if !targetIsMirrored || activeLayer == nil || !layers.contains(where: { $0.id == activeLayer }) {
            activeLayer = selectedLayerIDs.first ?? layers.first(where: \.isSelected)?.id ?? layers.first?.id
        }
        reloadPaths()
        onStateChange?()
    }

    private func reloadPaths() {
        paths = (try? session.paths(image)) ?? []
        if activePath == nil || !paths.contains(where: { $0.id == activePath }) {
            activePath = paths.first(where: \.isSelected)?.id
        }
        var shapes: [Int32: VectorPath] = [:]
        for path in paths where path.isVisible || path.id == activePath {
            if pendingPathEdits[path.id, default: 0] > 0, let pending = pathShapes[path.id] {
                shapes[path.id] = pending
            } else {
                shapes[path.id] = try? session.path(path.id, image: image)
            }
        }
        pathShapes = shapes
    }

    /// The drawable painting, fills, gradients, filters, Copy and Clear
    /// act on. A selected channel takes precedence over the remembered
    /// layer, just as it does for implicit engine edits — except while a
    /// floating selection is active: it owns painting even when it is
    /// attached to a mask or channel, whose drawable would otherwise win
    /// as the channel-priority (or mask-editing) target.
    private var paintTarget: PaintTarget? {
        guard !rejectedTargetPick, pendingTargetCommands.isEmpty else { return nil }
        if let pick = pendingTargetPick { return pick.target }
        if floatingState.isActive { return .layer(floatingState.floating) }
        if let channel = channels.first(where: \.isSelected) { return .channel(channel.id) }
        guard let layer = activeLayer else { return nil }
        if let state = maskStates[layer], state.editing, state.mask != 0 {
            return .mask(layer: layer, drawable: state.mask)
        }
        return .layer(layer)
    }

    var activeDrawable: Int32? { paintTarget?.drawable }

    var activeChannel: Int32? {
        if case .channel(let id) = paintTarget { return id }
        return nil
    }

    /// Whether the active target is a mask rather than the layer:
    /// transforms, moves and path strokes have no mask backend, so they
    /// refuse instead of silently editing the layer's pixels.
    var isMaskTargetActive: Bool {
        if case .mask = paintTarget { return true }
        return false
    }

    var isChannelTargetActive: Bool { activeChannel != nil }

    private func channelRow(_ row: EngineSession.Channel, selected: Bool? = nil,
                            visible: Bool? = nil) -> EngineSession.Channel {
        EngineSession.Channel(id: row.id, name: row.name, isVisible: visible ?? row.isVisible,
                              isSelected: selected ?? row.isSelected, isQuickMask: row.isQuickMask,
                              opacity: row.opacity, color: row.color)
    }

    private func mirrorChannelIntents() {
        if let state = components {
            var active = state.active, visible = state.visible
            for intent in componentIntents {
                active.subtract(intent.activeMask)
                active.formUnion(intent.activeValues.intersection(intent.activeMask))
                visible.subtract(intent.visibleMask)
                visible.formUnion(intent.visibleValues.intersection(intent.visibleMask))
            }
            components = EngineSession.ComponentState(mode: state.mode, supported: state.supported,
                                                       active: active, visible: visible)
        }
        channels = channels.map { row in
            channelRow(row, visible: channelVisibilityIntents[row.id]?.visible)
        }
        if let intent = quickMaskIntent, let state = quickMaskState {
            quickMaskState = EngineSession.QuickMaskState(enabled: intent.enabled,
                channel: intent.enabled ? state.channel : 0, inverted: state.inverted, color: state.color)
        }
    }

    /// Makes `id` the layer painting, fills, filters, plug-ins and the
    /// Layer commands act on, here and in the engine. Groups can be
    /// selected: they are valid metadata and filter targets. Picking the
    /// layer as the target leaves mask editing, as clicking the layer's
    /// own thumbnail does in GIMP.
    func selectLayer(_ id: Int32) {
        guard !isClosing else { return }
        guard !refuseWhileEditingUnavailable() else { return }
        // A target switch would implicitly anchor an active floating
        // selection in the engine; this slice refuses it instead.
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        selectTarget(id, editingMask: false)
    }

    /// The mask thumbnail's pick: `id`'s layer becomes active with mask
    /// editing on, so painting, fills, gradients, filters, Copy and Clear
    /// land on the mask.
    func editMask(_ id: Int32) {
        guard !isClosing else { return }
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        guard let layer = layers.first(where: { $0.id == id }), layer.hasMask else { return }
        // Without a cached state the mask's drawable id is unknown, and
        // activeDrawable could not name it; read it now — a cheap engine
        // read, no pixels.
        if maskStates[id] == nil { maskStates[id] = try? session.layerMask(id, image: image) }
        guard let mask = maskStates[id], mask.mask != 0 else { return }
        selectTarget(id, editingMask: true)
    }

    /// Queues the layer-vs-mask pick as one input-queue job: the engine's
    /// selected layer and the mask's transient EDITING flag land together,
    /// ahead of any stroke, fill or filter queued afterwards. The flag is
    /// mirrored optimistically so `activeDrawable` is right for input
    /// accepted before the job lands; the job's completion re-reads the
    /// authoritative state, which also covers a refused flag change.
    private func selectTarget(_ id: Int32, editingMask: Bool) {
        guard layers.contains(where: { $0.id == id }) else { return }
        // A masked layer whose state was never read gets one now, so a
        // stale engine-side EDITING flag cannot disagree with
        // activeDrawable in either direction.
        if maskStates[id] == nil,
           layers.first(where: { $0.id == id })?.hasMask == true {
            maskStates[id] = try? session.layerMask(id, image: image)
        }
        let mask = maskStates[id]?.mask
        guard !editingMask || (mask != nil && mask != 0) else { return }
        queueTargetPick(editingMask ? .mask(layer: id, drawable: mask!) : .layer(id))
    }

    func selectChannel(_ id: Int32) {
        guard !isClosing, !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        guard channels.contains(where: { $0.id == id }) else { return }
        queueTargetPick(.channel(id))
    }

    /// Selects exactly `ids`, primary first, as the image's whole
    /// selected-layer list — the native multi-selection the Layers
    /// palette's Shift/Command clicks ask for. Transient like a single
    /// pick: no undo step, no dirty flag, no pixel or mask change; the
    /// engine clears mask editing on the selected layers itself. Every
    /// id is validated against the cached list first: a stale or
    /// invalid row refuses and refreshes instead of reaching the engine.
    /// While a floating selection is active the resolve-first gate
    /// refuses, exactly like a single pick. The write is one counted,
    /// serial input-queue job capturing this document's image handle, so
    /// it can never land on another document or the front window.
    func selectLayers(_ ids: [Int32]) {
        guard !isClosing else { return }
        guard !refuseWhileEditingUnavailable() else { return }
        // A selection switch would implicitly anchor an active floating
        // selection; the resolve-first gate refuses it, like selectLayer.
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        let existing = Set(layers.map(\.id))
        guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ existing.contains($0) }) else {
            // An invalid or stale row: refuse and refresh from the
            // engine's authoritative selection.
            onUserCommand?()
            onError?(DocumentError.targetChanged.localizedDescription)
            NSSound.beep()
            try? reload()
            return
        }
        let ordered = LayerSelectionPolicy.reconcile(ids, existing: existing)
        guard ordered != selectedLayerIDs else { return }
        queueLayerSelection(ordered)
    }

    /// Queues the ordered multi-selection as one serial input job, with
    /// the same mirror discipline as a target pick: the primary id
    /// becomes the active layer at once, the native behavior of leaving
    /// mask editing is mirrored (the mask's pixels are never touched),
    /// and the completion re-reads the authoritative state. The job's
    /// read-back must equal the requested order exactly; a mismatch is
    /// reported, never treated as success.
    private func queueLayerSelection(_ ids: [Int32]) {
        layerSelectionVersion += 1
        let pick = PendingLayerSelection(version: layerSelectionVersion, ids: ids)
        pendingLayerSelection = pick
        // A valid pick resolves the target itself, like queueTargetPick.
        pendingTargetPick = nil
        rejectedTargetPick = false
        pendingTargetCommands.removeAll()
        selectedLayerIDs = ids
        if let primary = ids.first { activeLayer = primary }
        // Native multi-selection exits mask editing on every selected
        // layer; mirror it so activeDrawable is right for input accepted
        // before the job lands. Mask pixels and flags are untouched.
        for id in ids { maskStates[id]?.editing = false }
        channels = channels.map { channelRow($0, selected: false) }
        enqueue(on: inputQueue) { [session, image] in
            var failure: Error?
            self.paintTargetIsValid = false
            do {
                try session.channelCommand(.select, channel: 0, image: image)
                try session.selectLayers(ids, image: image)
                guard try session.selectedLayers(image) == ids else {
                    throw DocumentError.targetChanged
                }
                self.paintTargetIsValid = true
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                if self.pendingLayerSelection?.version == pick.version {
                    self.pendingLayerSelection = nil
                }
                if let failure { self.report(failure) }
                try? self.reload()
            }
        }
        onStateChange?()
    }

    func returnToLayers() {
        if let layer = activeLayer { selectLayer(layer) }
    }

    private func queueTargetPick(_ target: PaintTarget) {
        targetPickVersion += 1
        let pick = TargetPick(version: targetPickVersion, target: target)
        pendingTargetPick = pick
        rejectedTargetPick = false
        // A valid known pick resolves the target itself: queued target
        // commands keep running, but their completions now reconcile to
        // this pick rather than their own result.
        pendingTargetCommands.removeAll()
        // Mask editing is one target at a time: a mask still flagged
        // EDITING on another layer would keep claiming fills and
        // gradients, so its flag clears in the same job. EDITING
        // changes carry no undo step.
        let staleEditing = maskStates.filter {
            target.layer != nil && $0.key != target.layer && $0.value.editing && $0.value.mask != 0
        }
            .map(\.key)
        if let layer = target.layer {
            activeLayer = layer
            // A single-layer pick collapses the selection to that layer.
            selectedLayerIDs = [layer]
            pendingLayerSelection = nil
            maskStates[layer]?.editing = target.mask != nil
        }
        for other in staleEditing { maskStates[other]?.editing = false }
        channels = channels.map { row in
            if case .channel(let id) = target { return channelRow(row, selected: row.id == id) }
            return channelRow(row, selected: false)
        }
        enqueue(on: inputQueue) { [session, image] in
            var failure: Error?
            self.paintTargetIsValid = false
            do {
                // Best-effort: a layer gone since the read must not
                // block the pick itself; reload reconciles the rest.
                for other in staleEditing {
                    try? session.setLayerMask(other, image: image, flags: [.editing], values: [])
                }
                if let layer = target.layer {
                    // Selecting an already-selected layer can be a native
                    // no-op. Clear channels explicitly before that call.
                    try session.channelCommand(.select, channel: 0, image: image)
                    try session.selectLayer(layer, image: image)
                    guard try session.layers(image).contains(where: { $0.id == layer && $0.isSelected }) else {
                        throw DocumentError.targetChanged
                    }
                    let fresh = try session.layerMask(layer, image: image)
                    if let mask = target.mask, fresh.mask != mask || mask == 0 {
                        throw DocumentError.targetChanged
                    }
                    if fresh.mask != 0, fresh.editing != (target.mask != nil) {
                        try session.setLayerMask(layer, image: image, flags: [.editing],
                                                 values: target.mask != nil ? [.editing] : [])
                    }
                } else if case .channel(let id) = target {
                    try session.channelCommand(.select, channel: id, image: image)
                    guard try session.channels(image).contains(where: { $0.id == id && $0.isSelected }) else {
                        throw DocumentError.targetChanged
                    }
                }
                self.paintTargetIsValid = true
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                if self.pendingTargetPick?.version == pick.version {
                    self.pendingTargetPick = nil
                    self.rejectedTargetPick = failure != nil
                }
                if let failure { self.report(failure) }
                try? self.reload()
            }
        }
        onStateChange?()
    }

    /// The engine-reading refreshes `handle` asks for, collected while
    /// an exclusive engine activity runs: a pure-core call (a mode or
    /// precision conversion on a large image, a file call) can emit
    /// events before it returns, and a synchronous reload would wait on
    /// the engine thread behind that call, stalling the main thread.
    /// The pending kinds coalesce into one deferred refresh that runs
    /// through EngineActivity.whenIdle once the engine frees up.
    private struct PendingRefresh: OptionSet {
        let rawValue: Int
        /// A full state reload (size, layers, undo, color state).
        static let state = PendingRefresh(rawValue: 1 << 0)
        /// The selection outline read.
        static let selection = PendingRefresh(rawValue: 1 << 1)
        /// Fires the size callback after the reload.
        static let size = PendingRefresh(rawValue: 1 << 2)
        /// The guides list only; cheaper than a full reload.
        static let guides = PendingRefresh(rawValue: 1 << 3)
    }
    private var pendingRefresh: PendingRefresh = []
    private var refreshIsScheduled = false

    func handle(_ event: EngineSession.Event) {
        switch event {
        case .projectionChanged(let image, let rect) where image == self.image:
            onProjectionChange?(rect)
        case .layersChanged(let image) where image == self.image,
             .channelsChanged(let image) where image == self.image,
             .undoChanged(let image) where image == self.image:
            scheduleRefresh(.state)
        case .selectionChanged(let image) where image == self.image:
            scheduleRefresh(.selection)
        case .sizeChanged(let image) where image == self.image:
            scheduleRefresh([.state, .size])
        case .guidesChanged(let image) where image == self.image:
            scheduleRefresh(.guides)
        default:
            break
        }
    }

    /// Runs `kinds`' reads now, or once the exclusive engine activity
    /// ends; several events inside one busy period fold into one
    /// refresh. A closing document schedules nothing, and the deferred
    /// run skips it again if the close began meanwhile.
    private func scheduleRefresh(_ kinds: PendingRefresh) {
        guard !isClosing else { return }
        pendingRefresh.formUnion(kinds)
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        EngineActivity.shared.whenIdle { [weak self] in self?.runPendingRefresh() }
    }

    private func runPendingRefresh() {
        refreshIsScheduled = false
        let pending = pendingRefresh
        pendingRefresh = []
        guard !isClosing, !pending.isEmpty else { return }
        if pending.contains(.state) || pending.contains(.size) { try? reload() }
        if pending.contains(.selection) { refreshSelection() }
        if pending.contains(.guides) { reloadGuides() }
        if pending.contains(.size) { onSizeChange?() }
    }

    private func reloadGuides() {
        guard let fresh = try? session.guides(image) else { return }
        guard fresh != guides else { return }
        guides = fresh
        onStateChange?()
    }

    // MARK: Painting

    func beginStroke(at point: EngineSession.StrokePoint, brush: EngineSession.Brush = EngineSession.Brush()) {
        guard !refuseWhileEditingUnavailable(), !refuseWhileTargetPending() else { return }
        guard !refuseSingleLayerCommand("Paint") else { return }
        guard let drawable = activeDrawable else {
            onError?(DocumentError.targetChanged.localizedDescription)
            return
        }
        // A group's own pixels cannot be painted on; its mask can, so the
        // check applies to the layer, not the drawable.
        if drawable == activeLayer,
           layers.first(where: { $0.id == drawable })?.kind == .group {
            onError?("Layer groups cannot be painted on; select a layer.")
            NSSound.beep()
            return
        }
        strokeIsActive = true
        enqueue(on: inputQueue, input: true) { [session, image] in
            do {
                try self.requirePaintTarget()
                self.currentStroke = try session.beginStroke(image: image, drawable: drawable, brush: brush, first: point)
            } catch {
                self.currentStroke = nil
                self.report(error)
            }
        }
    }

    func continueStroke(_ points: [EngineSession.StrokePoint]) {
        guard strokeIsActive else { return }
        enqueue(on: inputQueue, input: true) { [session] in
            guard let stroke = self.currentStroke else { return }
            do { try session.continueStroke(stroke, points: points) } catch { self.report(error) }
        }
    }

    func endStroke() {
        guard strokeIsActive else { return }
        strokeIsActive = false
        enqueue(on: inputQueue, input: true) { [session] in
            guard let stroke = self.currentStroke else { return }
            self.currentStroke = nil
            do { try session.endStroke(stroke) } catch { self.report(error) }
        }
    }

    // MARK: Selection

    func select(_ shape: EngineSession.SelectShape, options: EngineSession.SelectOptions) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.select(shape, image: image, options: options) }
    }

    func selectColor(at point: CGPoint, options: EngineSession.SelectOptions) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.selectColor(at: point, image: image, options: options) }
    }

    func select(_ command: EngineSession.SelectCommand, radius: Double = 0) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.select(command, image: image, radius: radius) }
    }

    /// Strokes the selection's boundary on the active layer with `brush`,
    /// as one undo step ordered behind every already accepted input: the
    /// job counts as queued input on the input queue, off the main
    /// thread. `brush`'s settings and its selected brush's
    /// `ResourceIdentity` — never a session handle — and the target
    /// drawable are captured by value here and resolved on the worker, so
    /// no synchronous native call runs on the main thread and a stale or
    /// removed resource fails explicitly. The engine suspends the
    /// selection for the stroke, so the line straddles the boundary and
    /// the selection itself is unchanged; an empty selection fails
    /// actionably with no mutation. Like path strokes, the target is a
    /// layer only — a mask or channel target is refused rather than
    /// silently painting the layer's pixels, as is a layer group.
    func strokeSelection(_ brush: EngineSession.Brush = EngineSession.Brush()) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseSingleLayerCommand("Stroke Selection") else { return }
        guard !isChannelTargetActive else { return refuseChannelTransform() }
        guard !isMaskTargetActive else {
            onError?("A selection cannot be stroked onto a mask; select the layer first.")
            NSSound.beep()
            return
        }
        guard !refuseWhileTargetPending() else { return }
        guard let drawable = activeDrawable else {
            onError?(DocumentError.targetChanged.localizedDescription)
            NSSound.beep()
            return
        }
        if drawable == activeLayer,
           layers.first(where: { $0.id == drawable })?.kind == .group {
            onError?("A selection cannot be stroked onto a layer group; select a layer.")
            NSSound.beep()
            return
        }
        // End in-flight field/text edits and an active stroke first, the
        // finishInput/endPendingUserEdits convention: both enqueue their
        // jobs on this same serial input queue ahead of the one below, so
        // every already accepted edit — and the open stroke's end — lands
        // on the engine before the selection stroke runs. Without that,
        // the native readiness check would report BUSY under the open
        // stroke instead of stroking on the committed image.
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        enqueue(on: inputQueue, input: true) { [session, image] in
            do {
                try self.requirePaintTarget()
                try session.strokeSelection(image: image, drawable: drawable, brush: brush)
            } catch {
                self.report(error)
            }
        }
    }

    /// The cached-state reason Edit ▸ Stroke Selection… cannot run right
    /// now, or nil when it can. Reads only the document's cached state —
    /// never the engine — so menu validation and the sheet's open/accept
    /// gates make no synchronous native call. An editable structured
    /// source (text, link or vector layer that still carries its source)
    /// refuses with a rasterize-first explanation rather than silently
    /// destroying it; the rasterize UI is a separate pending change and
    /// is not adopted here.
    var strokeSelectionRefusal: String? {
        if let activity = EngineActivity.shared.label, !PlugInCommands.isRunning {
            return "\(activity)… Wait for it to finish before editing."
        }
        if isClosing { return DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard { return DocumentError.busy.localizedDescription }
        if filterPreviewIsOpen { return "Apply or cancel the filter preview first." }
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Stroke Selection") {
            return reason
        }
        if let running = PlugInCommands.running {
            let title = running.procedure.label.replacingOccurrences(of: "…", with: "")
            return "Finish or cancel \u{201C}\(title)\u{201D} first."
        }
        if selectionOutline.isEmpty { return "There is no selection to stroke; select an area first." }
        if isChannelTargetActive {
            return "A selection cannot be stroked onto a channel; select the layer first."
        }
        if isMaskTargetActive {
            return "A selection cannot be stroked onto a mask; select the layer first."
        }
        guard let drawable = activeDrawable else { return DocumentError.targetChanged.localizedDescription }
        if let layer = paintTarget?.layer,
           layers.first(where: { $0.id == drawable })?.kind == .group {
            return "A selection cannot be stroked onto a layer group; select a layer."
        }
        if let layer = paintTarget?.layer,
           layerLocks[layer]?.effective.contains(.pixels) == true {
            return "Unlock the layer's pixels (or its group's) before stroking the selection."
        }
        if let layer = paintTarget?.layer,
           let source = layerSources[layer], source.hasSource, !source.isRasterized {
            let what = source.kind == .text ? "text" : source.kind == .link ? "linked" : "vector"
            return "Rasterize the \(what) layer first (Layer ▸ Rasterize): stroking the selection would paint over its editable source."
        }
        return nil
    }

    // MARK: Guides

    /// Adds a guide at `position` (image pixels on `orientation`'s
    /// axis, inside 0 ... the image's extent on it) as one undo step.
    /// Guide changes are metadata: pixels and the selection are never
    /// touched, and pixel locks do not refuse them.
    func addGuide(_ orientation: EngineSession.GuideOrientation, at position: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            _ = try session.putGuide(EngineSession.Guide(id: 0, orientation: orientation,
                                                         position: position), image: image)
        }
    }

    /// Moves `guide` to `position` as one undo step; the guide's own
    /// orientation stays (a reorientation is refused). A move to the
    /// position it already holds is a no-op with no undo.
    func moveGuide(_ guide: EngineSession.Guide, to position: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            _ = try session.putGuide(EngineSession.Guide(id: guide.id,
                                                         orientation: guide.orientation,
                                                         position: position), image: image)
        }
    }

    /// Removes `guide` as one undo step; a stale, foreign or custom
    /// tool-owned id is refused.
    func removeGuide(_ guide: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.removeGuide(guide, image: image) }
    }

    // MARK: Grid

    /// Applies `grid` to the image as one undo step; an identical grid
    /// is a no-op with no undo. Grid changes are metadata: pixels and
    /// the selection are never touched, and pixel locks do not refuse
    /// them. The cached `grid` refreshes through `reload` on the
    /// undo-changed event this step emits.
    func setGrid(_ grid: EngineSession.Grid,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        endPendingUserEdits()
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        // Keep the deferred cache/completion stage alive through another
        // document's exclusive work as well as the native input job.
        pendingWork += 1
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.setGrid(grid, image: image) }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    if !self.isClosing {
                        try? self.reload()
                        if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    }
                    completion(result)
                }
            }
        }
    }

    // MARK: Editing

    func fill(at point: CGPoint, mode: EngineSession.FillMode, color: NSColor, threshold: Double,
              sampleMerged: Bool, opacity: Double = 1) {
        guard !refuseWhileEditingUnavailable() else { return }
        runOnPaintTarget { session, image in
            try session.fill(image: image, at: point, mode: mode, color: color,
                             opacity: opacity, threshold: threshold, sampleMerged: sampleMerged)
        }
    }

    func gradient(from: CGPoint, to: CGPoint, shape: EngineSession.GradientShape, fromColor: NSColor, toColor: NSColor) {
        guard !refuseWhileEditingUnavailable() else { return }
        runOnPaintTarget { session, image in
            try session.gradient(image: image, from: from, to: to, shape: shape, fromColor: fromColor, toColor: toColor)
        }
    }

    /// Fills the paint target with the pattern `identity` names, as one
    /// undo step. The identity is resolved to a live engine handle inside
    /// the queued work, so the resolve runs on the input queue, never the
    /// main thread; a persisted identity that no longer resolves fails
    /// the command like any other engine error.
    func fillPattern(_ identity: EngineSession.ResourceIdentity, at point: CGPoint,
                     _ settings: EngineSession.PatternFillSettings) {
        guard !refuseWhileEditingUnavailable() else { return }
        runOnPaintTarget { session, image in
            let pattern = try session.resolveResource(identity, kind: .pattern)
            try session.fillPattern(image: image, pattern: pattern, seed: point, settings)
        }
    }

    /// Draws a gradient with the selected gradient resource `identity`
    /// names, one undo step on the paint target. The persistent identity
    /// — never a session handle — is resolved to a live resource inside
    /// the queued engine job, so a gradient chosen before a restart, or
    /// one whose file was moved, reports NOT_FOUND on the engine queue
    /// rather than binding a stale handle here. Settings and endpoints
    /// are captured by value; no native call runs on the main thread.
    func gradientResource(_ identity: EngineSession.ResourceIdentity,
                          from: CGPoint, to: CGPoint,
                          settings: EngineSession.ResourceGradientSettings) {
        guard !refuseWhileEditingUnavailable() else { return }
        runOnPaintTarget { session, image in
            let handle = try session.resolveResource(identity, kind: .gradient)
            try session.gradient(image: image, resource: handle, from: from, to: to, settings: settings)
        }
    }

    /// The menu commands act on the layer the engine selects when they
    /// run — layer 0, the adapter's "selected layer at execution" — so a
    /// creation or pick queued ahead of them is what they hit, not the
    /// id the interface last saw selected. Palette rows name their
    /// layer explicitly instead.
    func layerCommand(_ command: EngineSession.LayerCommand) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        // Batch commands are unsupported: while more than one layer is
        // selected every command but New Layer (which creates and
        // selects a fresh row) refuses instead of silently acting on
        // the primary layer alone.
        if LayerSelectionPolicy.gates(command) {
            guard !refuseSingleLayerCommand(LayerSelectionPolicy.actionTitle(for: command)) else { return }
        }
        switch command {
        case .new, .duplicate, .delete, .mergeDown, .flatten:
            // The command's result becomes or replaces the paint target
            // once it lands; the engine selects it natively.
            enqueueTargetCommand { session, image in
                _ = try session.layerCommand(command, image: image)
            }
        case .raise, .lower, .toTop, .toBottom:
            run { session, image in _ = try session.layerCommand(command, image: image) }
        case .fitToImage, .trimToContent, .rasterize:
            // Pixel edits like the layer transforms: a mask or channel
            // paint target refuses them.
            guard !refuseWhileTargetPending() else { return }
            guard !isMaskTargetActive else { return refuseMaskEdit() }
            guard !isChannelTargetActive else { return refuseChannelTransform() }
            run { session, image in _ = try session.layerCommand(command, image: image) }
        case .restoreSource:
            // Restoration can reload a linked file and must use the
            // confirmed engine-wide exclusive route. Ordinary input
            // dispatch refuses it rather than starting file I/O here.
            onError?("Use the confirmed restore command.")
            NSSound.beep()
        }
    }

    /// Layer ▸ Rasterize Layer… after its confirmation sheet approved:
    /// turns the genuine text, link or vector layer `layer` pixel-behaving
    /// while its structured source is retained, as one undo step. The id
    /// is explicit and was captured before the sheet — never layer 0, the
    /// engine's selection or the front window's — and a deleted or stale
    /// id travels to the engine as-is and comes back NOT_FOUND, never
    /// retargeted. The work is counted and routed on the input queue
    /// behind every accepted edit. The completion receives the Result on
    /// the main actor exactly once; failures are also reported through
    /// `onError`. A closing or busy document refuses without queueing.
    func rasterizeLayerSource(_ layer: Int32,
                              completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else {
            onError?(DocumentError.closed.localizedDescription)
            return completion(.failure(DocumentError.closed))
        }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen, !EngineActivity.shared.isBusy else {
            onError?(DocumentError.busy.localizedDescription)
            return completion(.failure(DocumentError.busy))
        }
        guard !refuseSingleLayerCommand("Rasterize Layer", on: layer) else {
            return completion(.failure(DocumentError.multipleLayersSelected(
                LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Rasterize Layer")!)))
        }
        endPendingUserEdits()
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result<Void, Error> { _ = try session.layerCommand(.rasterize, image: image, layer: layer) }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                if case .failure(let error) = result { self.onError?(String(describing: error)) }
                completion(result)
            }
        }
    }

    /// Layer ▸ Restore Layer Source… after its confirmation sheet
    /// approved: discards the pixel edits of the rasterized layer `layer`
    /// and regenerates it from its retained text, path or linked source,
    /// as one undo step (a linked layer reloads its file when readable,
    /// otherwise it resumes from the retained source). Same explicit-id
    /// and NOT_FOUND rules as `rasterizeLayerSource`. A restore may load
    /// a file natively, so it never goes through the ordinary input
    /// queue: it takes the engine-wide exclusive admission like a profile
    /// conversion — pending edits end, accepted input in every document
    /// drains first, and the work stays counted in `pendingWork` until the
    /// completion, so a close waits for it. The completion receives the
    /// Result on the main actor exactly once, after a reload when the
    /// document is still alive; failures are also reported through
    /// `onError`.
    func restoreLayerSource(_ layer: Int32,
                            completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else {
            onError?(DocumentError.closed.localizedDescription)
            return completion(.failure(DocumentError.closed))
        }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen, !EngineActivity.shared.isBusy else {
            onError?(DocumentError.busy.localizedDescription)
            return completion(.failure(DocumentError.busy))
        }
        guard !refuseSingleLayerCommand("Restore Layer Source", on: layer) else {
            return completion(.failure(DocumentError.multipleLayersSelected(
                LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Restore Layer Source")!)))
        }
        endPendingUserEdits()
        enqueueExclusive(label: "Restoring the layer's source", rejected: {
            self.onError?(DocumentError.busy.localizedDescription)
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result<Void, Error> { _ = try session.layerCommand(.restoreSource, image: image, layer: layer) }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                if case .failure(let error) = result { self.onError?(String(describing: error)) }
                completion(result)
            }
        }
    }

    /// Layer ▸ New Layer Group: inside the active group as its first
    /// child, else directly above the active layer in the same parent.
    /// The engine selects the new group. Placement is read from the
    /// layers as the queue leaves them — a creation or pick queued
    /// ahead of this call moves the group's spot.
    func createGroup() {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in
            let fresh = try session.layers(image)
            let placement = LayerTree(layers: fresh)
                .newGroupPlacement(nearActive: fresh.first(where: \.isSelected)?.id)
            _ = try session.createGroup(image: image, parent: placement.parent,
                                        index: Int32(placement.index))
        }
    }

    /// A drop in the Layers outline: `item` to `rawIndex` among
    /// `parent`'s children (`parent` 0: the top level). `rawIndex` is the
    /// position in the child list as displayed; the tree validates the
    /// same-document ids, groups, cycles and range and adjusts the index
    /// for the item's removal before the engine is asked.
    func moveLayer(_ item: Int32, toParent parent: Int32, atIndex rawIndex: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Move Layer") else { return }
        switch LayerTree(layers: layers).resolveDrop(item: item, ontoParent: parent, at: rawIndex) {
        case .unchanged:
            return
        case .invalid:
            onError?("The layer cannot be moved there.")
            NSSound.beep()
            return
        case .move(let parent, let index):
            endPendingUserEdits()
            run { session, image in try session.reparentLayer(item, image: image, toParent: parent, index: index) }
        }
    }

    /// Sets `item`'s locks in `lock` to `locked` as one undo step.
    func setLayerLocks(_ item: Int32, _ lock: EngineSession.LayerLocks, to locked: Bool) {
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        run { session, image in
            try session.setLayerLocks(item, image: image, mask: lock, values: locked ? lock : [])
        }
    }

    /// Toggles `item`'s own `lock`, reading the state the engine last
    /// reported (an inherited lock is left alone — toggles act on the
    /// item's own bits).
    func toggleLocks(_ item: Int32, _ lock: EngineSession.LayerLocks) {
        guard !refuseSingleLayerCommand("Lock \(lock.name)") else { return }
        setLayerLocks(item, lock, to: !(layerLocks[item]?.local.contains(lock) ?? false))
    }

    func changeLayer(_ layer: Int32, _ change: EngineSession.LayerChange) {
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        run { session, image in try session.changeLayer(layer, image: image, change) }
    }

    /// Moves the active drawable. While its mask is the edit target the
    /// engine has no mask move — the mask's offset is part of the layer
    /// — so the gesture refuses rather than silently moving the layer.
    /// An active floating selection stays gated with the resolve-first
    /// reason here: its pixels move only through the specific captured
    /// `moveFloatingSelection(by:completion:)`, never through this
    /// ordinary-layer path.
    func moveActiveLayer(by offset: CGSize) {
        guard let layer = activeLayer, offset != .zero,
              !refuseWhileEditingUnavailable(), !refuseWhileTargetPending() else { return }
        guard !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Move Layer") else { return }
        guard !isMaskTargetActive else { return refuseMaskEdit() }
        guard !isChannelTargetActive else { return refuseChannelTransform() }
        run { session, image in try session.moveLayer(layer, image: image, by: offset) }
    }

    /// Refuses an edit the mask target cannot take, saying why.
    private func refuseMaskEdit() {
        onError?("Finish mask editing first; a mask cannot be moved or transformed on its own.")
        NSSound.beep()
    }

    private func refuseChannelTransform() {
        onError?("Return to Layers before moving, transforming or stroking a path; the current channel cannot take that edit.")
        NSSound.beep()
    }

    func transformImage(_ transform: EngineSession.Transform) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        run { session, image in try session.transformImage(image, transform) }
    }

    func transformActiveLayer(_ transform: EngineSession.Transform) {
        guard let layer = activeLayer,
              !refuseWhileEditingUnavailable(), !refuseWhileTargetPending() else { return }
        guard !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Transform Layer", on: layer) else { return }
        guard !isMaskTargetActive else { return refuseMaskEdit() }
        guard !isChannelTargetActive else { return refuseChannelTransform() }
        run { session, image in try session.transformLayer(layer, image: image, transform) }
    }

    // MARK: Channels

    func setComponentActive(_ component: EngineSession.Components, to enabled: Bool) {
        guard !refuseWhileFloatingActive() else { return }
        changeComponents(component, enabled: enabled, editing: true)
    }

    func setComponentVisible(_ component: EngineSession.Components, to enabled: Bool) {
        changeComponents(component, enabled: enabled, editing: false)
    }

    private func changeComponents(_ component: EngineSession.Components, enabled: Bool, editing: Bool) {
        guard !refuseWhileEditingUnavailable(), let state = components else { return }
        let mask = component.intersection(state.supported)
        guard !mask.isEmpty else { return }
        endPendingUserEdits()
        nextChannelIntent += 1
        let intent = ComponentIntent(version: nextChannelIntent,
            activeMask: editing ? mask : [], activeValues: editing && enabled ? mask : [],
            visibleMask: editing ? [] : mask, visibleValues: !editing && enabled ? mask : [])
        componentIntents.append(intent)
        mirrorChannelIntents()
        let work: (EngineSession, Int32) throws -> Void = { session, image in
            try session.setComponents(image, activeMask: intent.activeMask, activeValues: intent.activeValues,
                                      visibleMask: intent.visibleMask, visibleValues: intent.visibleValues)
        }
        let finished: @MainActor (Result<Void, Error>) -> Void = { _ in
            self.componentIntents.removeAll { $0.version == intent.version }
            try? self.reload()
        }
        if editing {
            enqueueTargetCommand(work, completion: finished)
        } else {
            // Display-only state must never reopen a failed paint target.
            enqueue(on: inputQueue) { [session, image] in
                let result = Result { try work(session, image) }
                DispatchQueue.main.async {
                    if case .failure(let error) = result { self.report(error) }
                    finished(result)
                }
            }
            onStateChange?()
        }
    }

    func saveSelectionToChannel(name: String? = nil,
                                completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        enqueueTargetCommand({ session, image in
            _ = try session.channelFromSelection(image, name: name)
        }, completion: completion)
    }

    func duplicateChannel(_ id: Int32) {
        guard !refuseWhileEditingUnavailable(), !refuseWhileFloatingActive(),
              channels.contains(where: { $0.id == id }) else { return }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in
            _ = try session.channelCommand(.duplicate, channel: id, image: image)
        }
    }

    func deleteChannel(_ id: Int32) {
        guard !refuseWhileEditingUnavailable(), !refuseWhileFloatingActive(),
              let row = channels.first(where: { $0.id == id }) else { return }
        guard !row.isQuickMask else {
            onError?("Turn off Quick Mask to remove its channel.")
            return
        }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in
            _ = try session.channelCommand(.delete, channel: id, image: image)
        }
    }

    func changeChannel(_ id: Int32, _ change: EngineSession.ChannelChange,
                       completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        guard !refuseWhileEditingUnavailable(), !refuseWhileFloatingActive(),
              channels.contains(where: { $0.id == id }) else { return }
        endPendingUserEdits()
        nextChannelIntent += 1
        let version = nextChannelIntent
        if let visible = change.isVisible {
            channelVisibilityIntents[id] = (version, visible)
            mirrorChannelIntents()
            onStateChange?()
        }
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.changeChannel(id, image: image, change) }
            DispatchQueue.main.async {
                if self.channelVisibilityIntents[id]?.version == version {
                    self.channelVisibilityIntents[id] = nil
                }
                if case .failure(let error) = result { self.report(error) }
                try? self.reload()
                completion?(result)
            }
        }
    }

    func channelToSelection(_ id: Int32, operation: EngineSession.SelectOperation) {
        guard !refuseWhileEditingUnavailable(), channels.contains(where: { $0.id == id }) else { return }
        endPendingUserEdits()
        run { session, image in try session.channelToSelection(id, image: image, operation: operation) }
    }

    func setQuickMask(_ enabled: Bool) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        nextChannelIntent += 1
        let version = nextChannelIntent
        quickMaskIntent = (version, enabled)
        mirrorChannelIntents()
        enqueueTargetCommand({ session, image in
            try session.setQuickMask(image, enabled: enabled)
        }, completion: { _ in
            if self.quickMaskIntent?.version == version { self.quickMaskIntent = nil }
            try? self.reload()
        })
    }

    // MARK: Text

    /// Adds a text layer at `position` and makes it the active layer.
    func addText(_ text: String, settings: EngineSession.TextSettings, at position: CGPoint) {
        guard !text.isEmpty, !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        enqueueTargetCommand { session, image in
            _ = try session.addTextLayer(image: image, text: text, settings: settings, at: position)
        }
    }

    /// Changes a text layer's text, its look, or both, as one undo step.
    /// Empty text removes the layer, like the text editor's commit —
    /// a target-changing edit, so it queues as a target command.
    func updateText(_ layer: Int32, text: String?, settings: EngineSession.TextSettings?) {
        guard text != nil || settings != nil, !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        if text?.isEmpty == true {
            enqueueTargetCommand { session, image in
                _ = try session.layerCommand(.delete, image: image, layer: layer)
            }
            return
        }
        run { session, image in
            try session.setTextLayer(image: image, layer: layer, text: text, settings: settings)
        }
    }

    /// A text layer's text and look, read on the engine thread's queue.
    func textLayer(_ layer: Int32) -> (text: String, settings: EngineSession.TextSettings)? {
        inputQueue.sync { [session, image] in try? session.textLayer(image: image, layer: layer) }
    }

    /// Commits the Transform tool: `matrix` maps the layer's pixels to
    /// where its handles put them. The engine transforms layers only, so
    /// a mask edit target refuses rather than resampling the layer.
    func transformLayer(_ layer: Int32, matrix: CGAffineTransform,
                        interpolation: EngineSession.Interpolation) {
        guard !matrix.isIdentity, !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileTargetPending() else { return }
        guard !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Transform Layer", on: layer) else { return }
        guard !isChannelTargetActive else { return refuseChannelTransform() }
        guard maskStates[layer]?.editing != true else {
            return refuseMaskEdit()
        }
        run { session, image in
            try session.transformLayer(layer, image: image, matrix: matrix, interpolation: interpolation)
        }
    }

    func scale(toWidth width: Int, height: Int) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        run { session, image in try session.scaleImage(image, width: width, height: height) }
    }

    func resizeCanvas(width: Int, height: Int, offset: CGPoint, fill: NSColor) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        run { session, image in try session.resizeCanvas(image, width: width, height: height, offset: offset, fill: fill) }
    }

    func crop(to rect: CGRect) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        run { session, image in try session.crop(image: image, to: rect) }
    }

    // MARK: Color mode and precision

    /// Image ▸ Mode ▸ RGB / Grayscale: the whole image's color model
    /// through one core conversion, as one undo step. A conversion on a
    /// large image holds the engine, so it takes the same exclusive
    /// admission a file call gets: accepted input in every document
    /// lands first, and the work counts toward close and Quit. Asking
    /// for the current mode is a no-op — nothing queues, no undo
    /// appears; a refusal (busy, closing, an active preview) reports
    /// busy without queuing either.
    func convertMode(to mode: EngineSession.ColorMode,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        guard !refuseFloatingForCompletion(completion) else { return }
        guard colorInfo.mode != mode else { return completion(.success(())) }
        endPendingUserEdits()
        enqueueExclusive(label: "Converting to \(mode.title)", rejected: {
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result { try session.convertMode(image, to: mode) }
            DispatchQueue.main.async {
                // The conversion fires the engine's own events, whose
                // coalesced refresh may still be pending behind this one.
                if !self.isClosing { try? self.reload() }
                completion(result)
            }
        }
    }

    /// Image ▸ Precision…: the component type and transfer curve the
    /// Precision form picked, as one undo step with no dithering. Same
    /// admission, no-op and refusal rules as `convertMode`; the facade
    /// validates the combination before mutating, so a refused change
    /// leaves the image exactly as it was.
    func convertPrecision(component: EngineSession.ColorComponent, trc: EngineSession.ColorTRC,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        guard !refuseFloatingForCompletion(completion) else { return }
        guard colorInfo.component != component || colorInfo.trc != trc else {
            return completion(.success(()))
        }
        endPendingUserEdits()
        enqueueExclusive(label: "Converting precision", rejected: {
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result { try session.convertPrecision(image, component: component, trc: trc) }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                completion(result)
            }
        }
    }

    /// Image ▸ Mode ▸ Indexed…: the whole image's color model to indexed
    /// with the sheet's palette and dither settings, as exactly one undo
    /// step through `convertToIndexed`. Same admission as the other color
    /// conversions: counted engine-wide exclusive work, so accepted input
    /// in every document drains first and close/Quit wait, with the same
    /// refusal reporting (busy, closing) and no-op rule (an already indexed
    /// image changes nothing and pushes no undo). The first attempt always
    /// carries the caller's `preserveEditable` settings; only an explicit
    /// consent retries with `allowRasterize`.
    func convertToIndexed(settings: EngineSession.IndexedSettings,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        guard !refuseFloatingForCompletion(completion) else { return }
        guard colorInfo.mode != .indexed else { return completion(.success(())) }
        endPendingUserEdits()
        enqueueExclusive(label: "Converting to indexed", rejected: {
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result { try session.convertToIndexed(image, settings: settings) }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                completion(result)
            }
        }
    }

    // MARK: Color profile

    /// Image ▸ Color Profile ▸ Assign…: embed the ICC profile at `path`
    /// without converting pixel values, or discard the embedded profile
    /// when `path` is nil, as one undo step. Same admission as the color
    /// conversions — counted engine-wide exclusive work, so accepted
    /// input in every document drains first and close/Quit wait — with
    /// the same refusal reporting (busy, closing) and no-op rules (the
    /// facade treats an equal profile as a no-op that pushes no undo).
    /// File identity is untouched; only the edit's dirty state reaches
    /// `fileState` through the reload.
    func assignProfile(path: String?,
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        guard !refuseFloatingForCompletion(completion) else { return }
        endPendingUserEdits()
        let label = path.map { "Assigning \(URL(fileURLWithPath: $0).lastPathComponent)" }
            ?? "Discarding the color profile"
        enqueueExclusive(label: label, rejected: {
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result { try session.assignProfile(image, path: path) }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                completion(result)
            }
        }
    }

    /// Image ▸ Color Profile ▸ Convert…: convert the pixels to preserve
    /// appearance in the destination profile — nil `path` for the
    /// builtin — as one undo step with the form's `intent` and
    /// `blackPointCompensation`. Same admission, refusal, no-op and
    /// file-identity rules as `assignProfile`. Indexed images refuse up
    /// front: their native palette conversion ignores intent and BPC
    /// (the facade reports UNSUPPORTED), so the document never queues it
    /// — assignment stays allowed on them.
    func convertProfile(path: String?, intent: EngineSession.ProfileIntent,
                        blackPointCompensation: Bool,
                        policy: EngineSession.ProfileConversionPolicy = .preserveEditableLayers,
                        completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        guard colorInfo.mode != .indexed else {
            return completion(.failure(DocumentError.indexedProfileConversion))
        }
        guard !refuseFloatingForCompletion(completion) else { return }
        endPendingUserEdits()
        let label = path.map { "Converting to \(URL(fileURLWithPath: $0).lastPathComponent)" }
            ?? "Converting to the built-in profile"
        enqueueExclusive(label: label, rejected: {
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result = Result {
                try session.convertProfile(image, path: path, intent: intent,
                                           blackPointCompensation: blackPointCompensation, policy: policy)
            }
            DispatchQueue.main.async {
                if !self.isClosing { try? self.reload() }
                completion(result)
            }
        }
    }

    // MARK: Paths

    /// Makes `id` the path the Path tool edits, here and in the engine.
    func selectPath(_ id: Int32) {
        guard paths.contains(where: { $0.id == id }), !refuseWhileEditingUnavailable() else { return }
        activePath = id
        if pathShapes[id] == nil { pathShapes[id] = try? session.path(id, image: image) }
        run { session, image in try session.changePath(id, image: image, select: true) }
        onStateChange?()
    }

    /// Adds a path with `shape` and makes it the active one. Waits for the
    /// engine, so the next edit knows the path.
    @discardableResult
    func addPath(_ shape: VectorPath) -> Int32? {
        guard !refuseWhileEditingUnavailable() else { return nil }
        let result = inputQueue.sync { [session, image] in
            Result { try session.setPath(nil, image: image, shape) }
        }
        switch result {
        case .success(let id):
            activePath = id
            pathShapes[id] = shape
            try? reload()
            return id
        case .failure(let error):
            report(error)
            return nil
        }
    }

    /// Replaces the shape of path `id` as one undo step. The canvas shows
    /// the new shape at once.
    func updatePath(_ id: Int32, to shape: VectorPath) {
        guard !refuseWhileEditingUnavailable() else { return }
        pathShapes[id] = shape
        pendingPathEdits[id, default: 0] += 1
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.setPath(id, image: image, shape) }
            DispatchQueue.main.async {
                self.pendingPathEdits[id, default: 1] -= 1
                if case .failure(let error) = result {
                    self.report(error)
                    try? self.reload()
                }
            }
        }
        onStateChange?()
    }

    func renamePath(_ id: Int32, to name: String) {
        guard !name.isEmpty, !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.changePath(id, image: image, name: name) }
    }

    func setPathVisible(_ id: Int32, _ visible: Bool) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.changePath(id, image: image, visible: visible) }
    }

    func deletePath(_ id: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.deletePath(id, image: image) }
    }

    /// Select ▸ From Path: the active path's area, combined by `operation`.
    func selectFromPath(_ id: Int32, operation: EngineSession.SelectOperation = .replace) {
        guard !refuseWhileEditingUnavailable() else { return }
        var options = EngineSession.SelectOptions()
        options.operation = operation
        run { session, image in try session.selectPath(id, image: image, options: options) }
    }

    /// Layer ▸ Mask ▸ Add… on `layer` — the menus pass the active layer,
    /// the Add Mask form the layer it opened for. `edit` starts mask
    /// editing at once: it replaces the paint target with a drawable
    /// whose id is unknown until the job lands, so it queues as a
    /// target command.
    func addMask(_ layer: Int32, source: EngineSession.MaskSource, edit: Bool) {
        guard layers.contains(where: { $0.id == layer }) else { return }
        guard !refuseSingleLayerCommand("Add Layer Mask", on: layer) else { return }
        if edit {
            guard !isClosing, !refuseWhileEditingUnavailable() else { return }
            guard !refuseWhileFloatingActive() else { return }
            endPendingUserEdits()
            enqueueTargetCommand { session, image in
                // addLayerMask sets the mask's EDITING flag but does not
                // select the layer; without selecting it first the new
                // target could land on a layer the engine selected last.
                try session.channelCommand(.select, channel: 0, image: image)
                try session.selectLayer(layer, image: image)
                _ = try session.addLayerMask(layer, image: image, source: source, edit: true)
            }
        } else {
            guard !refuseWhileFloatingActive() else { return }
            runMaskCommand { session, image in
                _ = try session.addLayerMask(layer, image: image, source: source, edit: false)
            }
        }
    }

    /// Layer ▸ Mask ▸ Apply / Delete: bakes the active layer's mask into
    /// it or removes it. Removing the mask replaces its drawable as the
    /// paint target, so it queues as a target command. The engine
    /// refuses Apply on groups and text, link and vector layers.
    func applyMask() {
        guard let layer = activeLayer, !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Apply Mask", on: layer) else { return }
        runMaskTargetCommand { session, image in
            try session.applyLayerMask(layer, image: image, mode: .apply)
        }
    }

    func deleteMask() {
        guard let layer = activeLayer, !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Delete Mask", on: layer) else { return }
        runMaskTargetCommand { session, image in
            try session.applyLayerMask(layer, image: image, mode: .discard)
        }
    }

    /// Layer ▸ Mask ▸ Enable Mask: toggles whether the active layer's
    /// mask affects the composite.
    func toggleMaskEnabled() {
        guard let layer = activeLayer, !refuseWhileFloatingActive(),
              let state = maskState(for: layer) else { return }
        guard !refuseSingleLayerCommand("Enable Mask", on: layer) else { return }
        setMaskFlags(layer, flags: [.enabled], values: state.enabled ? [] : [.enabled])
    }

    /// Layer ▸ Mask ▸ Edit Mask: toggles mask editing on the active
    /// layer — the same target change the layer and mask thumbnails
    /// make, so it queues ahead of later input like they do. A native
    /// multi-selection exits mask editing on its own; this menu command
    /// is gated instead of silently re-entering it on the primary.
    func toggleMaskEditing() {
        guard let layer = activeLayer, !refuseWhileFloatingActive() else { return }
        guard !refuseSingleLayerCommand("Edit Mask", on: layer) else { return }
        if isMaskTargetActive { selectLayer(layer) } else { editMask(layer) }
    }

    /// Layer ▸ Mask ▸ Show Mask and the mask thumbnail's Option-click:
    /// toggles `layer`'s mask display. This is a view flag — it neither
    /// selects the layer nor changes the paint target — so an explicit
    /// per-row call keeps targeting its captured row under a
    /// multi-selection; only the active-layer menu route is gated.
    func toggleMaskShowing(_ layer: Int32? = nil) {
        guard let id = layer ?? activeLayer, !refuseWhileFloatingActive(),
              let state = maskState(for: id) else { return }
        if layer == nil {
            guard !refuseSingleLayerCommand("Show Mask", on: id) else { return }
        }
        setMaskFlags(id, flags: [.showing], values: state.showing ? [] : [.showing])
    }

    /// Layer ▸ Mask ▸ Mask to Selection ▸ …: combines the active
    /// layer's mask into the selection.
    func maskToSelection(_ operation: EngineSession.SelectOperation) {
        guard let layer = activeLayer else { return }
        guard !refuseSingleLayerCommand("Mask to Selection", on: layer) else { return }
        runMaskCommand { session, image in
            try session.layerMaskToSelection(layer, image: image, operation: operation)
        }
    }

    /// Sets mask flags on any layer — the rows' Option-click needs it
    /// for a layer that is not the active one.
    private func setMaskFlags(_ layer: Int32, flags: EngineSession.MaskFlags,
                              values: EngineSession.MaskFlags) {
        runMaskCommand { session, image in
            try session.setLayerMask(layer, image: image, flags: flags, values: values)
        }
    }

    /// The layer's mask state, reading it once when the cache missed.
    private func maskState(for layer: Int32) -> EngineSession.MaskState? {
        if let state = maskStates[layer], state.mask != 0 { return state }
        guard layers.first(where: { $0.id == layer })?.hasMask == true else { return nil }
        let state = try? session.layerMask(layer, image: image)
        if let state, state.mask != 0 { maskStates[layer] = state }
        return state?.mask != 0 ? state : nil
    }

    /// Mask commands are edits: they queue as counted input behind
    /// pending work and reload afterwards — mask flag changes report no
    /// engine event of their own (EDITING has no undo record at all), so
    /// the reload is what makes `maskStates` authoritative again.
    private func runMaskCommand(_ work: @escaping (EngineSession, Int32) throws -> Void) {
        guard !isClosing else { return }
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        enqueue(on: inputQueue, input: true) { [session, image] in
            do { try work(session, image) } catch { self.report(error) }
            DispatchQueue.main.async { try? self.reload() }
        }
    }

    /// Mask commands that remove the target drawable queue as target
    /// commands: the gate keeps an edit accepted meanwhile from
    /// capturing the drawable about to disappear.
    private func runMaskTargetCommand(_ work: @escaping (EngineSession, Int32) throws -> Void) {
        guard !isClosing else { return }
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        enqueueTargetCommand(work)
    }

    /// Edit ▸ Stroke Path: draws the path on the active layer. The
    /// engine strokes layers only — a mask target is refused rather
    /// than silently painting the layer's pixels.
    func strokePath(_ id: Int32, settings: EngineSession.LineSettings) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !isChannelTargetActive else { return refuseChannelTransform() }
        guard !isMaskTargetActive else {
            onError?("A path cannot be drawn on a mask; select the layer first.")
            NSSound.beep()
            return
        }
        runOnPaintTarget { session, image in try session.strokePath(id, image: image, settings: settings) }
    }

    /// Edit ▸ Fill Path / the Paths palette's Fill: fills the path's area
    /// on the explicit current paint target — a layer, its mask while
    /// mask editing is on, or a selected channel — with the settings'
    /// color, as one undo step ordered behind earlier accepted input.
    /// A group, a missing or a pixel-locked target is refused with an
    /// error, never silently; the engine revalidates path and target.
    func fillPath(_ id: Int32, settings: EngineSession.PathFillSettings) {
        guard !refuseWhileEditingUnavailable() else { return }
        // A stale row's id (the path is gone) runs nothing.
        guard paths.contains(where: { $0.id == id }) else { return }
        guard !refuseWhileTargetPending() else { return }
        guard let drawable = activeDrawable else {
            onError?(DocumentError.targetChanged.localizedDescription)
            NSSound.beep()
            return
        }
        if case .layer(let layer) = paintTarget,
           layers.first(where: { $0.id == layer })?.kind == .group {
            onError?("A path cannot be filled onto a layer group; select a layer, its mask or a channel.")
            NSSound.beep()
            return
        }
        if let layer = paintTarget?.layer,
           layerLocks[layer]?.effective.contains(.pixels) == true {
            onError?("Unlock the layer's pixels (or its group's) before filling a path onto it.")
            NSSound.beep()
            return
        }
        runOnPaintTarget { session, image in
            try session.fillPath(id, image: image, drawable: drawable, settings: settings)
        }
    }

    /// The Paths palette's To Vector Layer: makes a genuine vector layer
    /// from the path, above the selected layer. The engine selects it
    /// natively; the completion's authoritative reload is what makes it
    /// the interface's target. Engines without vector layers (before
    /// GIMP 3.2) are told so honestly instead of degrading to a raster.
    /// The new layer starts in the engine's default style (white fill,
    /// black stroke) — the foreground color is not applied to it.
    func toVectorLayer(_ id: Int32, name: String? = nil) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        // A stale row's id (the path is gone) runs nothing.
        guard paths.contains(where: { $0.id == id }) else { return }
        if session.supportsVectorLayers == false {
            onError?("This engine has no vector layers; they arrived in GIMP 3.2.")
            NSSound.beep()
            return
        }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in
            _ = try session.toVectorLayer(id, image: image, name: name)
        }
    }

    /// Layer ▸ Vector Style…: applies the sheet's change to the genuine
    /// vector layer `layer` as one native undo step, queued as counted
    /// input on the input queue — off the main thread, behind every
    /// accepted edit. An empty `properties` is a no-op: nothing is queued
    /// and no undo is pushed. A layer that is no longer a cached genuine
    /// vector layer — deleted, rasterized or retargeted while the sheet
    /// was up — is refused with targetChanged; busy and closed states are
    /// refused up front, and the engine's own BUSY, LOCKED, NOT_FOUND and
    /// UNSUPPORTED (pattern style, pre-3.2) answers are reported as they
    /// come. The call never rasterizes anything.
    func changeVectorLayerStyle(_ layer: Int32, _ change: EngineSession.VectorStyleChange) {
        if isClosing {
            onError?(DocumentError.closed.localizedDescription)
            return
        }
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        guard layers.contains(where: { $0.id == layer && $0.kind == .vector }) else {
            onError?(DocumentError.targetChanged.localizedDescription)
            NSSound.beep()
            return
        }
        guard !change.properties.isEmpty else { return }
        endPendingUserEdits()
        run { session, image in try session.changeVectorLayerStyle(layer, image: image, change) }
    }

    /// Re-reads the outline; the engine caches it until the selection changes.
    func refreshSelection() {
        selectionOutline = (try? session.selectionOutline(image: image)) ?? []
        selectionBounds = try? session.selectionBounds(image: image)
        onSelectionChange?()
    }

    // MARK: Committed effects

    /// Whether `effect` still names a committed effect of `drawable` as
    /// the last reload saw them — the membership guard every effect-row
    /// command takes, so a stale row cannot hit another drawable's stack.
    func canChangeEffect(_ effect: Int32, on drawable: Int32) -> Bool {
        layers.contains(where: { $0.id == drawable })
            && layerEffects[drawable]?.contains(where: { $0.id == effect }) == true
    }

    /// Sets the committed effect's name, enabled state or opacity as one
    /// undo step (`effect_change`); an empty name restores the
    /// operation's default title.
    func changeEffect(_ effect: Int32, on drawable: Int32, _ change: EngineSession.EffectChange) {
        guard canChangeEffect(effect, on: drawable), !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        run { session, image in try session.changeEffect(effect, on: drawable, image: image, change) }
    }

    /// A stack command — remove, merge or reorder — on the committed
    /// effect, as one undo step (`effect_command`). The ids are
    /// explicit: a stale row's command cannot reach another drawable's
    /// stack, and the engine's guards stay authoritative.
    func effectCommand(_ command: EngineSession.EffectCommand, effect: Int32, on drawable: Int32) {
        guard canChangeEffect(effect, on: drawable), !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        run { session, image in try session.effectCommand(command, effect: effect, on: drawable, image: image) }
    }

    // MARK: Undo

    /// Undo and redo replace the paint target like a delete does: the
    /// engine selects whatever the moved state leaves, so they queue as
    /// target commands and edits accepted meanwhile are refused instead
    /// of landing on the drawable the move is about to leave behind.
    func undo() {
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in try session.undo(image) }
    }

    func redo() {
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        enqueueTargetCommand { session, image in try session.redo(image) }
    }

    // MARK: History and snapshots

    /// The app's entry point for opening a snapshot as a document, wired
    /// by whoever owns document lifetime; nil without one.
    var snapshotHandler: ((ImageDocument) -> Void)?

    /// Image ▸ New Snapshot and the History palette's Snapshot button:
    /// asks the app for an independent copy of this image opened as a new
    /// document.
    func newSnapshot() {
        guard !refuseWhileEditingUnavailable(), let snapshotHandler else { return }
        snapshotHandler(self)
    }

    /// Queues a native duplicate behind pending input — in-flight
    /// strokes and text edits are part of the copy. The callback runs on
    /// the main actor bound to this document with the new engine image
    /// or the error, whoever is front document then. The work is counted,
    /// so a close waits for it before freeing this image.
    func snapshot(completion: @escaping @MainActor (Result<Int32, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard acceptsEdits else { return completion(.failure(DocumentError.busy)) }
        endPendingUserEdits()
        enqueueExclusive(label: "Creating a snapshot", rejected: { completion(.failure(DocumentError.busy)) }) { [session, image] in
            let result = Result { try session.duplicateImage(image) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A History palette pick: move the image to the state `position` had
    /// under `revision`, queued through input so pending text, field and
    /// stroke edits end first. When those land as a newer revision the
    /// engine refuses the pick without changing the image; the refusal
    /// is reported and the list reloads — it is never retried under the
    /// newer revision.
    func moveToHistoryState(_ position: Int32, revision: UInt64) {
        guard !refuseWhileEditingUnavailable() else { return }
        endPendingUserEdits()
        // A history move can remove the layers and masks the interface
        // paints through — its target ids are replaced like a delete's.
        enqueueTargetCommand { session, image in
            _ = try session.moveHistory(image, revision: revision, to: position)
        }
    }

    /// The engine refuses edits while a plug-in command runs (its dialog
    /// acts as a modal filter dialog), and the interface refuses them
    /// while its own filter preview is open; say why instead of failing
    /// later. `forPreviewWork` lets the preview's own updates and its
    /// commit through.
    private func refuseWhileEditingUnavailable(forPreviewWork: Bool = false) -> Bool {
        onUserCommand?()
        if let activity = EngineActivity.shared.label, !PlugInCommands.isRunning {
            onError?("\(activity)… Wait for it to finish before editing.")
            return true
        }
        if isClosing || isSavingForClose || isTransferringClipboard {
            onError?(isClosing ? DocumentError.closed.localizedDescription : DocumentError.busy.localizedDescription)
            return true
        }
        if filterPreviewIsOpen, !forPreviewWork {
            onError?("Apply or cancel the filter preview first.")
            NSSound.beep()
            return true
        }
        guard let running = PlugInCommands.running else { return false }
        let title = running.procedure.label.replacingOccurrences(of: "…", with: "")
        onError?("Finish or cancel \u{201C}\(title)\u{201D} first.")
        NSSound.beep()
        return true
    }

    /// Asks the window to commit in-flight field and text edits and end
    /// an active stroke; the callback itself can run document commands
    /// (committing text does), so it never re-enters.
    private var endingPendingEdits = false
    private func endPendingUserEdits() {
        guard let callback = onWillChangeLayers, !endingPendingEdits else { return }
        endingPendingEdits = true
        callback()
        endingPendingEdits = false
    }

    func finishInputForEngineActivity() {
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
    }

    // MARK: Plug-in commands

    /// Whether the command can run on the selected layers. Asks the engine
    /// once per change of the image.
    func canRun(_ procedure: EngineSession.Procedure) -> Bool {
        if procedureSensitivity == nil {
            let rows = (try? session.procedures(image: image)) ?? []
            procedureSensitivity = Dictionary(rows.map { ($0.name, $0.isSensitive) }, uniquingKeysWith: { a, _ in a })
        }
        return procedureSensitivity?[procedure.name] ?? false
    }

    /// Runs a plug-in command on the selected layers. Interactively the
    /// plug-in shows its own dialog; the call completes when it finished.
    func run(_ procedure: EngineSession.Procedure, mode: EngineSession.RunMode,
             completion: @escaping @MainActor (Result<EngineSession.RunOutcome, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !EngineActivity.shared.isBusy else { return completion(.failure(DocumentError.busy)) }
        // A plug-in runs on the engine's whole selected-layer list; under
        // a multi-selection that would be a batch operation, so it refuses.
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: procedure.label.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        enqueueExclusive(label: procedure.label, rejected: { completion(.failure(DocumentError.busy)) }) { [session, image] in
            let result = Result { try session.runProcedure(procedure.name, image: image, mode: mode) }
            DispatchQueue.main.async {
                try? self.reload()
                completion(result)
            }
        }
    }

    enum DocumentError: LocalizedError {
        case closed, busy, noLayer, targetChanged, indexedProfileConversion
        case multipleLayersSelected(String)
        var errorDescription: String? {
            switch self {
            case .closed: return "This image has already closed."
            case .busy: return "Wait for the current image operation to finish."
            case .noLayer: return "There is no layer to work on."
            case .targetChanged: return "The selected layer, mask or channel changed. Select a paint target again."
            case .multipleLayersSelected(let reason): return reason
            case .indexedProfileConversion:
                return "An indexed image cannot convert its color profile: the palette conversion ignores the intent and black-point settings. Convert the image to RGB first."
            }
        }
    }

    /// After Save was chosen on close, stop accepting new edits until
    /// the write either fails/cancels or the image is destroyed.
    func beginCloseSave() -> Bool {
        guard !refuseWhileEditingUnavailable() else { return false }
        isSavingForClose = true
        onStateChange?()
        return true
    }

    func cancelCloseSave() {
        isSavingForClose = false
        onStateChange?()
    }

    enum ClipboardOperation { case layer, merged, cutLayer }

    /// Pixel work stays serial with input; the pasteboard transaction is
    /// asynchronous on the main actor. Never block this queue waiting for
    /// AppKit, which can synchronously read text/path metadata from it.
    func copyPixels(_ operation: ClipboardOperation, background: NSColor,
                    consume: @escaping @MainActor (ClipboardImage.Encoded) throws -> Void,
                    completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        // Copy/Cut of the active layer would silently read only the
        // primary layer under a multi-selection; Copy Merged reads the
        // whole composite and stays available.
        if operation != .merged,
           let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: operation == .cutLayer ? "Cut" : "Copy") {
            return completion(DocumentError.multipleLayersSelected(reason))
        }
        // A pending target command does not refuse the copy: the read
        // and a cut's deferred clear resolve the native drawable on the
        // input queue as one pair — only a rejected pick or a missing
        // target is refused here.
        if operation != .merged, activeDrawable == nil, pendingTargetCommands.isEmpty {
            return completion(DocumentError.targetChanged)
        }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !EngineActivity.shared.isBusy, !(operation == .cutLayer && filterPreviewIsOpen) else {
            return completion(DocumentError.busy)
        }
        isTransferringClipboard = true
        let cutting = operation == .cutLayer
        // Track the encoding/main-actor stage independently of the short
        // pixel-read job; it must also drain before destroying the image.
        pendingWork += 1
        if cutting { pendingInput += 1 }
        onStateChange?()
        enqueue(on: inputQueue) { [session, image] in
            let pixels = Result {
                if operation != .merged { try self.requirePaintTarget() }
                return try session.copyPixels(image, merged: operation == .merged)
            }
            self.clipboardQueue.async {
                let result = pixels.flatMap { image in Result { try image.encoded() } }
                DispatchQueue.main.async {
                    defer { self.jobDidFinish(input: cutting) }
                    guard !self.isClosing else { return self.finishClipboard(DocumentError.closed, completion: completion) }
                    do { try consume(result.get()) } catch {
                        return self.finishClipboard(error, completion: completion)
                    }
                    guard !self.isClosing else {
                        return self.finishClipboard(DocumentError.closed, completion: completion)
                    }
                    guard cutting else { return self.finishClipboard(nil, completion: completion) }
                    // No edits were accepted between the copy and clear.
                    self.enqueue(on: self.inputQueue, input: true) {
                        let error: Error?
                        do {
                            try self.requirePaintTarget()
                            try session.clearPixels(image, background: background)
                            error = nil
                        }
                        catch let failure { error = failure }
                        DispatchQueue.main.async { self.finishClipboard(error, completion: completion) }
                    }
                }
            }
        }
    }

    private func finishClipboard(_ error: Error?, completion: @MainActor (Error?) -> Void) {
        isTransferringClipboard = false
        if !isClosing { try? reload() }
        completion(error)
    }

    /// Edit ▸ Paste: the payload becomes a new layer the engine selects,
    /// so it queues as a target command. `origin` resolves the placement
    /// on the queue once the payload is decoded. While a floating
    /// selection is active an ordinary Paste would implicitly anchor it,
    /// so it is refused with the resolve-first reason; without one its
    /// behavior is unchanged.
    func pastePixels(_ payload: ClipboardImage.Payload, origin: @escaping (ClipboardImage) -> CGPoint,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseFloatingForCompletion(completion) else { return }
        // An ordinary Paste would attach to the primary layer alone.
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Paste") {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        endPendingUserEdits()
        enqueueTargetCommand({ session, image in
            let pixels = try payload.decoded()
            _ = try session.pastePixels(image, pixels: pixels, at: origin(pixels))
        }, completion: completion)
    }

    // MARK: Floating selection (Paste Into)

    /// Whether Edit ▸ Paste Into may run on the current paint target,
    /// from cached state only: an explicit drawable id (never 0), or the
    /// refusal reason. Menu validation and the controller's capture read
    /// this; no engine call happens here.
    var pasteIntoReadiness: FloatingControlsLogic.PasteIntoTarget {
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Paste Into") {
            return .init(drawable: nil, reason: reason)
        }
        return FloatingControlsLogic.pasteIntoTarget(activeDrawable, state: floatingState, layers: layers,
                                              maskStates: maskStates, channels: channels, sources: layerSources,
                                              locks: layerLocks, acceptsEdits: acceptsEdits,
                                              pendingTarget: !pendingTargetCommands.isEmpty)
    }

    /// Whether resolving the active floating selection with `command`
    /// may run now, from cached state only — the palette's Anchor / New
    /// Layer / Discard controls and their menu items validate through it.
    func floatingResolutionReadiness(_ command: EngineSession.FloatingCommand) -> FloatingControlsLogic.Readiness {
        FloatingControlsLogic.resolution(command, state: floatingState, layers: layers, maskStates: maskStates,
                                         sources: layerSources, locks: layerLocks, acceptsEdits: acceptsEdits,
                                         pendingTarget: !pendingTargetCommands.isEmpty)
    }

    /// Edit ▸ Paste Into: the payload's pixels become a floating
    /// selection attached to the explicit `target` drawable — the
    /// document and the target id are captured with the payload here and
    /// never fall back to the front document or a layer-0 target at
    /// execution. The payload is decoded on the input queue and the
    /// paste runs as one counted, serial target command behind every
    /// accepted edit, so a close drains it before destroying the image.
    func pasteIntoPixels(_ payload: ClipboardImage.Payload, target: Int32,
                         completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Paste Into") {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseWhileTargetPending() else { return completion(.failure(DocumentError.busy)) }
        let readiness = FloatingControlsLogic.pasteIntoTarget(target, state: floatingState, layers: layers,
            maskStates: maskStates, channels: channels, sources: layerSources, locks: layerLocks,
            acceptsEdits: acceptsEdits, pendingTarget: !pendingTargetCommands.isEmpty)
        guard let drawable = readiness.drawable else {
            return completion(.failure(FloatingError.refused(readiness.reason ?? DocumentError.busy.localizedDescription)))
        }
        endPendingUserEdits()
        enqueueTargetCommand({ session, image in
            let pixels = try payload.decoded()
            _ = try session.pasteInto(image, target: drawable, pixels: pixels)
        }, completion: completion)
    }

    /// Resolves the active floating selection with `command` — Anchor,
    /// New Layer or Discard — as one counted, serial target command. The
    /// expected floating id is the one this document cached at its last
    /// reload, captured now and passed explicitly: the engine never
    /// falls back to whichever floating selection happens to be active,
    /// and a stale or zero id fails with NOT_FOUND / INVALID_ARGUMENT.
    func resolveFloatingSelection(_ command: EngineSession.FloatingCommand,
                                  completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseWhileTargetPending() else { return completion(.failure(DocumentError.busy)) }
        let expected = floatingState.floating
        let readiness = floatingResolutionReadiness(command)
        guard readiness.allowed else {
            return completion(.failure(FloatingError.refused(readiness.reason
                ?? "The floating selection cannot be resolved now.")))
        }
        endPendingUserEdits()
        enqueueTargetCommand({ session, image in
            _ = try session.floatingCommand(command, image: image, expected: expected)
        }, completion: completion)
    }

    /// Moves the pixels of the active floating selection by `offset`, as
    /// one counted, serial input command behind every accepted edit —
    /// one native undo step when it lands (a same-position move follows
    /// the engine's own no-op semantics). The expected floating state
    /// (floating id, attachment target, target kind) is captured here
    /// from the cache and re-read FRESH on the worker immediately before
    /// the move: if the floating selection changed or resolved meanwhile
    /// — a Detach turns the same id into an ordinary layer — the move is
    /// refused with no mutation and no undo, visibly through `onError`
    /// and the completion. The attachment and the unresolved floating
    /// state are preserved; the move never anchors, and native move
    /// readiness/position locks stay authoritative. Unlike an ordinary
    /// layer move this is not a target command: the floating layer stays
    /// the paint target, so the pending-target gate only refuses edits
    /// accepted while another command's target is still unknown.
    func moveFloatingSelection(by offset: CGSize,
                               completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: "Move Floating Selection") {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseWhileTargetPending() else { return completion(.failure(DocumentError.busy)) }
        let expected = floatingState
        let readiness = FloatingControlsLogic.floatingMoveReadiness(expected,
            acceptsEdits: acceptsEdits, pendingTarget: !pendingTargetCommands.isEmpty)
        guard readiness.allowed else {
            return completion(.failure(FloatingError.refused(readiness.reason
                ?? "The floating selection cannot be moved now.")))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1 // Include the deferred cache/completion stage in close drain.
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result<Void, Error> {
                // Fresh read on the worker, immediately before the move:
                // the captured id must still be the active floating
                // selection with the same attachment — never a detached
                // ordinary layer reusing the id.
                let fresh = try session.floatingSelection(image)
                guard FloatingControlsLogic.floatingStateStillMatches(expected: expected, fresh: fresh) else {
                    throw FloatingError.refused("The floating selection changed before the move, so nothing was moved.")
                }
                try session.moveLayer(expected.floating, image: image, by: offset)
            }
            // Moving changes bounds, dirty/history and the floating cache;
            // collect those reads on the worker rather than blocking AppKit.
            let refresh: Result<(EngineSession.ImageInfo, [EngineSession.Layer], EngineSession.UndoInfo,
                                 EngineSession.History, EngineSession.FloatingState), Error>?
            if case .success = result {
                refresh = Result { (try session.info(image), try session.layers(image), try session.undoInfo(image),
                                    try session.history(image), try session.floatingSelection(image)) }
            } else { refresh = nil }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    if !self.isClosing {
                        if case .success(let state)? = refresh {
                            self.stateVersion += 1
                            self.procedureSensitivity = nil
                            self.info = state.0
                            self.fileState.syncDirty(state.0.isDirty)
                            self.layers = state.1
                            self.undoInfo = state.2
                            self.history = state.3
                            self.floatingState = state.4
                            self.onStateChange?()
                        } else if case .failure(let error)? = refresh {
                            self.onError?(String(describing: error))
                        }
                        if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    }
                    completion(result)
                }
            }
        }
    }

    /// The Select ▸ Float … action title for `mode`, used in the
    /// multi-selection refusal.
    private static func floatActionTitle(_ mode: EngineSession.FloatMode) -> String {
        mode == .move ? "Float Selected Pixels" : "Float a Copy"
    }

    /// Whether Select ▸ Float … may run on the current paint target in
    /// `mode`, from cached state only: a non-empty selection, no active
    /// floating selection, exactly one selected layer (a multi-selection
    /// refuses with the choose-one-layer reason), and an explicit target
    /// drawable (never 0) passing the mode's lock/source gates. Menu
    /// validation and the controller's capture read this; no engine call
    /// happens here.
    func floatReadiness(_ mode: EngineSession.FloatMode) -> FloatingControlsLogic.FloatTarget {
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: Self.floatActionTitle(mode)) {
            return .init(drawable: nil, reason: reason)
        }
        return FloatingControlsLogic.floatTarget(activeDrawable, mode: mode,
                                                 hasSelection: selectionBounds != nil, state: floatingState,
                                                 layers: layers, maskStates: maskStates, channels: channels,
                                                 sources: layerSources, locks: layerLocks, acceptsEdits: acceptsEdits,
                                                 pendingTarget: !pendingTargetCommands.isEmpty)
    }

    /// Select ▸ Float Selected Pixels (`.move`) / Float a Copy (`.copy`):
    /// floats the current selection off the explicit `target` drawable as
    /// one counted, serial target command. The document, the target id
    /// and the mode are captured here at command time — the queued work
    /// never falls back to the front document or a layer-0 target — and
    /// the completion's reload makes the cached floating state and the
    /// paint target authoritative again. In-flight field/text edits and
    /// an active stroke drain first: both enqueue on this same serial
    /// input queue ahead of the target command, so the float runs on the
    /// committed image instead of reporting BUSY under an open stroke.
    /// A close drains the accepted command before the image is
    /// destroyed. MOVE cuts the source and clears the selection mask;
    /// COPY preserves the source and still clears it — the engine owns
    /// both, the native side revalidates every gate.
    func floatSelectedPixels(mode: EngineSession.FloatMode, target: Int32,
                             completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: Self.floatActionTitle(mode)) {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseWhileTargetPending() else { return completion(.failure(DocumentError.busy)) }
        let readiness = FloatingControlsLogic.floatTarget(target, mode: mode,
            hasSelection: selectionBounds != nil, state: floatingState, layers: layers,
            maskStates: maskStates, channels: channels, sources: layerSources, locks: layerLocks,
            acceptsEdits: acceptsEdits, pendingTarget: !pendingTargetCommands.isEmpty)
        guard let drawable = readiness.drawable else {
            return completion(.failure(FloatingError.refused(readiness.reason ?? DocumentError.busy.localizedDescription)))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        enqueueTargetCommand({ session, image in
            _ = try session.floatSelection(image, target: drawable, mode: mode)
        }, completion: completion)
    }

    // MARK: Files

    /// Whether closing now could lose work: edits the engine counted, an
    /// imported image never written as XCF, edits still queued on their
    /// way to the engine, or a plug-in command still working on it.
    var hasUnsavedChanges: Bool {
        fileState.hasUnsavedChanges || pendingInput > 0
            || PlugInCommands.running?.document === self
    }

    func export(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard, !PlugInCommands.isRunning else { return completion(DocumentError.busy) }
        enqueueExclusive(label: "Exporting \(url.lastPathComponent)", rejected: { completion(DocumentError.busy) }) { [session, image] in
            let result: Error?
            do { try session.export(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async {
                if result == nil { self.fileState.noteExported(to: url) }
                completion(result)
            }
        }
    }

    func save(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard, !PlugInCommands.isRunning else { return completion(DocumentError.busy) }
        enqueueExclusive(label: "Saving \(url.lastPathComponent)", rejected: { completion(DocumentError.busy) }) { [session, image] in
            let result: Error?
            do { try session.save(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `label` names the engine-wide activity while the copy is written;
    /// a recovery pass labels its background copy as such.
    func saveCopy(to url: URL, label: String = "Saving a copy", completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning else { return completion(DocumentError.busy) }
        enqueueExclusive(label: label, rejected: { completion(DocumentError.busy) }) { [session, image] in
            let result: Error?
            do { try session.saveCopy(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A native save to `url` succeeded: it becomes the image's file —
    /// name, dirty state and all.
    func noteSaved(to url: URL) {
        fileState.noteSaved(to: url)
        name = url.lastPathComponent
        try? reload()
    }

    /// Whether the engine is known to place genuine link layers (GIMP
    /// 3.2 and later); nil when its version does not say, in which case
    /// the facade's own UNSUPPORTED answer reports the rest. Place's
    /// menu item and action consult this.
    var supportsLinkLayers: Bool? { session.supportsLinkLayers }

    /// Whether the engine is known to make genuine vector layers from
    /// paths (GIMP 3.2 and later); nil when its version does not say, in
    /// which case the facade's own UNSUPPORTED answer reports the rest.
    /// To Vector Layer's menu item and action consult this.
    var supportsVectorLayers: Bool? { session.supportsVectorLayers }

    /// What a file import did, for the caller's status line.
    enum ImportOutcome: Equatable {
        /// Open as Layers: the file's layers joined this image.
        case openedLayers
        /// Place: the file joined this image as a link layer.
        case placedLink
        /// The engine's loader reported a cancellation; nothing changed.
        case cancelled
    }

    /// File ▸ Open as Layers…: every layer of the file at `url` lands in
    /// this image above the selected layer — or inside a selected group —
    /// centered on the canvas, as one undo step.
    func openLayers(from url: URL,
                    completion: @escaping @MainActor (Result<ImportOutcome, Error>) -> Void) {
        importFile(url, asLink: false, completion: completion)
    }

    /// File ▸ Place…: the file at `url` joins this image as a genuine
    /// link layer — it keeps the file reference and re-renders when the
    /// source changes — above the selected layer, as one undo step.
    func placeLink(from url: URL,
                   completion: @escaping @MainActor (Result<ImportOutcome, Error>) -> Void) {
        importFile(url, asLink: true, completion: completion)
    }

    /// Shared admission for both imports: end accepted edits, take the
    /// engine-wide exclusive gate so every document's input drains and
    /// the busy label holds for the whole load — including a file
    /// plug-in's modal dialog — then run the facade call off the main
    /// thread. The work counts toward close and Quit like a save, so a
    /// closing image is never destroyed under a running load and its
    /// completion still lands.
    ///
    /// The engine selects the imported result natively; the completion's
    /// reload is what makes it the interface's target — it never
    /// selects anything itself. File identity (native file, imported
    /// source, name) is untouched; only the edit's own dirty state
    /// reaches `fileState` through the reload. A failed or cancelled
    /// load adds nothing and leaves the image editable; the facade's
    /// native error reaches the caller.
    private func importFile(_ url: URL, asLink: Bool,
                            completion: @escaping @MainActor (Result<ImportOutcome, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning else {
            return completion(.failure(DocumentError.busy))
        }
        let label = asLink ? "Placing \(url.lastPathComponent)" : "Opening \(url.lastPathComponent) as layers"
        enqueueExclusive(label: label, rejected: { completion(.failure(DocumentError.busy)) }) { [session, image] in
            let result = Result<ImportOutcome, Error> {
                if asLink {
                    _ = try session.placeLink(image: image, path: url.path)
                    return .placedLink
                }
                let imported = try session.openLayers(image: image, path: url.path)
                // Importing a stack is not a user multi-selection. Keep
                // its primary immediately editable while the exclusive
                // load still owns the target; no later UI pick can race it.
                if let primary = imported.first {
                    try session.selectLayers([primary], image: image)
                }
                return .openedLayers
            }
            if case .success = result {
                // Admission drained this queue and still holds the global
                // gate. Keep the queue-owned validity flag confined to it.
                self.inputQueue.sync { self.paintTargetIsValid = true }
            }
            DispatchQueue.main.async {
                if case .success = result { self.rejectedTargetPick = false }
                // The reload mirrors the engine's native selection — the
                // imported top layer or the placed link — as the target.
                // A closing image skips it: the drain destroys it next.
                if !self.isClosing { try? self.reload() }
                switch result {
                case .success(let outcome):
                    completion(.success(outcome))
                case .failure(let error):
                    if Self.isLoaderCancellation(error) {
                        completion(.success(.cancelled))
                    } else {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// The facade reports a loader's cancel as CANCELLED with no engine
    /// message; it is an outcome, not an error.
    private static func isLoaderCancellation(_ error: Error) -> Bool {
        (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_CANCELLED.rawValue)
    }

    // MARK: Printing

    /// Renders the committed composite into an immutable snapshot fitted
    /// to `imageablePoints`, behind every accepted edit and counted
    /// toward close like a file write. The render rides the exclusive
    /// engine queue in stripes, so queued strokes, text and field
    /// commits land in the snapshot and no single engine call
    /// monopolizes its thread. The size is computed inside the job from
    /// the dimensions the engine reports then: a queued crop, resize or
    /// rotation must not leave the snapshot fitted for the size the
    /// image used to have.
    func preparePrintSnapshot(imageablePoints: CGSize,
                              completion: @escaping @MainActor (Result<PrintSnapshot, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning,
              !filterPreviewIsOpen else { return completion(.failure(DocumentError.busy)) }
        endPendingUserEdits()
        enqueueExclusive(label: "Preparing to print",
                         rejected: { completion(.failure(DocumentError.busy)) }) { [session, image] in
            let result = Result {
                let info = try session.info(image)
                let pixelSize = PrintGeometry.snapshotSize(
                    imagePixels: CGSize(width: info.width, height: info.height),
                    imageablePoints: imageablePoints)
                return try PrintSnapshot.render(session: session, image: image,
                                                scale: pixelSize.width / Double(info.width),
                                                pixelSize: pixelSize)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops taking work and destroys the engine image once everything
    /// queued has run, so a close never tears the image from under a job.
    /// The teardown cannot rely on `self` — the controller may already be
    /// gone — so the session and image id travel in the closure.
    func closeImageWhenDrained(completion: @escaping @MainActor () -> Void = {}) {
        guard !isClosing else { return }
        if strokeIsActive { endStroke() }
        isClosing = true
        let close = { [session, image] in
            EngineActivity.shared.closeImage(image, session: session) { result in
                if case .failure(let error) = result { self.onError?(String(describing: error)) }
                completion()
            }
        }
        if pendingWork == 0 { close() } else { onQueueDrained = close }
    }

    // MARK: Helpers

    /// Runs engine work on the input queue, after any pending pointer input.
    enum CommandEffect { case readsPixels, changesImage, changesPreview }

    /// What an accepted filter start hands its panel builder: the open
    /// session and the values its editable properties began at.
    struct FilterPreviewStart {
        let filter: Int32
        let values: [String: EngineSession.FilterValue]
    }

    /// Begins a filter session for `operation` on the active drawable —
    /// the layer, or its mask while mask editing is on — and reads
    /// `properties`' starting values, as one counted job on the
    /// input queue — behind pending stroke, field and text input, so the
    /// preview begins on the edits the user already made instead of
    /// overtaking them. The completion runs on the main actor before the
    /// job counts down, so a stale completion that aborts the session it
    /// just created still keeps the close drain waiting.
    func beginFilterPreview(operation: String, properties: [EngineSession.FilterProperty],
                            completion: @escaping @MainActor (Result<FilterPreviewStart, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        // A filter preview would run on the primary layer alone.
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: "Apply a filter") {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        guard let drawable = activeDrawable else {
            return completion(.failure(pendingTargetCommands.isEmpty ? DocumentError.noLayer : DocumentError.busy))
        }
        guard !EngineActivity.shared.isBusy else { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session, image] in
            let result = Result<FilterPreviewStart, Error> {
                try self.requirePaintTarget()
                let filter = try session.beginFilter(image: image, drawable: drawable, operation: operation)
                var values: [String: EngineSession.FilterValue] = [:]
                for property in properties where property.kind.isEditable {
                    values[property.name] = try? session.filterProperty(filter, property.name)
                }
                return FilterPreviewStart(filter: filter, values: values)
            }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    /// Begins a live session editing committed effect `effect` of
    /// `drawable` — both ids explicit, never the implicit paint target —
    /// and reads `properties`' starting values, as one counted job on
    /// the input queue behind pending input, like a new filter's begin.
    /// The completion runs on the main actor before the job counts down,
    /// so a stale completion that aborts the session it just created
    /// still keeps the close drain waiting.
    func beginEffectPreview(effect: Int32, on drawable: Int32,
                            properties: [EngineSession.FilterProperty],
                            completion: @escaping @MainActor (Result<FilterPreviewStart, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard canChangeEffect(effect, on: drawable) else {
            return completion(.failure(DocumentError.targetChanged))
        }
        guard !EngineActivity.shared.isBusy else { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session, image] in
            let result = Result<FilterPreviewStart, Error> {
                let filter = try session.beginEditingEffect(effect, on: drawable, image: image)
                var values: [String: EngineSession.FilterValue] = [:]
                for property in properties where property.kind.isEditable {
                    values[property.name] = try? session.filterProperty(filter, property.name)
                }
                return FilterPreviewStart(filter: filter, values: values)
            }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    /// Aborting a preview is cleanup, so clipboard/save edit gates must
    /// never suppress it; it also runs while the image closes, so a
    /// session begun behind pending input still unwinds before destroy.
    /// A commit is an edit and leaves its session available if refused.
    func finishFilter(_ filter: Int32, commit: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        if commit {
            guard !isClosing else { return completion(false) }
            if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(false) }
        }
        enqueue(on: inputQueue, input: commit, teardown: !commit) { [session] in
            let success: Bool
            do {
                if commit { try session.commitFilter(filter) } else { try session.abortFilter(filter) }
                success = true
            } catch {
                if commit { self.report(error) }
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// A live-preview property write through the typed setter, behind
    /// pending input. The completion reports the engine's answer so the
    /// form can restore a refused control and show the reason; a preview
    /// write adds no undo step and does not dirty the image.
    func setFilterProperty(_ filter: Int32, _ property: String, _ value: EngineSession.FilterValue,
                           completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        enqueue(on: inputQueue) { [session] in
            let result = Result { try session.setFilterProperty(filter, property, to: value) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// While a floating selection is active, commands that would
    /// implicitly anchor it or change the layer/mask/channel structure
    /// underneath it — target switches, structural layer and mask
    /// commands, channel edits, an ordinary Paste, image-wide pixel and
    /// color operations — are refused with the resolve-first reason.
    /// Painting, fills and Copy land on the floating layer instead (see
    /// `paintTarget`), and Undo/Redo stay available and refresh the
    /// cached floating state. No automatic anchor is performed.
    private func refuseWhileFloatingActive() -> Bool {
        guard let reason = FloatingControlsLogic.resolveFirstGate(floatingState) else { return false }
        onUserCommand?()
        onError?(reason)
        NSSound.beep()
        return true
    }

    /// The completion-taking form of the same gate.
    private func refuseFloatingForCompletion(_ completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> Bool {
        guard let reason = FloatingControlsLogic.resolveFirstGate(floatingState) else { return false }
        onUserCommand?()
        completion(.failure(FloatingError.refused(reason)))
        return true
    }

    /// Refuses a single-layer command while more than one layer is
    /// selected, with the actionable "Choose one layer" reason; batch
    /// operations are unsupported, so nothing is ever silently applied
    /// to only the first (primary) layer. `layer` limits the gate to
    /// commands about that explicit layer — the primary's — while
    /// per-row edits (rename, visibility, an explicit mask view flag)
    /// keep targeting their captured row. Returns true when refused.
    func refuseSingleLayerCommand(_ action: String, on layer: Int32? = nil) -> Bool {
        guard hasMultipleSelectedLayers, layer == nil || layer == activeLayer,
              let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count, action: action)
        else { return false }
        onUserCommand?()
        onError?(reason)
        NSSound.beep()
        return true
    }

    /// While a queued command has yet to report the drawable it creates
    /// or leaves selected, an edit that captures the paint target now
    /// could hit the drawable that command is about to replace; refuse
    /// it and say why. Picks are unaffected — a valid pick resolves the
    /// target itself.
    private func refuseWhileTargetPending() -> Bool {
        guard !pendingTargetCommands.isEmpty else { return false }
        onUserCommand?()
        onError?(DocumentError.busy.localizedDescription)
        return true
    }

    /// Queues a command whose result becomes or replaces the paint
    /// target — a created, pasted or text layer, an editing mask, or a
    /// command that removes the target — as counted input. While the
    /// command is queued `activeDrawable` reports none, so an edit that
    /// captures it now is refused instead of landing on the drawable
    /// being replaced. The command selects its result in the engine;
    /// the completion only clears the gate and reconciles the
    /// interface's state — it must never enqueue another native select,
    /// which could land between another operation's pixel read and its
    /// deferred write.
    private func enqueueTargetCommand(_ work: @escaping (EngineSession, Int32) throws -> Void,
                                      completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        nextTargetCommandToken += 1
        let token = nextTargetCommandToken
        pendingTargetCommands.insert(token)
        onStateChange?()
        enqueue(on: inputQueue, input: true) { [session, image] in
            // While the command runs the target it replaces cannot be
            // painted; a success leaves a fresh native selection the
            // edits behind it may use, while a failure keeps the
            // queue's prior answer rather than reopening a refused one.
            let targetWasValid = self.paintTargetIsValid
            self.paintTargetIsValid = false
            let result = Result { try work(session, image) }
            self.paintTargetIsValid = targetWasValid
            if case .success = result { self.paintTargetIsValid = true }
            DispatchQueue.main.async {
                // The token still stands only if no pick took over the
                // target while the command was queued — a pick owns the
                // rejected state through its own completion then. A
                // success ends a refused pick's rejection; a failure
                // never reopens it.
                if self.pendingTargetCommands.remove(token) != nil, case .success = result {
                    self.rejectedTargetPick = false
                }
                if case .failure(let error) = result { self.onError?(String(describing: error)) }
                try? self.reload()
                completion?(result)
            }
        }
    }

    /// Refuses commands after a failed queued target pick or while a
    /// target command's result is unknown, before they can act on the
    /// engine's previous implicit drawable target. Painting, fills,
    /// gradients, path strokes and Clear all go through here, so a
    /// multi-selection gates them all with the same reason instead of
    /// painting only the primary layer.
    @discardableResult
    func runOnPaintTarget(_ work: @escaping (EngineSession, Int32) throws -> Void) -> Bool {
        guard !refuseWhileTargetPending() else { return false }
        guard !refuseSingleLayerCommand("Paint") else { return false }
        guard activeDrawable != nil else {
            onError?(DocumentError.targetChanged.localizedDescription)
            return false
        }
        return run { session, image in
            try self.requirePaintTarget()
            try work(session, image)
        }
    }

    private nonisolated func requirePaintTarget() throws {
        guard paintTargetIsValid else { throw DocumentError.targetChanged }
    }

    @discardableResult
    func run(effect: CommandEffect = .changesImage, _ work: @escaping (EngineSession, Int32) throws -> Void) -> Bool {
        guard !isClosing else { return false }
        if effect != .readsPixels && refuseWhileEditingUnavailable(forPreviewWork: effect == .changesPreview) {
            return false
        }
        enqueue(on: inputQueue, input: effect == .changesImage) { [session, image] in
            do { try work(session, image) } catch { self.report(error) }
        }
        return true
    }

    /// Queues engine work; the document counts it until it ran so a close
    /// can wait. `input` jobs go through the input queue — all edits —
    /// and count as unsaved changes while they wait or run. `teardown`
    /// jobs (filter aborts) are cleanup: they queue and count even while
    /// closing, so the drain never destroys an image out from under them.
    private func enqueue(on queue: DispatchQueue, input: Bool = false, teardown: Bool = false,
                       _ work: @escaping () -> Void) {
        guard teardown || !isClosing else { return }
        pendingWork += 1
        if input { pendingInput += 1 }
        EngineActivity.shared.whenIdle {
            queue.async {
                work()
                DispatchQueue.main.async { self.jobDidFinish(input: input) }
            }
        }
    }

    /// Count the whole exclusive operation, including its input drain,
    /// so a close cannot destroy the image while a file call is waiting.
    private func enqueueExclusive(label: String, rejected: @escaping @MainActor () -> Void,
                                  _ work: @escaping () -> Void) {
        guard !isClosing else { return rejected() }
        onUserCommand?()
        pendingWork += 1
        let accepted = EngineActivity.shared.perform(label: label, work: work) {
            self.jobDidFinish(input: false)
        }
        if !accepted {
            jobDidFinish(input: false)
            rejected()
        }
    }

    private func jobDidFinish(input: Bool) {
        pendingWork -= 1
        if input {
            pendingInput -= 1
            // An in-flight edit can hold the dirty bullet up; refresh it.
            if pendingInput == 0 { onStateChange?() }
        }
        if pendingWork == 0, let drained = onQueueDrained {
            onQueueDrained = nil
            drained()
        }
    }

    private nonisolated func report(_ error: Error) {
        let message = String(describing: error)
        DispatchQueue.main.async { self.onError?(message) }
    }
}
