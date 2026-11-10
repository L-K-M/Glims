import AppKit
import CGlimsEngine
import CoreGraphics

/// Carries the native creation's ids from the input queue, where the
/// target command runs, to its main-actor completion.
private final class CreatedAdjustmentBox: @unchecked Sendable {
    var value: (layer: Int32, effect: Int32)?
}

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

    /// The document owns its frontend command log; engine handles remain outside it.
    private(set) var recorder = RecorderLog<SemanticImageCommand>()
    private var recorderTargetContexts: [Int: RecorderContext] = [:]
    private(set) var recorderDescriptions = RecorderDescriptionCatalog()
    private(set) var recorderBindingDescriptions: [Int: RecorderBindingDescription] = [:]
    private var recorderSymbols: [RecorderRuntimeTarget: UUID] = [:]
    private(set) var recorderLoadedFile: RecorderFileValue?
    private(set) var recorderFileMetadata: RecorderFileMetadata
    private var recorderRevision = UUID()
    private var recorderSavedRevision: UUID?
    private static let recorderFileQueue = DispatchQueue(label: "ch.lkmc.Glims.recorder.file", qos: .userInitiated)
    private var recorderReplayGeneration = UUID()
    private var recorderReplayWaitingGeneration: UUID?

    private struct RecorderTargetContext: Equatable {
        let layers: [Int32]
        let channels: [Int32]
        let target: PaintTarget
        let masks: [Int32: EngineSession.MaskState]
        let quickMask: EngineSession.QuickMaskState
    }

    private enum RecorderContext {
        case target(RecorderTargetContext)
        case layer(Int32)
        case unavailable(String)
    }

    private struct RecorderCapture {
        let reservation: RecorderLog<SemanticImageCommand>.Reservation
        let context: RecorderContext?
        let symbols: [RecorderRuntimeTarget: UUID]
    }

    /// Native identities are confined to this document's runtime packets.
    private enum RecorderRuntimeTarget: Hashable {
        case layer(Int32)
        case channel(Int32)
    }

    struct RecorderInstallCheckpoint: Equatable {
        fileprivate let owner: UUID
        fileprivate let revision: UUID
    }

    enum RecorderInstallChoice: Hashable {
        case layer(Int32)
        case channel(Int32)
        case quickMask(Int32)
    }

    enum RecorderSaveOutcome: Equatable {
        case savedCurrentRevision
        case savedEarlierRevision
    }

    enum RecorderInstallError: LocalizedError, Equatable {
        case wrongDocument, staleRecording, unsettled, changedImage, incompleteChoices, duplicateTarget
        case unavailableTarget(String)
        case missingMask(String)

        var errorDescription: String? {
            switch self {
            case .wrongDocument: return "This Recorder action was confirmed for a different image."
            case .staleRecording: return "The current recording changed. Choose the Recorder action again."
            case .unsettled: return "Stop recording or replay and wait for accepted commands to finish."
            case .changedImage: return "The image changed while checking the recording targets. Confirm the targets again."
            case .incompleteChoices: return "Choose one target for each required recording symbol."
            case .duplicateTarget: return "Choose a distinct target for each recording symbol."
            case .unavailableTarget(let name): return "Choose a current target with the recorded role for “\(name)” in this image."
            case .missingMask(let name): return "Choose a layer with a mask for “\(name)”."
            }
        }
    }

    private struct RecorderInstallation {
        let log: RecorderLog<SemanticImageCommand>
        let file: RecorderFileValue
        let contexts: [Int: RecorderContext]
        let descriptions: RecorderDescriptionCatalog
        let bindings: [Int: RecorderBindingDescription]
        let symbols: [RecorderRuntimeTarget: UUID]
    }

    private struct ConfirmedRecorderCapture {
        let context: RecorderContext?
        let binding: RecorderBindingDescription
        let descriptions: [UUID: RecorderDescriptionObservation]
    }

    private struct RecorderReplayError: LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

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
    /// The image's selected channels, ordered as the slot-137 read-back
    /// returns them (the order slot 136 last wrote). Transient like the
    /// layer selection; reconciled on every reload. Exactly one selected
    /// channel is the paint/edit target; several are an ambiguous target
    /// (none), never the first row.
    private(set) var selectedChannelIDs: [Int32] = []
    /// The image's selected paths, ordered as the slot-137 read-back
    /// returns them. Exactly one selected path is the active path; none
    /// or several selected means no active path.
    private(set) var selectedPathIDs: [Int32] = []
    /// Whether more than one channel is selected: the ambiguous
    /// channel-target state that gates target-writing commands.
    var hasMultipleSelectedChannels: Bool { ItemSelectionPolicy.isMulti(selectedChannelIDs.count) }
    /// Whether more than one path is selected: the ambiguous path state
    /// the Path tool and the palette commands refuse.
    var hasMultipleSelectedPaths: Bool { ItemSelectionPolicy.isMulti(selectedPathIDs.count) }
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
    private enum PaintTarget: Equatable {
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
    /// A queued channel/path batch selection, mirrored like a target pick:
    /// the ordered ids captured with the document's own image handle, so
    /// the job can never retarget to another document.
    private struct PendingItemSelection {
        let version: Int
        let kind: EngineSession.ItemSetKind
        let ids: [Int32]
    }
    private var itemSelectionVersion = 0
    private var pendingChannelSelection: PendingItemSelection?
    private var pendingPathSelection: PendingItemSelection?
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
    /// Recorder admission and completion use their own notification so observing
    /// the log never replaces the window's image-state handler.
    var onRecorderChange: (() -> Void)?
    enum RecorderObserverScope: Equatable { case commands, presentation }
    private struct RecorderObserver {
        let scope: RecorderObserverScope
        let callback: () -> Void
    }
    private var recorderObservers: [UUID: RecorderObserver] = [:]
    /// Called with the changed area in image pixels.
    var onProjectionChange: ((CGRect) -> Void)?
    /// Called with engine errors that the interface should show.
    var onError: ((String) -> Void)?
    /// A refused pixel edit asks its owning window for explicit rasterization.
    /// The gesture is consumed; it is never replayed after the sheet closes.
    var onPaintNeedsRasterize: ((_ layer: Int32, _ stateVersion: Int) -> Void)?
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
    /// Closing admission may precede the canvas render drain. Native
    /// teardown is scheduled separately, after the controller releases it.
    private var nativeCloseIsScheduled = false
    private(set) var isTransferringClipboard = false
    private(set) var isSavingForClose = false
    private var onQueueDrained: (() -> Void)?

    private var acceptsImageReads: Bool {
        !isClosing && !isSavingForClose && !isTransferringClipboard && !PlugInCommands.isRunning
            && !filterPreviewIsOpen && !EngineActivity.shared.isBusy
    }

    var acceptsEdits: Bool { acceptsImageReads && !recorder.isReplaying }

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
        let initialInfo = try session.info(image)
        self.info = initialInfo
        self.recorderFileMetadata = RecorderFileMetadata(origin: .init(imageLabel: name,
            initialWidth: initialInfo.width, initialHeight: initialInfo.height))
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
        // The ordered selected channels come from the whole-list slot-137
        // read-back, reconciled against the channels that still exist; a
        // queued pick's mirror wins until its completion lands. The rows'
        // own isSelected flags are then derived from the reconciled list,
        // so the palette shows exactly the native selection.
        let mirroredChannelIDs: [Int32]? = {
            if let pick = pendingTargetPick {
                if case .channel(let id) = pick.target { return [id] }
                return []
            }
            return pendingChannelSelection?.ids
        }()
        let existingChannelIDs = Set(channels.map(\.id))
        selectedChannelIDs = LayerSelectionPolicy.reconcile(
            mirroredChannelIDs ?? (try? session.selectedItems(.channel, image: image))
                ?? channels.filter(\.isSelected).map(\.id),
            existing: existingChannelIDs)
        channels = channels.map { channelRow($0, selected: selectedChannelIDs.contains($0.id)) }
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
        // The ordered selected paths, from the slot-137 read-back or a
        // queued pick's mirror, reconciled against the paths that still
        // exist. The active path is always reconciled from this current
        // native selection: exactly one selected path is active; none or
        // several selected means no active path — never a stale
        // remembered row.
        let existingPathIDs = Set(paths.map(\.id))
        selectedPathIDs = LayerSelectionPolicy.reconcile(
            pendingPathSelection?.ids ?? (try? session.selectedItems(.path, image: image))
                ?? paths.filter(\.isSelected).map(\.id),
            existing: existingPathIDs)
        activePath = ItemSelectionPolicy.activePath(selectedPathIDs, existing: existingPathIDs)
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
    /// as the channel-priority (or mask-editing) target. Several selected
    /// channels are an ambiguous target: no drawable at all, never the
    /// first selected channel.
    private var paintTarget: PaintTarget? {
        guard !rejectedTargetPick, pendingTargetCommands.isEmpty else { return nil }
        if let pick = pendingTargetPick { return pick.target }
        if floatingState.isActive { return .layer(floatingState.floating) }
        if !selectedChannelIDs.isEmpty {
            guard let channel = ItemSelectionPolicy.channelTarget(selectedChannelIDs,
                                                                   existing: Set(channels.map(\.id)))
            else { return nil }
            return .channel(channel)
        }
        guard let layer = activeLayer else { return nil }
        if let state = maskStates[layer], state.editing, state.mask != 0 {
            return .mask(layer: layer, drawable: state.mask)
        }
        return .layer(layer)
    }

    var activeDrawable: Int32? { paintTarget?.drawable }

    /// View ▸ Show Layer Boundary's cached outline: the actual bounds, in
    /// image pixels, of the current cached paint target — an ordinary
    /// layer's absolute bounds, the owner layer's bounds while its mask is
    /// being edited, the image bounds for a selected channel, and the
    /// floating layer's own bounds while a floating selection is active
    /// (it owns painting ahead of any channel or mask target). Resolved
    /// from the caches on every read, so a draw never shows a remembered
    /// unrelated layer; nil when no target is current or its bounds are
    /// missing or invalid. Pure cache read: no engine call, no pixel,
    /// dirty-flag or history change.
    var cachedPaintTargetBounds: CGRect? {
        guard let target = paintTarget else { return nil }
        let kind: LayerBoundaryGeometry.Target
        switch target {
        case .layer(let id): kind = .layer(id)
        case .mask(let layer, _): kind = .mask(layer: layer)
        case .channel(let id): kind = .channel(id)
        }
        return LayerBoundaryGeometry.boundaryRect(target: kind, layers: layers,
            imageSize: CGSize(width: Double(info.width), height: Double(info.height)))
    }

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

    /// Whether any channel is selected — even when several are and no
    /// single channel is the active target: channel-target edits refuse
    /// either way.
    var isChannelTargetActive: Bool { ItemSelectionPolicy.isChannelTargetActive(selectedChannelIDs) }

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

    /// Makes `id` the image's whole selected-channel list — one row, so a
    /// click resolves an earlier multi-selection to exactly this channel —
    /// through the native batch write (slot 136), never a first-row pick.
    func selectChannel(_ id: Int32) {
        guard !isClosing, !refuseWhileEditingUnavailable() else { return }
        // The native write refuses a non-empty channel list under an
        // active floating selection; a single pick refuses it too.
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        guard channels.contains(where: { $0.id == id }) else { return }
        queueItemSelection([id], kind: .channel)
    }

    /// Selects exactly `ids`, in that order, as the image's whole
    /// selected-channel list (slot 136) with the exact slot-137 read-back
    /// as the postcondition. An empty list returns the target to the
    /// layers. Transient; the native edit-readiness and floating rules
    /// apply (a non-empty list is refused under a floating selection).
    func selectChannelItems(_ ids: [Int32]) {
        guard !isClosing, !refuseWhileEditingUnavailable() else { return }
        guard ids.isEmpty || !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        let existing = Set(channels.map(\.id))
        guard ids.allSatisfy({ existing.contains($0) }), Set(ids).count == ids.count else { return }
        queueItemSelection(ids, kind: .channel)
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
        selectedChannelIDs = []
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

    /// Queues the ordered channel/path batch selection as one serial
    /// input job, mirrored like a target pick; the completion re-reads the
    /// authoritative state and its slot-137 read-back must equal the
    /// requested order exactly. A single selected channel also mirrors
    /// the paint target through `pendingTargetPick`; several selected
    /// channels resolve to no target. Path selection never touches it.
    private func queueItemSelection(_ ids: [Int32], kind: EngineSession.ItemSetKind) {
        itemSelectionVersion += 1
        let pick = PendingItemSelection(version: itemSelectionVersion, kind: kind, ids: ids)
        let existing: Set<Int32>
        switch kind {
        case .channel:
            pendingChannelSelection = pick
            existing = Set(channels.map(\.id))
        case .path:
            pendingPathSelection = pick
            existing = Set(paths.map(\.id))
        case .layer:
            return
        }
        let ordered = LayerSelectionPolicy.reconcile(ids, existing: existing)
        var pickTargetVersion = 0
        if kind == .channel {
            selectedChannelIDs = ordered
            channels = channels.map { channelRow($0, selected: ordered.contains($0.id)) }
            pendingTargetCommands.removeAll()
            if let id = ordered.first, ordered.count == 1 {
                targetPickVersion += 1
                pickTargetVersion = targetPickVersion
                pendingTargetPick = TargetPick(version: pickTargetVersion, target: .channel(id))
                rejectedTargetPick = false
            } else {
                pendingTargetPick = nil
                rejectedTargetPick = false
            }
        } else {
            selectedPathIDs = ordered
            activePath = ordered.count == 1 ? ordered.first : nil
        }
        enqueue(on: inputQueue) { [session, image] in
            var failure: Error?
            if kind == .channel { self.paintTargetIsValid = false }
            do {
                try session.selectItems(ordered, kind: kind, image: image)
                guard try session.selectedItems(kind, image: image) == ordered else {
                    throw DocumentError.targetChanged
                }
                if kind == .channel { self.paintTargetIsValid = true }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                if kind == .channel {
                    if self.pendingChannelSelection?.version == pick.version { self.pendingChannelSelection = nil }
                    if self.pendingTargetPick?.version == pickTargetVersion {
                        self.pendingTargetPick = nil
                        self.rejectedTargetPick = failure != nil
                    }
                } else if self.pendingPathSelection?.version == pick.version {
                    self.pendingPathSelection = nil
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
        switch target {
        case .channel(let id): selectedChannelIDs = [id]
        case .layer, .mask: selectedChannelIDs = []
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
        guard !refuseMultiChannelCommand("Paint") else { return }
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
        guard let target = paintTarget, !refuseStructuredPaint(on: target) else { return }
        strokeIsActive = true
        enqueue(on: inputQueue, input: true) { [session, image] in
            do {
                try self.requirePaintTarget()
                try self.requireRasterizedPaintTarget(target)
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
        let command = SemanticImageCommand.selectionShape(shape, options: options)
        run(semantic: command, command.apply)
    }

    func selectColor(at point: CGPoint, options: EngineSession.SelectOptions) {
        guard !refuseWhileEditingUnavailable() else { return }
        let command = SemanticImageCommand.selectColor(point, options: options)
        run(semantic: command, command.apply)
    }

    func select(_ command: EngineSession.SelectCommand, radius: Double = 0) {
        guard !refuseWhileEditingUnavailable() else { return }
        let semantic = SemanticImageCommand.selectCommand(command, radius: radius)
        run(semantic: semantic, semantic.apply)
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

    // MARK: Create resource from selection

    /// The cached-state reason Edit ▸ Create Resource ▸ … cannot run right
    /// now, or nil when it can. Reads only the document's cached state —
    /// never the engine — so menu validation and the sheet's open/accept
    /// gates make no synchronous native call. The selection gate reads the
    /// image's root selection mask bounds (`selectionBounds`): any nonzero
    /// mask value counts, including soft coverage below the marching-ants
    /// threshold, which has bounds but no outline. No gate keys on the
    /// paint target, its source kind or layer locks: the capture reads the
    /// merged image, which is valid for any target.
    func createResourceRefusal(kind: EngineSession.ResourceKind) -> String? {
        if recorder.isReplaying { return "Cancel Recorder replay before changing resources." }
        return ResourceSelectionFormValidation.menuRefusal(
            engineActivity: PlugInCommands.isRunning ? nil : EngineActivity.shared.label,
            plugInLabel: PlugInCommands.running.map { $0.procedure.label.replacingOccurrences(of: "…", with: "") },
            isClosing: isClosing,
            isSavingForClose: isSavingForClose,
            isTransferringClipboard: isTransferringClipboard,
            previewOpen: filterPreviewIsOpen,
            selectionBounds: selectionBounds,
            kind: kind)
    }

    /// Edit ▸ Create Resource ▸ Brush/Pattern from Selection…: captures the
    /// selected VISIBLE MERGED pixels of this document into one new saved
    /// resource (facade slot 129, `EngineSession.createResource`) — the
    /// native copy is the private `gimp_selection_extract` (cut FALSE)
    /// behind `copyPixels(image, merged: true)`, never the system clipboard,
    /// and never a full-image fallback: a fresh native check on the worker
    /// requires an actual nonempty selection and refuses bounds over the
    /// 10000 px per-side cap BEFORE any pixels are allocated.
    ///
    /// The flow is one counted global exclusive job: `EngineActivity`
    /// drains ALL accepted input of every document before the native work,
    /// and `pendingWork` stays counted through the deferred main completion
    /// stage, so a close waits for the whole job and its callback. The
    /// completion runs on the main actor exactly once with the created
    /// id/name/kind; a successful publish never becomes a false failure
    /// through the optional identity query. Pre-acceptance refusals
    /// (closing, cached gate, local validation, busy) call the completion
    /// synchronously with nothing queued.
    func createResourceFromSelection(kind: EngineSession.ResourceKind, name: String, brushSpacing: UInt32,
                                     completion: @escaping @MainActor (Result<CreatedResource, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = createResourceRefusal(kind: kind) {
            return completion(.failure(EngineSession.EngineError(
                status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)))
        }
        // Pure local validation before anything is queued: the name and
        // spacing rules (dimensions come from the fresh selection on the
        // worker). This is the same pre-RPC gate slot 129 applies.
        do {
            try EngineSession.validateResourceCreation(kind: kind, name: name, width: 1, height: 1,
                                                       byteCount: 4, brushSpacing: brushSpacing)
        } catch { return completion(.failure(error)) }
        // End in-flight field/text edits and this document's own open
        // stroke explicitly — the established finishInput pattern — so the
        // exclusive drain below starts from committed input.
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        let label = "Creating \(kind.singular) “\(name)”"
        enqueueExclusive(label: label, rejected: {
            self.jobDidFinish(input: false)
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result: Result<CreatedResource, Error> = Result {
                // Fresh native check on the worker: the actual root
                // selection, including soft coverage below the ants
                // threshold — bounds exist whenever the mask is nonempty.
                guard let bounds = try session.selectionBounds(image: image) else {
                    throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                        message: "There is no selection to create a \(kind.singular) from; select an area first.")
                }
                guard bounds.width.isFinite, bounds.height.isFinite,
                      Int(bounds.width) >= 1, Int(bounds.height) >= 1,
                      Int(bounds.width) <= EngineSession.resourceMaxDimension,
                      Int(bounds.height) <= EngineSession.resourceMaxDimension else {
                    // Refused before copyPixels allocates any pixels.
                    throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                        message: "The selection is too large to create a \(kind.singular) from (at most \(EngineSession.resourceMaxDimension) pixels per side).")
                }
                let pixels = try session.copyPixels(image, merged: true)
                guard pixels.width == Int(bounds.width), pixels.height == Int(bounds.height) else {
                    throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                        message: "The engine copied \(pixels.width) × \(pixels.height) pixels for a \(Int(bounds.width)) × \(Int(bounds.height)) selection.")
                }
                let id = try session.createResource(kind: kind, name: name, pixels: pixels,
                                                    brushSpacing: brushSpacing)
                // Optional identity query only: a successful publish must
                // not become a false failure through it.
                let identity = try? session.resourceIdentifiers(id)
                return CreatedResource(id: id, name: identity?.name ?? name, kind: kind)
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    // The extra count covers this deferred completion,
                    // including callbacks that request window closure.
                    defer { self.jobDidFinish(input: false) }
                    if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    completion(result)
                }
            }
        }
    }

    // MARK: Duplicate resource

    /// The cached-state reason a Duplicate… write cannot run right now, or
    /// nil when it can. Reads only the document's cached state — never the
    /// engine — so the choosers' validation and the form's Create gate make
    /// no synchronous native call on the main thread.
    func duplicateResourceRefusal(kind: EngineSession.ResourceKind) -> String? {
        if recorder.isReplaying { return "Cancel Recorder replay before changing resources." }
        return ResourceDuplicateValidation.gate(
            engineActivity: PlugInCommands.isRunning ? nil : EngineActivity.shared.label,
            plugInLabel: PlugInCommands.running.map { $0.procedure.label.replacingOccurrences(of: "…", with: "") },
            isClosing: isClosing,
            isSavingForClose: isSavingForClose,
            isTransferringClipboard: isTransferringClipboard,
            previewOpen: filterPreviewIsOpen,
            kind: kind)
    }

    /// Duplicates the captured saved `source` resource as a new saved
    /// resource of the same kind under `name` — the ONLY native write is
    /// facade slot 131, `EngineSession.duplicateResource`. The call takes no
    /// image and changes no image, undo history, selection, clipboard or
    /// committed ToolState; the source itself is never renamed or dirtied.
    ///
    /// The flow mirrors `createResourceFromSelection` exactly: one counted
    /// global exclusive job (`EngineActivity` drains ALL accepted document
    /// input first), with the outer `pendingWork` count covering the
    /// deferred main completion stage and `enqueueExclusive`'s inner count
    /// covering the job itself, so a close waits for the whole job and its
    /// callback and a rejection balances both counts and completes once.
    /// On the worker the captured `ResourceIdentity` is resolved freshly
    /// with the captured kind — the engine's own match, no name-only
    /// fallback, internal localized-name semantics honored natively — the
    /// current resource is revalidated through the facade, and slot 131
    /// runs synchronously OFF MAIN with the full UInt64 handles, the result
    /// captured by value. The completion runs on the main actor exactly once
    /// (main -> whenIdle -> onError/completion -> jobDidFinish); a successful
    /// publish never becomes a false failure through the optional identity
    /// query. Pre-acceptance refusals (closing, cached gate, local
    /// validation) call the completion synchronously with nothing queued.
    func duplicateResource(source: ResourceDuplicateValidation.Source, name: String,
                           completion: @escaping @MainActor (Result<CreatedResource, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = duplicateResourceRefusal(kind: source.kind) {
            return completion(.failure(EngineSession.EngineError(
                status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)))
        }
        // Pure local validation before anything is queued: the shared label
        // contract slot 131 applies natively as well. No trimming, no
        // normalization — the name goes through exactly as typed.
        do {
            try EngineSession.validateResourceName(name)
        } catch { return completion(.failure(error)) }
        // End in-flight field/text edits and this document's own open
        // stroke explicitly — the established finishInput pattern — so the
        // exclusive drain below starts from committed input.
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        let label = "Duplicating \(source.kind.singular) “\(source.identity.name)”"
        enqueueExclusive(label: label, rejected: {
            self.jobDidFinish(input: false)
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result: Result<CreatedResource, Error> = Result {
                // Resolve the captured identity freshly with the captured
                // kind: the engine's own exact match (collection and
                // isInternal included), no name-only fallback.
                let sourceID = try session.resolveResource(source.identity, kind: source.kind)
                // Revalidate the current source through the facade before
                // writing: a removed or foreign source is NOT_FOUND here,
                // never duplicated.
                _ = try session.resourceIdentifiers(sourceID)
                // The one native write: synchronous slot 131, off the main
                // thread, full UInt64 handles by value.
                let newID = try session.duplicateResource(sourceID, name: name)
                // Optional follow-up only: a successful publish must not
                // become a false failure through the identity query.
                let identity = try? session.resourceIdentifiers(newID)
                return CreatedResource(id: newID, name: identity?.name ?? name, kind: source.kind)
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    // The outer count covers this deferred completion,
                    // including callbacks that request window closure.
                    defer { self.jobDidFinish(input: false) }
                    if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    completion(result)
                }
            }
        }
    }

    /// Reads the exact captured resource off-main. Both the worker and its
    /// deferred delivery remain counted, so host close cannot overtake them.
    func loadResourceMutationInfo(source: ResourceDuplicateValidation.Source,
                                  completion: @escaping @MainActor (Result<EngineSession.ResourceMutationInfo, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        enqueue(on: longQueue) { [session] in
            let result = Result { () throws -> EngineSession.ResourceMutationInfo in
                let id = try session.resolveResource(source.identity, kind: source.kind)
                guard id == source.id else { throw EngineSession.EngineError(
                    status: Int32(GLIMS_STATUS_NOT_FOUND.rawValue), message: "This resource changed. Refresh the chooser.") }
                return try session.resourceMutationInfo(id)
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    completion(self.isClosing ? .failure(DocumentError.closed) : result)
                }
            }
        }
    }

    func resourceMutationRefusal() -> String? {
        if recorder.isReplaying { return "Cancel Recorder replay before changing resources." }
        if isClosing { return DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard { return DocumentError.busy.localizedDescription }
        if PlugInCommands.isRunning { return "Finish or cancel the running plug-in first." }
        if let label = EngineActivity.shared.label { return "Wait for \(label) to finish." }
        if filterPreviewIsOpen { return "Apply or cancel the filter preview first." }
        return nil
    }

    /// A resource write is globally exclusive and outside image Undo. onCommitted
    /// survives form invalidation: global identity references still need migration
    /// after an accepted rename, even if its original host has already closed.
    func mutateResource(source: ResourceDuplicateValidation.Source, guardToken: String,
                        action: ResourceMutationAction,
                        onCommitted: @escaping @MainActor (ResourceMutationOutcome) -> String? = { _ in nil },
                        completion: @escaping @MainActor (Result<ResourceMutationOutcome, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = resourceMutationRefusal() {
            return completion(.failure(EngineSession.EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)))
        }
        do {
            try EngineSession.validateResourceGuard(guardToken)
            if case .rename(let name) = action { try EngineSession.validateResourceName(name) }
        } catch { return completion(.failure(error)) }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        enqueueExclusive(label: "\(action.progress) \(source.kind.singular) “\(source.identity.name)”", rejected: {
            self.jobDidFinish(input: false)
            completion(.failure(DocumentError.busy))
        }) { [session] in
            let result: Result<ResourceMutationOutcome, Error> = Result {
                let id = try session.resolveResource(source.identity, kind: source.kind)
                guard id == source.id else { throw EngineSession.EngineError(
                    status: Int32(GLIMS_STATUS_NOT_FOUND.rawValue), message: "This resource changed. Refresh the chooser.") }
                switch action {
                case .rename(let name):
                    try session.renameResource(id, guardToken: guardToken, name: name)
                    let identity = try? session.resourceIdentifiers(id)
                    return ResourceMutationOutcome(renamedIdentity: identity,
                        warning: identity == nil ? "The resource was renamed, but its new identity could not be read. Refresh the chooser." : nil)
                case .delete:
                    try session.deleteResource(id, guardToken: guardToken)
                    return ResourceMutationOutcome(renamedIdentity: nil, warning: nil)
                }
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    var delivered = result
                    if case .success(let outcome) = result {
                        let migrationWarning = onCommitted(outcome)
                        let warnings = [outcome.warning, migrationWarning].compactMap { $0 }
                        delivered = .success(ResourceMutationOutcome(renamedIdentity: outcome.renamedIdentity,
                            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n")))
                    }
                    let newIdentity: EngineSession.ResourceIdentity?
                    if case .success(let outcome) = result { newIdentity = outcome.renamedIdentity } else { newIdentity = nil }
                    ResourceCatalogChanges.publish(.init(kind: source.kind, oldIdentity: source.identity, newIdentity: newIdentity))
                    if case .failure(let error) = result, !self.isClosing { self.onError?(String(describing: error)) }
                    completion(delivered)
                }
            }
        }
    }

    // MARK: Create gradient

    /// The cached-state reason Edit ▸ Create Resource ▸ Gradient… cannot
    /// run right now, or nil when it can. Reads only the document's cached
    /// state — never the engine — so menu validation and the sheet's
    /// open/accept gates make no synchronous native call. The gradient
    /// catalog is global and the write takes no image: no gate keys on the
    /// selection, the paint target, layer or channel targets, a floating
    /// selection or the file state.
    func createGradientRefusal() -> String? {
        if recorder.isReplaying { return "Cancel Recorder replay before changing resources." }
        return GradientCreateValidation.gate(
            engineActivity: PlugInCommands.isRunning ? nil : EngineActivity.shared.label,
            plugInLabel: PlugInCommands.running.map { $0.procedure.label.replacingOccurrences(of: "…", with: "") },
            isClosing: isClosing,
            isSavingForClose: isSavingForClose,
            isTransferringClipboard: isTransferringClipboard,
            previewOpen: filterPreviewIsOpen)
    }

    /// Creates one saved two-endpoint gradient under `name` — the ONLY
    /// native write is facade slot 138, `EngineSession.createGradient`,
    /// whose endpoints are plain owned sRGB RGBA values converted from the
    /// color wells on the main thread at accept; the worker never sees
    /// NSColor or AppKit. The call takes no image and changes no image,
    /// undo history, selection, clipboard, context or committed ToolState;
    /// it never selects the new gradient or replaces the current gradient
    /// choice.
    ///
    /// The flow mirrors `duplicateResource` exactly: one counted global
    /// exclusive job (`EngineActivity` drains ALL accepted document input
    /// first), with the outer `pendingWork` count covering the deferred
    /// main completion stage and `enqueueExclusive`'s inner count covering
    /// the job itself, so a close waits for the whole job and its callback
    /// and a rejection balances both counts and completes once. The
    /// completion runs on the main actor exactly once — pre-acceptance
    /// refusals call it synchronously with nothing queued — and a
    /// successful publish never becomes a false failure through the
    /// optional identity query.
    func createGradient(name: String, left: EngineSession.RGBAColor, right: EngineSession.RGBAColor,
                        completion: @escaping @MainActor (Result<CreatedResource, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if let reason = createGradientRefusal() {
            return completion(.failure(EngineSession.EngineError(
                status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)))
        }
        // Pure local validation before anything is queued: the name
        // contract, the .ggr ASCII edge-whitespace rule and both endpoints
        // (every component, alpha included, finite inside 0...1) — the
        // same pre-RPC gate slot 138 applies. No trimming, no clamping.
        do {
            try EngineSession.validateGradientCreation(name: name, left: left, right: right)
        } catch { return completion(.failure(error)) }
        // End in-flight field/text edits and this document's own open
        // stroke explicitly — the established finishInput pattern — so the
        // exclusive drain below starts from committed input.
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        let label = "Creating gradient “\(name)”"
        enqueueExclusive(label: label, rejected: {
            self.jobDidFinish(input: false)
            completion(.failure(DocumentError.busy))
        }) { [session] in
            let result: Result<CreatedResource, Error> = Result {
                // The one native write: synchronous slot 138, off the main
                // thread, plain RGBA values by value. The call persists one
                // static gradient and mutates no image.
                let id = try session.createGradient(name: name, left: left, right: right)
                // Optional identity query only: a successful publish must
                // not become a false failure through it.
                let identity = try? session.resourceIdentifiers(id)
                return CreatedResource(id: id, name: identity?.name ?? name, kind: .gradient)
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    // The outer count covers this deferred completion,
                    // including callbacks that request window closure.
                    defer { self.jobDidFinish(input: false) }
                    if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    if case .success = result { GradientChooser.shared.reloadCatalog() }
                    completion(result)
                }
            }
        }
    }

    // MARK: Saved sets (facade slots 133/134 read, 135 edit)

    /// One saved-set read row: the slot-133 row plus the slot-134 current
    /// member ids of the same token.
    struct SavedSetRow: Equatable {
        let set: EngineSession.ItemSet
        let members: [Int32]
    }

    /// One explicit saved-set edit request captured by value at apply.
    /// `captureSelection` asks the worker to query the CURRENT selected ids
    /// of `kind` by an actual per-kind query (never a fake all-items list).
    struct SavedSetEditRequest: Equatable {
        let operation: EngineSession.ItemSetEdit
        let kind: EngineSession.ItemSetKind
        let token: UInt64
        let name: String?
        let members: [Int32]
        let captureSelection: Bool
    }

    /// Reads the catalog (slot 133) AND each set's members (slot 134) off
    /// the main thread as one counted input-queue job — plain reads, allowed
    /// even while busy — so a close drains the read before destroy.
    func readSavedSetRows(completion: @escaping @MainActor (Result<[SavedSetRow], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result {
                try session.itemSets(image).map { set in
                    SavedSetRow(set: set, members: try session.itemSetMembers(image, token: set.token))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The current selected item ids of `kind`, in the engine's own order,
    /// from the authoritative whole-list slot-137 query for all three
    /// kinds; a failed query throws — never a fake all-items list, never a
    /// filtered row cache, empty = explicit empty.
    static func currentSelectedItemIDs(_ session: EngineSession, image: Int32,
                                       kind: EngineSession.ItemSetKind) throws -> [Int32] {
        try session.selectedItems(kind, image: image)
    }

    /// One undoable saved-set edit (slot 135) as one counted GLOBAL
    /// exclusive job: `EngineActivity` drains ALL accepted input of every
    /// document first, and `pendingWork` stays counted through the deferred
    /// main completion (inside `whenIdle`), so a close waits for the whole
    /// job including its callback, which runs exactly once with the
    /// resulting token (0 after REMOVE and every failure). The request is
    /// captured by value — a foreign/stale token fails NOT_FOUND, never
    /// retargeted, no front-document fallback. Pre-acceptance refusals
    /// complete synchronously with nothing queued.
    func editSavedSet(_ request: SavedSetEditRequest,
                      completion: @escaping @MainActor (Result<UInt64, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable() { return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy)) }
        if case .failure(let rejection) = SavedSetControlsLogic.validateRequest(
            operation: request.operation, kind: request.kind, token: request.token,
            name: request.name, members: request.members, captureSelection: request.captureSelection) {
            return completion(.failure(rejection))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        enqueueExclusive(label: "Editing a saved set", rejected: {
            self.jobDidFinish(input: false)
            completion(.failure(DocumentError.busy))
        }) { [session, image] in
            let result: Result<UInt64, Error> = Result {
                let members: [Int32]
                if request.captureSelection {
                    members = try Self.currentSelectedItemIDs(session, image: image, kind: request.kind)
                } else {
                    members = request.members
                }
                return try session.editItemSet(image, request.operation, kind: request.kind,
                                              token: request.token, name: request.name, members: members)
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    // The extra count covers this deferred completion,
                    // including callbacks that request window closure.
                    defer { self.jobDidFinish(input: false) }
                    if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    completion(result)
                }
            }
        }
    }

    /// Recall of a saved set of any kind: the document, kind and token are
    /// captured at the call, and the worker resolves the CURRENT members
    /// (slot 134) fresh — cached table members are never an executable
    /// command. Nonempty members become the whole native selection of
    /// `kind` (slot 136) with the exact slot-137 read-back as the
    /// postcondition; a stale or foreign token fails NOT_FOUND without
    /// touching the selection. Layer and channel recall replace the paint
    /// target, so they run inside the counted target-command lifecycle
    /// (paint refuses while pending); path recall keeps the drawable
    /// state as one counted input job. Under a floating selection the
    /// native contract refuses layer/channel recall, allows path recall.
    func recallItemSet(token: UInt64, kind: EngineSession.ItemSetKind,
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        if kind != .path, refuseWhileFloatingActive() { return completion(.failure(DocumentError.busy)) }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        let work: (EngineSession, Int32) throws -> Void = { session, image in
            let members = try session.itemSetMembers(image, token: token)
            guard !members.isEmpty else {
                throw SavedSetControlsLogic.Rejection(message: "The saved set is empty; there is nothing to recall.")
            }
            try session.selectItems(members, kind: kind, image: image)
            guard try session.selectedItems(kind, image: image) == members else { throw DocumentError.targetChanged }
        }
        if kind == .path {
            enqueue(on: inputQueue, input: true) { [session, image] in
                let result = Result { try work(session, image) }
                DispatchQueue.main.async {
                    if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    try? self.reload()
                    completion(result)
                }
            }
        } else {
            enqueueTargetCommand(work, completion: completion)
        }
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

    // MARK: Image metadata

    /// The tag names present on the image's metadata in `domain`, read
    /// as asynchronous COUNTED document work on the input queue — never
    /// on the main thread and never while a menu validates. The read is
    /// a plain native read (allowed even while a stroke, preview or
    /// plug-in holds the image), but it still counts in `pendingWork`,
    /// so a close drains it before the image is destroyed and a
    /// completion always lands on a live image or reports `closed`.
    /// The image id is captured by value in the queued job.
    func readMetadataTags(_ domain: EngineSession.MetadataDomain,
                          completion: @escaping @MainActor (Result<[String], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result { try session.metadataTags(image, domain: domain) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The ordered value list of one metadata `tag`, queued and counted
    /// exactly like `readMetadataTags(_:)`: duplicates, empty strings,
    /// newlines and order are the engine's own vector, never flattened
    /// or re-joined here. An unregistered tag reports the native
    /// NOT_FOUND through the completion.
    func readMetadataValues(_ tag: String,
                            completion: @escaping @MainActor (Result<[String], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result { try session.metadataValues(image, tag: tag) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A view-only proof preflight is a counted read behind accepted input.
    /// File access and the native transform both run off the main thread.
    func readSoftProofProfile(at url: URL, proofIntent: EngineSession.ProfileIntent,
                              displayIntent: EngineSession.ProfileIntent,
                              blackPointCompensation: Bool, destination: CanvasDisplayDestination,
                              completion: @escaping @MainActor (Result<CanvasSoftProof, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result {
                let proof = try CanvasSoftProof(profileICC: ICCProfileFile.read(url),
                    profileName: url.lastPathComponent, proofIntent: proofIntent,
                    displayIntent: displayIntent, blackPointCompensation: blackPointCompensation)
                _ = try CanvasDisplayDestination.render(session, image: image, scale: 1,
                    area: CGRect(x: 0, y: 0, width: 1, height: 1), destination: destination, proof: proof)
                return proof
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func validateSoftProof(_ proof: CanvasSoftProof, destination: CanvasDisplayDestination,
                           completion: @escaping @MainActor (Result<CanvasSoftProof, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result {
                _ = try CanvasDisplayDestination.render(session, image: image, scale: 1,
                    area: CGRect(x: 0, y: 0, width: 1, height: 1), destination: destination, proof: proof)
                return proof
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The image's registered XMP LangAlt root property `tag` (its owned
    /// (language, text) pairs), queued and counted exactly like
    /// `readMetadataValues(_:)`: a plain native read on the input queue,
    /// never on the main thread, still counted in `pendingWork` so a
    /// close drains it before the image is destroyed, with the session,
    /// image and tag captured by value in the queued job. An absent root
    /// or unregistered tag reports the native NOT_FOUND through the
    /// completion.
    func readMetadataLanguages(_ tag: String,
                               completion: @escaping @MainActor (Result<[EngineSession.MetadataLanguageValue], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result { try session.metadataLanguages(image, tag: tag) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The read-only descriptor of one registered metadata `tag` (facade
    /// slot 128: presence, native multiple-value support, the facade value
    /// kind, the type/format policy bits and the bounded native label,
    /// description and type name), queued and counted exactly like
    /// `readMetadataValues(_:)`: the session, image and tag are captured
    /// explicitly by the queued job, the native call never runs on the
    /// main thread, the read still counts in `pendingWork` so a close
    /// drains it before the image is destroyed, and a completion always
    /// lands on a live image or reports `closed`. An unregistered tag
    /// reports the native NOT_FOUND through the completion.
    func readMetadataTagInfo(_ tag: String,
                             completion: @escaping @MainActor (Result<EngineSession.MetadataTagInfo, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: inputQueue) { [session, image] in
            let result = Result { try session.metadataTagInfo(image, tag: tag) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Sets or removes ONE metadata `tag` with the captured ordered
    /// `values` array (SET requires at least one value; REMOVE takes [])
    /// as one undo step, as counted input work on the input queue — the
    /// same serial queue as every other accepted edit, so it lands behind
    /// them in order. Before queueing, in-flight field/text edits are
    /// committed and an active stroke ended (the
    /// finishInput/endPendingUserEdits convention): both enqueue their
    /// jobs on this queue ahead of this one.
    ///
    /// Admission reads only the cached busy/preview/closing/modal state
    /// (`refuseWhileEditingUnavailable`): metadata edits are image-level,
    /// so pixel/alpha locks and layer/mask/channel target types never
    /// refuse them. The native readiness gate (BUSY under a stroke,
    /// preview or plug-in) still applies on the queue. The completion
    /// reports the engine's own answer — UNSUPPORTED (protected,
    /// LangAlt, new XMP containers), NOT_FOUND (unregistered tag),
    /// INVALID_ARGUMENT (empty SET, multi-value on a single-value tag),
    /// BUSY — unchanged; every refusal leaves the image, its metadata
    /// and its history untouched. The cache reloads only after a
    /// successful change; a no-op (identical values, absent-tag REMOVE)
    /// is a success with no undo.
    func editMetadata(_ tag: String, _ operation: EngineSession.MetadataEdit, values: [String] = [],
                      completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        // Keep the deferred cache/completion stage alive through another
        // document's exclusive work as well as the native input job.
        pendingWork += 1
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.editMetadata(image, tag: tag, operation, values: values) }
            let refresh: Result<(EngineSession.ImageInfo, EngineSession.UndoInfo, EngineSession.History), Error>?
            if case .success = result {
                refresh = Result { (try session.info(image), try session.undoInfo(image), try session.history(image)) }
            } else { refresh = nil }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    if !self.isClosing {
                        // Reload only after a successful change; a refusal
                        // leaves the cached state as it was.
                        if case .success(let state)? = refresh {
                            self.info = state.0
                            self.fileState.syncDirty(state.0.isDirty)
                            self.undoInfo = state.1
                            self.history = state.2
                            self.stateVersion += 1
                            self.onStateChange?()
                        } else if case .failure(let error)? = refresh {
                            self.onError?("Metadata changed, but its document state could not be refreshed: \(error)")
                        }
                        if case .failure(let error) = result { self.onError?(String(describing: error)) }
                    }
                    completion(result)
                }
            }
        }
    }

    /// Sets ONE language-alternative `tag`/`language` pair to `text` as
    /// one undo step, as counted input work on the input queue, mirroring
    /// `editMetadata(_:_:values:completion:)` exactly: admission reads
    /// only the cached busy/preview/closing/modal state
    /// (`refuseWhileEditingUnavailable`), in-flight field/text edits are
    /// committed and an active stroke ended before queueing, a second
    /// closed guard runs after that, and an extra `pendingWork` hold keeps
    /// the deferred cache/completion stage alive through another
    /// document's exclusive work as well as the native input job. The job
    /// is queued as accepted input behind already-accepted input; on
    /// success it reloads info/undo/history/stateVersion/onStateChange,
    /// while the completion lands on the main actor. Every refusal leaves
    /// the image, its metadata and its history untouched.
    func editMetadataLanguage(_ tag: String, language: String, text: String,
                              completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        // Keep the deferred cache/completion stage alive through another
        // document's exclusive work as well as the native input job.
        pendingWork += 1
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.editMetadataLanguage(image, tag: tag, language: language, text: text) }
            let refresh: Result<(EngineSession.ImageInfo, EngineSession.UndoInfo, EngineSession.History), Error>?
            if case .success = result {
                refresh = Result { (try session.info(image), try session.undoInfo(image), try session.history(image)) }
            } else { refresh = nil }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    if !self.isClosing {
                        // Reload only after a successful change; a refusal
                        // leaves the cached state as it was.
                        if case .success(let state)? = refresh {
                            self.info = state.0
                            self.fileState.syncDirty(state.0.isDirty)
                            self.undoInfo = state.1
                            self.history = state.2
                            self.stateVersion += 1
                            self.onStateChange?()
                        } else if case .failure(let error)? = refresh {
                            self.onError?("Metadata changed, but its document state could not be refreshed: \(error)")
                        }
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

    /// Captures the complete ordered layer selection at admission. The
    /// worker validates every id and chooses all copies natively; refresh
    /// is required even on a rare partial Core failure.
    func duplicateSelectedLayers(completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        guard !refuseWhileTargetPending() else { return completion(.failure(DocumentError.busy)) }
        let captured = selectedLayerIDs
        guard !captured.isEmpty else { return completion(.failure(DocumentError.noLayer)) }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueueTargetCommand({ session, image in
            _ = try session.duplicateLayers(image, layers: captured)
        }, completion: completion)
    }

    /// Capture the whole ordered vector before queued selection changes can
    /// retarget Delete. The native operation preflights every source first.
    func deleteSelectedLayers(completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        guard !refuseWhileTargetPending(), !refuseWhileFloatingActive() else {
            return completion(.failure(DocumentError.busy))
        }
        let captured = selectedLayerIDs
        guard !captured.isEmpty else { return completion(.failure(DocumentError.noLayer)) }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueueTargetCommand({ session, image in
            try session.deleteLayers(image, layers: captured)
        }, completion: completion)
    }

    /// Cached admission only; menu validation never reads the native engine.
    func fitSelectedLayersRefusal() -> String? {
        guard acceptsEdits else {
            return isClosing ? DocumentError.closed.localizedDescription : DocumentError.busy.localizedDescription
        }
        if targetCommandIsPending { return DocumentError.busy.localizedDescription }
        if let reason = FloatingControlsLogic.resolveFirstGate(floatingState) { return reason }
        return fitLayerTargetsRefusal(ids: selectedLayerIDs)
    }

    private func fitLayerTargetsRefusal(ids: [Int32]) -> String? {
        if isMaskTargetActive { return "Finish mask editing before resizing layers." }
        if isChannelTargetActive { return "Return to Layers before resizing; the current channel cannot take that edit." }
        let kinds = Dictionary(layers.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return LayerFitPolicy.refusal(ids: ids, kinds: kinds, locks: layerLocks)
    }

    /// Capture every ordered id before finishing field edits or a stroke can
    /// change the cached selection. Native code preflights this same vector.
    func fitSelectedLayers(completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !refuseWhileEditingUnavailable() else {
            return completion(.failure(isClosing ? DocumentError.closed : DocumentError.busy))
        }
        guard !refuseWhileTargetPending(), !refuseWhileFloatingActive() else {
            return completion(.failure(DocumentError.busy))
        }
        let captured = selectedLayerIDs
        if let reason = fitLayerTargetsRefusal(ids: captured) {
            onError?(reason)
            NSSound.beep()
            return completion(.failure(EngineSession.EngineError(
                status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: reason)))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueueTargetCommand({ session, image in
            try session.fitLayersToImage(image, layers: captured)
        }, completion: completion)
    }

    /// Cached admission for the captured source vector. The menu/sheet uses
    /// `.confirmation`; an explicit confirmed command may become a no-op.
    /// This never queries the engine or substitutes the current selection.
    func rasterizeLayerSourcesRefusal(_ ids: [Int32],
                                     request: LayerRasterizePolicy.Request = .confirmation) -> String? {
        rasterizeLayerSourcesError(ids, request: request)?.localizedDescription
    }

    private func rasterizeLayerSourcesError(_ ids: [Int32],
                                           request: LayerRasterizePolicy.Request) -> Error? {
        if isClosing { return DocumentError.closed }
        if !acceptsEdits || targetCommandIsPending { return DocumentError.busy }
        if let reason = FloatingControlsLogic.resolveFirstGate(floatingState) {
            return EngineSession.EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)
        }
        let reason: String?
        if isMaskTargetActive {
            reason = "Finish mask editing before rasterizing layers."
        } else if isChannelTargetActive {
            reason = "Return to Layers before rasterizing; the current channel cannot take that edit."
        } else {
            reason = LayerRasterizePolicy.refusal(ids: ids, layerIDs: Set(layers.map(\.id)),
                sources: layerSources, locks: layerLocks, request: request)
        }
        return reason.map {
            EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: $0)
        }
    }

    /// Rasterize the explicit ordered IDs captured by a confirmation. Field
    /// commits may change selection; the accepted vector still names these
    /// objects in this document. Native code preflights them behind every
    /// earlier input, then performs one batch call/Undo. Counted target work
    /// holds close until both native execution and completion have drained;
    /// its existing cleanup refreshes authoritative state even on failure.
    func rasterizeLayerSources(_ layers: [Int32],
                               completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        let captured = layers
        onUserCommand?()
        if let error = rasterizeLayerSourcesError(captured, request: .explicitCommand) {
            onError?(error.localizedDescription)
            NSSound.beep()
            return completion(.failure(error))
        }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        // Field/text commits may start close, preview or exclusive work, or
        // enqueue a target replacement. Recheck before accepting any work.
        if let error = rasterizeLayerSourcesError(captured, request: .explicitCommand) {
            onError?(error.localizedDescription)
            NSSound.beep()
            return completion(.failure(error))
        }
        enqueueTargetCommand({ session, image in
            try session.rasterizeLayers(image, layers: captured)
        }, completion: completion)
    }

    /// Cached whole-vector admission. Confirmation requires at least one
    /// rasterized source; an already confirmed vector may become a no-op.
    func restoreLayerSourcesRefusal(_ ids: [Int32],
                                   request: LayerRestorePolicy.Request = .confirmation) -> String? {
        restoreLayerSourcesError(ids, request: request)?.localizedDescription
    }

    private func restoreLayerSourcesError(_ ids: [Int32],
                                         request: LayerRestorePolicy.Request) -> Error? {
        if isClosing { return DocumentError.closed }
        if !acceptsEdits || targetCommandIsPending { return DocumentError.busy }
        if let reason = FloatingControlsLogic.resolveFirstGate(floatingState) {
            return EngineSession.EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue), message: reason)
        }
        let reason: String?
        if isMaskTargetActive {
            reason = "Finish mask editing before restoring layer sources."
        } else if isChannelTargetActive {
            reason = "Return to Layers before restoring sources; the current channel cannot take that edit."
        } else {
            reason = LayerRestorePolicy.refusal(ids: ids, layerIDs: Set(layers.map(\.id)),
                sources: layerSources, locks: layerLocks, request: request)
        }
        return reason.map {
            EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: $0)
        }
    }

    /// Restore captured IDs in this document as one native vector command.
    /// File reads use engine-wide exclusive admission after accepted input
    /// drains. A detected native failure can leave a changed prefix, so reload
    /// authoritative state on either outcome while the document remains alive.
    func restoreLayerSources(_ ids: [Int32],
                             completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        let captured = ids
        onUserCommand?()
        func refuse(_ error: Error) {
            onError?(error.localizedDescription)
            NSSound.beep()
            completion(.failure(error))
        }
        if let error = restoreLayerSourcesError(captured, request: .explicitCommand) { return refuse(error) }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
        if let error = restoreLayerSourcesError(captured, request: .explicitCommand) { return refuse(error) }
        var rejection: Error = DocumentError.busy
        enqueueExclusive(label: "Restoring layer sources", admission: {
            if let error = self.restoreLayerSourcesError(captured, request: .explicitCommand) {
                rejection = error
                return false
            }
            return true
        }, rejected: {
            refuse(self.isClosing ? DocumentError.closed : rejection)
        }) { [session, image] in
            let result = Result<Void, Error> { try session.restoreLayerSources(image, layers: captured) }
            DispatchQueue.main.async {
                var delivered = result
                if !self.isClosing {
                    do { try self.reload() }
                    catch {
                        if case .success = delivered { delivered = .failure(error) }
                        else { self.onError?(error.localizedDescription) }
                    }
                }
                if case .failure(let error) = delivered { self.onError?(error.localizedDescription) }
                completion(delivered)
            }
        }
    }

    /// The menu commands act on the layer the engine selects when they
    /// run — layer 0, the adapter's "selected layer at execution" — so a
    /// creation or pick queued ahead of them is what they hit, not the
    /// id the interface last saw selected. Palette rows name their
    /// layer explicitly instead.
    func layerCommand(_ command: EngineSession.LayerCommand) {
        if command == .delete && hasMultipleSelectedLayers { return deleteSelectedLayers() }
        if command == .fitToImage && hasMultipleSelectedLayers { return fitSelectedLayers() }
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        endPendingUserEdits()
        // Other single-layer commands refuse a multi-selection instead
        // of silently editing its primary. Captured batch Delete and Fit
        // take dedicated routes above; New Layer selects its fresh row.
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
                              paintStateVersion: Int? = nil,
                              completion: @escaping @MainActor (Result<Void, Error>) -> Void = { _ in }) {
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        // Ending a field/text edit can itself enqueue a mutation. Paint
        // consent must still describe exactly the idle state it displayed.
        if let version = paintStateVersion,
           stateVersion != version || pendingWork != 0 || isClosing
            || !acceptsEdits || targetCommandIsPending || strokeIsActive
            || selectedLayerIDs != [layer] || activeDrawable != layer
            || isMaskTargetActive || isChannelTargetActive {
            onError?(DocumentError.targetChanged.localizedDescription)
            return completion(.failure(DocumentError.targetChanged))
        }
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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

    /// Layer ▸ New Adjustment Layer… accepted: creates the pass-through
    /// adjustment group with one committed native-default effect as ONE
    /// undo step, at the placement New Layer Group would use — resolved
    /// from the layers as the queue leaves them, never from the cache. The
    /// creation is a counted target command queued behind accepted input,
    /// after this document's pending edits end; like group creation it
    /// takes no single-layer, mask or channel target restriction, since it
    /// only inserts metadata into the hierarchy. The mode gate reads the
    /// cached color state: RGB and grayscale only — Indexed refuses here
    /// and in the native guard. The completion receives the created
    /// layer and effect ids on the main actor exactly once; failures are
    /// also reported through `onError`.
    func createAdjustmentLayer(name: String, operation: String,
                               completion: @escaping @MainActor (Result<(layer: Int32, effect: Int32), Error>) -> Void) {
        guard !isClosing else {
            onError?(DocumentError.closed.localizedDescription)
            return completion(.failure(DocumentError.closed))
        }
        if let reason = AdjustmentLayerLogic.modeAdmission(colorInfo.mode).reason {
            onError?(reason)
            NSSound.beep()
            return completion(.failure(AdjustmentLayerLogic.InputError(message: reason)))
        }
        guard !refuseWhileEditingUnavailable() else { return completion(.failure(DocumentError.busy)) }
        guard !refuseWhileFloatingActive() else { return completion(.failure(DocumentError.busy)) }
        endPendingUserEdits()
        let created = CreatedAdjustmentBox()
        enqueueTargetCommand({ session, image in
            let fresh = try session.layers(image)
            let placement = LayerTree(layers: fresh)
                .newGroupPlacement(nearActive: fresh.first(where: \.isSelected)?.id)
            let ids = try session.createAdjustmentLayer(image: image, parent: placement.parent,
                                                        index: Int32(placement.index),
                                                        operation: operation, name: name)
            created.value = ids
        }, completion: { result in
            completion(result.flatMap { _ in
                guard let value = created.value else { return .failure(DocumentError.targetChanged) }
                return .success(value)
            })
        })
    }

    /// Reads the engine's filter-operation catalog off the main thread as
    /// one counted job on the long queue — a close waits for it — and
    /// installs the list in the shared catalog cache that
    /// `editEffectParameters` resolves operations through. The completion
    /// runs on the main actor with the actual error on failure; an unsuccessful
    /// query never replaces the existing catalog cache.
    func loadNativeFilterOperations(completion: @escaping @MainActor (Result<[EngineSession.FilterOperation], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        enqueue(on: longQueue) { [session] in
            let result = Result { try session.filterOperations() }
            DispatchQueue.main.async {
                guard !self.isClosing else { return completion(.failure(DocumentError.closed)) }
                if case .success(let operations) = result { NativeFilterCatalog.shared.install(operations) }
                completion(result)
            }
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

    private final class LayerChangeResult: @unchecked Sendable {
        // Written on inputQueue, read only by its dispatched afterFinish.
        var value: Result<Void, Error>?
    }

    func changeLayer(_ layer: Int32, _ change: EngineSession.LayerChange,
                     completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        guard !refuseWhileEditingUnavailable() else {
            completion?(.failure(isClosing ? DocumentError.closed : DocumentError.busy)); return
        }
        endPendingUserEdits()
        // Finishing a field can close the document or start exclusive work.
        guard !refuseWhileEditingUnavailable() else {
            completion?(.failure(isClosing ? DocumentError.closed : DocumentError.busy)); return
        }
        let semantic = SemanticImageCommand.layerProperties(.init(change))
        guard let completion else {
            run(semantic: semantic, recorderLayer: layer) { session, image in
                try session.changeLayer(layer, image: image, change)
            }
            return
        }
        let capture: RecorderCapture?
        do { capture = try reserveRecording(semantic, explicitLayer: layer) }
        catch {
            assertionFailure("A recording log refused an admitted layer change: \(error)")
            completion(.failure(error))
            return
        }
        let result = LayerChangeResult()
        // Keep reconciliation alive even if another document starts exclusive
        // work between this input and its callback. Close drains both stages.
        pendingWork += 1
        enqueue(on: inputQueue, input: true, afterFinish: {
            EngineActivity.shared.whenIdle {
                if !self.isClosing {
                    do { try self.reload() }
                    catch { self.onError?("The layer state could not be refreshed: \(error)") }
                }
                self.jobDidFinish(input: false)
                completion(result.value ?? .failure(DocumentError.busy))
            }
        }) { [session, image] in
            let confirmed = Self.confirmRecordingCapture(capture, session: session, image: image)
            let answer = Result { try session.changeLayer(layer, image: image, change) }
            result.value = answer
            if case .failure(let error) = answer { self.report(error) }
            self.settleRecording(capture, result: answer.map { semantic }, confirmed: confirmed)
        }
        // Queue/count first: Recorder observers may immediately request close.
        if capture != nil { notifyRecorderChanged() }
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
        let command = SemanticImageCommand.transformImage(transform)
        run(semantic: command, command.apply)
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

    /// Commits a new editor's original floating expectation. The native
    /// compound action may anchor that exact float; it never retargets to
    /// one introduced while typing. Reconcile actual state even on failure.
    func addText(_ text: String, settings: EngineSession.TextSettings, at position: CGPoint,
                 expectedFloating: EngineSession.FloatingState) {
        guard !text.isEmpty, !refuseWhileEditingUnavailable(), !refuseWhileTargetPending() else { return }
        enqueueTargetCommand { session, image in
            _ = try session.addTextLayer(image: image, text: text, settings: settings, at: position,
                                        expectedFloating: expectedFloating)
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
        let command = SemanticImageCommand.scale(width: width, height: height)
        run(semantic: command, command.apply)
    }

    func resizeCanvas(width: Int, height: Int, offset: CGPoint, fill: NSColor) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        let capturedFill = (fill.copy() as? NSColor) ?? fill
        runDeferredImageCommand { session, image in
            let value = try session.resizeCanvas(image, width: width, height: height, offset: offset, fill: capturedFill)
            return .resizeCanvas(width: width, height: height, offset: offset, fill: value)
        }
    }

    func crop(to rect: CGRect) {
        guard !refuseWhileEditingUnavailable() else { return }
        guard !refuseWhileFloatingActive() else { return }
        let command = SemanticImageCommand.crop(rect)
        run(semantic: command, command.apply)
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
    /// Makes `id` the image's whole selected-path list — one row, so a
    /// palette click resolves an earlier multi-selection to exactly this
    /// path — through the native batch write (slot 136). The active path
    /// follows the native selection: exactly this one path, never a stale
    /// remembered row. Path selection is allowed under a floating
    /// selection (the native contract), and changes no paint target.
    func selectPath(_ id: Int32) {
        guard paths.contains(where: { $0.id == id }), !refuseWhileEditingUnavailable() else { return }
        if pathShapes[id] == nil { pathShapes[id] = try? session.path(id, image: image) }
        queueItemSelection([id], kind: .path)
    }

    /// Adds a path with `shape` and makes it the active one. Waits for the
    /// engine, so the next edit knows the path.
    @discardableResult
    func addPath(_ shape: VectorPath) -> Int32? {
        guard !refuseWhileEditingUnavailable() else { return nil }
        let result = inputQueue.sync { [session, image] in
            Result { () -> Int32 in
                let id = try session.setPath(nil, image: image, shape)
                // Make the new path the image's whole path selection, so
                // the reload's exact-one active-path rule keeps it active.
                try? session.selectItems([id], kind: .path, image: image)
                return id
            }
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
        guard !refuseWhileEditingUnavailable(allowingReplayRead: true), let snapshotHandler else { return }
        snapshotHandler(self)
    }

    /// Queues a native duplicate behind pending input — in-flight
    /// strokes and text edits are part of the copy. The callback runs on
    /// the main actor bound to this document with the new engine image
    /// or the error, whoever is front document then. The work is counted,
    /// so a close waits for it before freeing this image.
    func snapshot(completion: @escaping @MainActor (Result<Int32, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard acceptsImageReads else { return completion(.failure(DocumentError.busy)) }
        if !recorder.isReplaying { endPendingUserEdits() }
        enqueueExclusive(effect: .readsPixels, label: "Creating a snapshot", rejected: { completion(.failure(DocumentError.busy)) }) { [session, image] in
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
    private func refuseWhileEditingUnavailable(forPreviewWork: Bool = false, allowingReplayRead: Bool = false) -> Bool {
        onUserCommand?()
        if recorder.isReplaying && !allowingReplayRead {
            onError?("Cancel Recorder replay before editing the image.")
            return true
        }
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
        // Replay admission already finished fields/strokes. Read-only exclusive
        // work must drain its accepted step without committing new user edits.
        guard !recorder.isReplaying else { return }
        endPendingUserEdits()
        if strokeIsActive { endStroke() }
    }

    // MARK: Plug-in commands

    /// Whether the command can run on the selected layers. Asks the engine
    /// once per change of the image.
    func canRun(_ procedure: EngineSession.Procedure) -> Bool {
        guard !recorder.isReplaying else { return false }
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
        guard !isTransferringClipboard, !isSavingForClose, !EngineActivity.shared.isBusy, !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
        // A plug-in runs on the engine's whole selected-layer list; under
        // a multi-selection that would be a batch operation, so it refuses.
        if let reason = LayerSelectionPolicy.refusal(count: selectedLayerIDs.count,
                                                     action: procedure.label.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) {
            return completion(.failure(DocumentError.multipleLayersSelected(reason)))
        }
        // Several selected channels leave no single drawable target either.
        if let reason = ItemSelectionPolicy.refusal(count: selectedChannelIDs.count, kind: .channel,
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
        if recorder.isReplaying { try? cancelReplay() }
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
        guard operation != .cutLayer || !recorder.isReplaying else { return completion(DocumentError.busy) }
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
        if let reason = ItemSelectionPolicy.refusal(count: selectedChannelIDs.count, kind: .channel, action: "Paste") {
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
        if let reason = ItemSelectionPolicy.refusal(count: selectedChannelIDs.count, kind: .channel, action: "Paste Into") {
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
        enqueueExclusive(effect: .readsPixels, label: "Exporting \(url.lastPathComponent)", rejected: { completion(DocumentError.busy) }) { [session, image] in
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
        enqueueExclusive(effect: .readsPixels, label: "Saving \(url.lastPathComponent)", rejected: { completion(DocumentError.busy) }) { [session, image] in
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
        enqueueExclusive(effect: .readsPixels, label: label, rejected: { completion(DocumentError.busy) }) { [session, image] in
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
        if !recorder.isReplaying { endPendingUserEdits() }
        enqueueExclusive(effect: .readsPixels, label: "Preparing to print",
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

    /// Stops accepting edits immediately, without destroying the image.
    /// A document window calls this before its renderer begins draining;
    /// accepted input and teardown remain counted until native close.
    func beginClosing() {
        guard !isClosing else { return }
        if strokeIsActive { endStroke() }
        isClosing = true
        if recorder.isReplaying { try? cancelReplay() }
    }

    /// Destroys the engine image once accepted work and teardown drain.
    /// A window calls this only after its renderer has stopped. Bare
    /// document callers begin closing here without a separate render phase.
    func closeImageWhenDrained(completion: @escaping @MainActor () -> Void = {}) {
        guard !nativeCloseIsScheduled else { return }
        beginClosing()
        nativeCloseIsScheduled = true
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
        var colorBalance: EngineSession.ColorBalanceSettings? = nil
        var hueSaturation: EngineSession.HueSaturationSettings? = nil
        var levels: EngineSession.LevelsSettings? = nil
        var curves: EngineSession.CurvesSettings? = nil
    }

    /// Source preparation reads remain counted through their deferred reply.
    func loadFilterProperties(_ operation: String,
                              completion: @escaping @MainActor (Result<[EngineSession.FilterProperty], Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        enqueue(on: longQueue) { [session] in
            let result = Result { () throws -> [EngineSession.FilterProperty] in
                var properties = try session.filterOperationProperties(operation)
                for index in properties.indices where properties[index].kind == .enumeration {
                    properties[index].choices = try session.filterEnumChoices(operation, property: properties[index].name)
                }
                return properties
            }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    completion(self.isClosing ? .failure(DocumentError.closed) : result)
                }
            }
        }
    }

    /// Cached admission only. The source chooser keeps its original target.
    func sourceFilterRefusal(target: Int32) -> String? {
        if !acceptsEdits { return "Finish or cancel the current operation first." }
        if targetCommandIsPending { return "Wait for the layer change to finish." }
        if floatingState.isActive { return "Resolve the floating selection first." }
        if colorInfo.mode != .rgb && colorInfo.mode != .grayscale { return "Convert the image to RGB or grayscale first." }
        if selectedLayerIDs != [target] || activeDrawable != target { return "Select the original target layer before previewing." }
        guard let source = layerSources[target], source.kind == .pixel || source.isRasterized else {
            return "Rasterize the editable target layer first."
        }
        if layerLocks[target]?.effective.contains(.pixels) == true { return "Unlock the target layer's pixels first." }
        return nil
    }

    /// An explicit captured target and source, queued behind accepted input.
    /// startPreview has already reserved the document's preview gate.
    func beginFilterPreview(operation: String, properties: [EngineSession.FilterProperty],
                            target: Int32, source: Int32,
                            completion: @escaping @MainActor (Result<FilterPreviewStart, Error>) -> Void) {
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isSavingForClose, !isTransferringClipboard, !PlugInCommands.isRunning,
              !EngineActivity.shared.isBusy, !targetCommandIsPending,
              selectedLayerIDs == [target], activeDrawable == target else {
            return completion(.failure(DocumentError.busy))
        }
        pendingWork += 1
        inputQueue.async { [session, image] in
            let result = Result<FilterPreviewStart, Error> {
                try self.requirePaintTarget()
                let filter = try session.beginFilter(image: image, drawable: target, operation: operation, source: source)
                var values: [String: EngineSession.FilterValue] = [:]
                for property in properties where property.kind.isEditable {
                    values[property.name] = try? session.filterProperty(filter, property.name)
                }
                return FilterPreviewStart(filter: filter, values: values)
            }
            DispatchQueue.main.async {
                defer { self.jobDidFinish(input: false) }
                completion(result)
            }
        }
    }

    /// Displace's captured pair follows the same counted preview start as the
    /// single-source filters. Native169 freshly validates all three identities.
    func beginDisplacePreview(properties: [EngineSession.FilterProperty], target: Int32,
                              xSource: Int32, ySource: Int32,
                              completion: @escaping @MainActor (Result<FilterPreviewStart, Error>) -> Void) {
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isSavingForClose, !isTransferringClipboard, !PlugInCommands.isRunning,
              !EngineActivity.shared.isBusy, !targetCommandIsPending,
              selectedLayerIDs == [target], activeDrawable == target else {
            return completion(.failure(DocumentError.busy))
        }
        pendingWork += 1
        inputQueue.async { [session, image] in
            let result = Result<FilterPreviewStart, Error> {
                try self.requirePaintTarget()
                let filter = try session.beginDisplace(image: image, drawable: target, xSource: xSource, ySource: ySource)
                var values: [String: EngineSession.FilterValue] = [:]
                for property in properties where property.kind.isEditable {
                    values[property.name] = try? session.filterProperty(filter, property.name)
                }
                return FilterPreviewStart(filter: filter, values: values)
            }
            DispatchQueue.main.async {
                defer { self.jobDidFinish(input: false) }
                completion(result)
            }
        }
    }

    /// Read initial settings on the worker; failed typed reads abort the new session.
    private nonisolated static func previewValues(_ filter: Int32, operation: String?,
                                                  properties: [EngineSession.FilterProperty],
                                                  session: EngineSession) throws -> [String: EngineSession.FilterValue] {
        if operation == "gimp:brightness-contrast" {
            do {
                let settings = try session.brightnessContrastSettings(filter)
                return ["brightness": .number(settings.brightness), "contrast": .number(settings.contrast)]
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        }
        var values: [String: EngineSession.FilterValue] = [:]
        for property in properties where property.kind.isEditable {
            values[property.name] = try? session.filterProperty(filter, property.name)
        }
        return values
    }

    private nonisolated static func previewStart(_ filter: Int32, operation: String?,
                                                 properties: [EngineSession.FilterProperty],
                                                 session: EngineSession) throws -> FilterPreviewStart {
        if operation == "gimp:curves" {
            do {
                return FilterPreviewStart(filter: filter, values: [:], curves: try session.curvesSettings(filter))
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        }
        if operation == "gimp:levels" {
            do {
                return FilterPreviewStart(filter: filter, values: [:], levels: try session.levelsSettings(filter))
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        }
        if operation == "gimp:hue-saturation" {
            do {
                return FilterPreviewStart(filter: filter, values: [:], hueSaturation: try session.hueSaturationSettings(filter))
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        }
        if operation == "gimp:color-balance" {
            do {
                return FilterPreviewStart(filter: filter, values: [:], colorBalance: try session.colorBalanceSettings(filter))
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        }
        return FilterPreviewStart(filter: filter,
            values: try previewValues(filter, operation: operation, properties: properties, session: session))
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
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
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
                return try Self.previewStart(filter, operation: operation, properties: properties, session: session)
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
                            operation: String? = nil,
                            completion: @escaping @MainActor (Result<FilterPreviewStart, Error>) -> Void) {
        guard !recorder.isReplaying else { return completion(.failure(DocumentError.busy)) }
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard canChangeEffect(effect, on: drawable) else {
            return completion(.failure(DocumentError.targetChanged))
        }
        guard !EngineActivity.shared.isBusy else { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session, image] in
            let result = Result<FilterPreviewStart, Error> {
                let filter = try session.beginEditingEffect(effect, on: drawable, image: image)
                return try Self.previewStart(filter, operation: operation, properties: properties, session: session)
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

    func setBrightnessContrast(_ filter: Int32, _ settings: EngineSession.BrightnessContrastSettings,
                               completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.setBrightnessContrastSettings(filter, to: settings) }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    func setColorBalance(_ filter: Int32, _ settings: EngineSession.ColorBalanceSettings,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.setColorBalanceSettings(filter, to: settings) }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }


    func setHueSaturation(_ filter: Int32, _ settings: EngineSession.HueSaturationSettings,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.setHueSaturationSettings(filter, to: settings) }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    func setLevels(_ filter: Int32, _ settings: EngineSession.LevelsSettings,
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.setLevelsSettings(filter, to: settings) }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    func loadInputHistogram(_ filter: Int32,
                            completion: @escaping @MainActor (Result<EngineSession.InputHistogram, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.inputHistogram(filter) }
            DispatchQueue.main.async {
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    completion(self.isClosing ? .failure(DocumentError.closed) : result)
                }
            }
        }
    }

    func autoLevels(_ filter: Int32,
                    completion: @escaping @MainActor (Result<EngineSession.LevelsSettings, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { try session.autoLevels(filter) }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
        }
    }

    func setCurves(_ filter: Int32, patch: CurvesDraft.Patch,
                   completion: @escaping @MainActor (Result<EngineSession.CurvesSettings, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        if refuseWhileEditingUnavailable(forPreviewWork: true) { return completion(.failure(DocumentError.busy)) }
        pendingWork += 1
        inputQueue.async { [session] in
            let result = Result { () throws -> EngineSession.CurvesSettings in
                switch patch {
                case .curve(let edit): return try session.editCurve(filter, edit: edit)
                case .trc(let trc): return try session.setCurvesTRC(filter, to: trc)
                }
            }
            DispatchQueue.main.async {
                completion(result)
                self.jobDidFinish(input: false)
            }
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

    /// Refuses a single-target command while more than one channel is
    /// selected: the paint target is ambiguous (no drawable), so nothing
    /// may silently act on the first selected channel. Returns true when
    /// refused.
    func refuseMultiChannelCommand(_ action: String) -> Bool {
        guard let reason = ItemSelectionPolicy.refusal(count: selectedChannelIDs.count,
                                                        kind: .channel, action: action)
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
        guard !isClosing else {
            completion?(.failure(DocumentError.closed))
            return
        }
        nextTargetCommandToken += 1
        let token = nextTargetCommandToken
        pendingTargetCommands.insert(token)
        // Hold the deferred cache/completion stage too, so an exclusive
        // operation admitted after this input cannot overtake its cleanup.
        pendingWork += 1
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
                EngineActivity.shared.whenIdle {
                    defer { self.jobDidFinish(input: false) }
                    if self.pendingTargetCommands.remove(token) != nil, case .success = result {
                        self.rejectedTargetPick = false
                    }
                    if !self.isClosing {
                        // Core can report a partial native insertion failure;
                        // always reconcile the actual state, never an optimistic
                        // selection written from the captured result vector.
                        if case .failure(let error) = result { self.onError?(String(describing: error)) }
                        do { try self.reload() }
                        catch { self.onError?("The image state could not be refreshed: \(error)") }
                    }
                    completion?(result)
                }
            }
        }
        // Queue/count first: this callback may itself request a close.
        onStateChange?()
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
        guard !refuseMultiChannelCommand("Paint") else { return false }
        guard activeDrawable != nil else {
            onError?(DocumentError.targetChanged.localizedDescription)
            return false
        }
        guard let target = paintTarget, !refuseStructuredPaint(on: target) else { return false }
        return run { session, image in
            try self.requirePaintTarget()
            try self.requireRasterizedPaintTarget(target)
            try work(session, image)
        }
    }

    /// Masks and channels have their own pixels. Only painting the layer
    /// itself can replace its structured source with raster content.
    private func refuseStructuredPaint(on target: PaintTarget) -> Bool {
        guard case .layer(let layer) = target else { return false }
        guard let source = layerSources[layer] else {
            onError?("The layer's source state is unavailable. Select the layer again before painting.")
            return true
        }
        guard Self.paintNeedsRasterize(source) else { return false }
        guard pendingWork == 0 else {
            onError?(DocumentError.busy.localizedDescription)
            return true
        }
        guard source.hasSource else {
            onError?("The layer's editable source is unavailable. Select another paint target.")
            return true
        }
        if layerLocks[layer]?.effective.isDisjoint(with: [.pixels, .position]) == false {
            onError?("Unlock the layer's pixels and position before rasterizing it for painting.")
            return true
        }
        if let request = onPaintNeedsRasterize {
            request(layer, stateVersion)
        } else {
            onError?("Rasterize the layer before painting (Layer > Rasterize Layer).")
        }
        return true
    }

    private nonisolated static func paintNeedsRasterize(_ source: EngineSession.LayerSource) -> Bool {
        !source.isRasterized && (source.kind == .text || source.kind == .link || source.kind == .vector)
    }

    /// Recheck behind accepted input: an Undo queued before this edit can
    /// restore editable source after the main-thread cache admitted it.
    private nonisolated func requireRasterizedPaintTarget(_ target: PaintTarget) throws {
        guard case .layer(let layer) = target else { return }
        let source = try session.layerSource(layer, image: image)
        guard !Self.paintNeedsRasterize(source) else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                message: "Rasterize the layer before painting (Layer > Rasterize Layer).")
        }
    }

    private nonisolated func requirePaintTarget() throws {
        guard paintTargetIsValid else { throw DocumentError.targetChanged }
    }

    /// Recorder-specific UI subscriptions leave the existing single callback
    /// intact. A snapshot permits listeners to detach or retarget reentrantly.
    func addRecorderObserver(scope: RecorderObserverScope = .commands, _ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        recorderObservers[token] = RecorderObserver(scope: scope, callback: observer)
        return token
    }

    func removeRecorderObserver(_ token: UUID) {
        recorderObservers.removeValue(forKey: token)
    }

    private func notifyRecorderChanged() {
        let observers = recorderObservers.values.map(\.callback)
        onRecorderChange?()
        observers.forEach { $0() }
    }

    private func notifyRecorderPresentationChanged() {
        let observers = recorderObservers.values.filter { $0.scope == .presentation }.map(\.callback)
        observers.forEach { $0() }
    }

    func startRecording() throws {
        guard !isClosing else { throw DocumentError.closed }
        try recorder.startRecording()
        resetRecorderSidecars()
        notifyRecorderChanged()
    }

    func stopRecording() throws {
        try recorder.stopRecording()
        notifyRecorderChanged()
    }

    @discardableResult
    func clearRecording() -> Bool {
        guard !recorder.isReplaying else {
            onError?("Cancel Recorder replay before clearing the recording.")
            return false
        }
        recorder.clear()
        resetRecorderSidecars()
        notifyRecorderChanged()
        return true
    }

    private func resetRecorderSidecars() {
        recorderTargetContexts.removeAll()
        recorderSymbols.removeAll()
        recorderDescriptions = RecorderDescriptionCatalog()
        recorderBindingDescriptions.removeAll()
        recorderLoadedFile = nil
        recorderFileMetadata = RecorderFileMetadata(origin: .init(imageLabel: name,
            initialWidth: info.width, initialHeight: info.height))
        recorderRevision = UUID()
        recorderSavedRevision = nil
    }

    var hasUnsavedRecordingChanges: Bool {
        recorderFileMetadata.hasUnsavedChanges(in: recorder, revision: recorderRevision, savedRevision: recorderSavedRevision)
    }

    func renameRecording(_ name: String) throws {
        guard !isClosing else { throw DocumentError.closed }
        if try recorderFileMetadata.rename(name) {
            recorderRevision = UUID()
            notifyRecorderChanged()
        }
    }

    /// Identifies the owning document and current settled recording revision.
    func recorderInstallCheckpoint() throws -> RecorderInstallCheckpoint {
        try requireRecorderReadiness(holding: 0)
        return RecorderInstallCheckpoint(owner: recoveryID, revision: recorderRevision)
    }

    /// Read and validate the complete file away from MainActor. Preparing a
    /// file never chooses targets or changes this document's current log.
    func prepareRecordingFile(at url: URL, checkpoint: RecorderInstallCheckpoint,
                              completion: @escaping @MainActor (Result<RecorderFileSemanticBridge.PreparedRecording, Error>) -> Void) {
        do { try requireRecorderReadiness(checkpoint, holding: 0) }
        catch { return completion(.failure(error)) }
        pendingWork += 1
        Self.recorderFileQueue.async {
            let prepared = Result { try RecorderFileSemanticBridge.prepare(RecorderFileStore.load(from: url)) }
            DispatchQueue.main.async {
                defer { self.jobDidFinish(input: false) }
                completion(Result {
                    try self.requireRecorderReadiness(checkpoint, holding: 1)
                    return try prepared.get()
                })
            }
        }
    }

    /// Save the admitted revision to the chosen URL. The file name and the
    /// recording's intrinsic name are independent. An accepted write can
    /// finish after an edit or close request, with its result reported once
    /// while the work count still holds the document.
    func saveRecording(to url: URL, checkpoint: RecorderInstallCheckpoint,
                       completion: @escaping @MainActor (Result<RecorderSaveOutcome, Error>) -> Void) {
        do { try requireRecorderReadiness(checkpoint, holding: 0) }
        catch { return completion(.failure(error)) }

        let metadata = recorderFileMetadata
        let log = recorder
        let descriptions = recorderDescriptions
        let bindings = recorderBindingDescriptions
        let loaded = recorderLoadedFile
        pendingWork += 1
        Self.recorderFileQueue.async {
            let written = Result {
                let file: RecorderFileValue
                if let loaded { file = metadata.namedCopy(of: loaded) }
                else {
                    file = try RecorderFileCodec.snapshot(log, recordingID: metadata.recordingID, name: metadata.name,
                                                          origin: metadata.origin, descriptions: descriptions, bindings: bindings)
                }
                try RecorderFileStore.save(file, to: url)
            }
            DispatchQueue.main.async {
                defer { self.jobDidFinish(input: false) }
                switch written {
                case .failure(let error): completion(.failure(error))
                case .success:
                    if self.recorderRevision == checkpoint.revision {
                        self.recorderSavedRevision = checkpoint.revision
                        self.notifyRecorderChanged()
                    }
                    // An observer may have edited the recording reentrantly.
                    let outcome: RecorderSaveOutcome = self.recorderRevision == checkpoint.revision
                        ? .savedCurrentRevision : .savedEarlierRevision
                    completion(.success(outcome))
                }
            }
        }
    }

    /// Verify bindings against this image on its input queue. The MainActor
    /// completion runs once while the accepted read still holds its work count.
    /// The ordinary drain runs after completion, including any requested close.
    func installRecording(_ prepared: RecorderFileSemanticBridge.PreparedRecording,
                          checkpoint: RecorderInstallCheckpoint,
                          choices: [UUID: RecorderInstallChoice],
                          completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        do { try requireRecorderReadiness(checkpoint, holding: 0) }
        catch { return completion(.failure(error)) }
        let version = stateVersion
        pendingWork += 1
        inputQueue.async { [session, image] in
            let checked = Result { try Self.bindRecording(prepared, choices: choices, session: session, image: image) }
            DispatchQueue.main.async {
                // Keep the count through notifications and completion, even
                // if either callback asks to close the document reentrantly.
                defer { self.jobDidFinish(input: false) }
                let committed = Result<Void, Error> {
                    try self.requireRecorderReadiness(checkpoint, holding: 1)
                    guard self.stateVersion == version else { throw RecorderInstallError.changedImage }
                    let installation = try checked.get()
                    self.recorder = installation.log
                    self.recorderTargetContexts = installation.contexts
                    self.recorderDescriptions = installation.descriptions
                    self.recorderBindingDescriptions = installation.bindings
                    self.recorderSymbols = installation.symbols
                    self.recorderLoadedFile = installation.file
                    self.recorderFileMetadata = RecorderFileMetadata(file: installation.file)
                    self.recorderRevision = UUID()
                    self.recorderSavedRevision = self.recorderRevision
                    self.recorderReplayGeneration = UUID()
                    self.recorderReplayWaitingGeneration = nil
                }
                if case .success = committed { self.notifyRecorderChanged() }
                completion(committed)
            }
        }
    }

    private func requireRecorderReadiness(_ checkpoint: RecorderInstallCheckpoint? = nil,
                                          holding workCount: Int) throws {
        guard !isClosing else { throw DocumentError.closed }
        if let checkpoint {
            guard checkpoint.owner == recoveryID else { throw RecorderInstallError.wrongDocument }
            guard checkpoint.revision == recorderRevision else { throw RecorderInstallError.staleRecording }
        }
        guard !recorder.isRecording, !recorder.isReplaying, recorder.pendingCount == 0 else {
            throw RecorderInstallError.unsettled
        }
        guard acceptsImageReads, !strokeIsActive, !endingPendingEdits,
              pendingWork == workCount, !recorderTargetWorkPending else { throw DocumentError.busy }
    }

    private nonisolated static func bindRecording(_ prepared: RecorderFileSemanticBridge.PreparedRecording,
                                                  choices: [UUID: RecorderInstallChoice],
                                                  session: EngineSession, image: Int32) throws -> RecorderInstallation {
        let file = prepared.file
        var required: Set<UUID> = []
        for row in file.records {
            if case .success(_, let binding) = row.outcome {
                required.formUnion(try RecorderFileCodec.referencedSymbols(binding))
            }
        }
        guard Set(choices.keys) == required else { throw RecorderInstallError.incompleteChoices }
        _ = try session.info(image)

        let needsLayers = choices.values.contains { if case .layer = $0 { return true }; return false }
        let needsChannels = choices.values.contains { if case .channel = $0 { return true }; return false }
        let needsQuickMask = choices.values.contains { if case .quickMask = $0 { return true }; return false }
        let layerIDs = needsLayers ? Set(try session.layers(image).map(\.id)) : []
        let channelIDs = needsChannels ? Set(try session.channels(image).filter { !$0.isQuickMask }.map(\.id)) : []
        let liveQuickMask = needsQuickMask ? try session.quickMask(image) : nil

        var targets: [UUID: RecorderRuntimeTarget] = [:]
        var symbols: [RecorderRuntimeTarget: UUID] = [:]
        var observations: [UUID: RecorderDescriptionObservation] = [:]
        var names: [UUID: String] = [:]
        for symbol in file.symbols {
            observations[symbol.id] = .available(symbol.description)
            names[symbol.id] = symbol.description.name
            guard let choice = choices[symbol.id] else { continue }
            let unavailable = RecorderInstallError.unavailableTarget(symbol.description.name)
            let target: RecorderRuntimeTarget
            switch symbol.description.kind {
            case .pixel, .group, .text, .link, .vector:
                guard case .layer(let id) = choice, id > 0, layerIDs.contains(id) else { throw unavailable }
                target = .layer(id)
            case .channel:
                guard case .channel(let id) = choice, id > 0, channelIDs.contains(id) else { throw unavailable }
                target = .channel(id)
            case .quickMask:
                guard case .quickMask(let id) = choice, id > 0,
                      liveQuickMask?.enabled == true, liveQuickMask?.channel == id else { throw unavailable }
                target = .channel(id)
            }
            guard symbols[target] == nil else { throw RecorderInstallError.duplicateTarget }
            targets[symbol.id] = target
            symbols[target] = symbol.id
        }

        func layer(_ symbol: UUID) throws -> Int32 {
            guard case .layer(let id)? = targets[symbol] else { throw RecorderInstallError.incompleteChoices }
            return id
        }
        func channel(_ symbol: UUID) throws -> Int32 {
            guard case .channel(let id)? = targets[symbol] else { throw RecorderInstallError.incompleteChoices }
            return id
        }

        var bindings: [Int: RecorderBindingDescription] = [:]
        var contexts: [Int: RecorderContext] = [:]
        var liveMasks: [Int32: Int32] = [:]
        for row in file.records {
            guard case .success(_, let binding) = row.outcome else { continue }
            bindings[row.ordinal] = binding
            switch binding {
            case .none: break
            case .unavailable(let reason): throw RecorderFileError.invalid(reason)
            case .layer(let symbol): contexts[row.ordinal] = .layer(try layer(symbol))
            case .context(let saved):
                var masks: [Int32: EngineSession.MaskState] = [:]
                for mask in saved.masks {
                    let owner = try layer(mask.owner)
                    var id: Int32 = 0
                    if mask.isPresent {
                        if let known = liveMasks[owner] { id = known }
                        else {
                            id = try session.layerMask(owner, image: image).mask
                            guard id > 0 else { throw RecorderInstallError.missingMask(names[mask.owner] ?? "recorded layer") }
                            liveMasks[owner] = id
                        }
                    }
                    masks[owner] = .init(mask: id, enabled: mask.enabled, editing: mask.editing, showing: mask.showing)
                }
                let target: PaintTarget
                switch saved.target {
                case .layer(let symbol): target = .layer(try layer(symbol))
                case .channel(let symbol), .quickMask(let symbol): target = .channel(try channel(symbol))
                case .mask(let symbol):
                    let owner = try layer(symbol)
                    guard let mask = masks[owner], mask.mask > 0 else {
                        throw RecorderInstallError.missingMask(names[symbol] ?? "recorded layer")
                    }
                    target = .mask(layer: owner, drawable: mask.mask)
                }
                // Keep the recorded flags and order as replay expectations.
                // Only the explicitly bound runtime handles come from A.
                let color = saved.quickMask.color
                let quickMask = EngineSession.QuickMaskState(enabled: saved.quickMask.enabled,
                    channel: try saved.quickMask.symbol.map(channel) ?? 0, inverted: saved.quickMask.inverted,
                    color: NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                                   blue: CGFloat(color.blue), alpha: CGFloat(color.alpha)))
                contexts[row.ordinal] = .target(.init(layers: try saved.layers.map(layer),
                    channels: try saved.channels.map(channel), target: target, masks: masks, quickMask: quickMask))
            }
        }
        var descriptions = RecorderDescriptionCatalog()
        descriptions.acceptFirst(observations)
        // A prepared candidate can be reused. Each install needs its own epoch.
        let log = try RecorderLog(settledRecords: prepared.log.records)
        return RecorderInstallation(log: log, file: file, contexts: contexts,
                                    descriptions: descriptions, bindings: bindings, symbols: symbols)
    }

    /// Replay uses this document's current native image only. Each step keeps
    /// its normal Undo entry; earlier successful steps are not rolled back.
    func startReplay() throws {
        if let reason = recorderReplayBlockReason() { throw RecorderReplayError(message: reason) }
        endPendingUserEdits()
        if let reason = recorderReplayBlockReason() { throw RecorderReplayError(message: reason) }
        try recorder.beginReplay()
        recorderReplayGeneration = UUID()
        recorderReplayWaitingGeneration = nil
        let generation = recorderReplayGeneration
        notifyRecorderChanged()
        continueRecorderReplay(generation: generation)
    }

    func cancelReplay() throws {
        try recorder.cancelReplay()
        recorderReplayGeneration = UUID()
        recorderReplayWaitingGeneration = nil
        notifyRecorderChanged()
    }

    var replayStatus: RecorderLog<SemanticImageCommand>.ReplayStatus { recorder.replayStatus }

    private func recorderReplayBlockReason(continuing: Bool = false) -> String? {
        if isClosing { return DocumentError.closed.localizedDescription }
        if recorder.isReplaying && !continuing { return "Recorder replay is already running." }
        if EngineActivity.shared.isBusy || PlugInCommands.isRunning || filterPreviewIsOpen
            || isSavingForClose || isTransferringClipboard {
            return "Finish the current engine, filter, save or clipboard operation before replaying."
        }
        if strokeIsActive { return "Finish the current stroke before replaying." }
        if endingPendingEdits { return "Finish pending field edits before replaying." }
        if pendingWork != 0 || recorderTargetWorkPending {
            return "Wait for accepted image and target changes to finish before replaying."
        }
        return nil
    }

    private var recorderTargetWorkPending: Bool {
        pendingTargetPick != nil || pendingLayerSelection != nil || pendingChannelSelection != nil
            || pendingPathSelection != nil || !pendingTargetCommands.isEmpty || quickMaskIntent != nil
            || !componentIntents.isEmpty || !channelVisibilityIntents.isEmpty
    }

    private func continueRecorderReplay(generation: UUID) {
        guard generation == recorderReplayGeneration, recorder.isReplaying, !isClosing else { return }
        if pendingWork != 0 {
            // Counted reads may remain available during replay. They finish
            // before the next semantic edit, without claiming another step.
            recorderReplayWaitingGeneration = generation
            return
        }
        let step: RecorderLog<SemanticImageCommand>.ReplayStep
        do { step = try recorder.nextReplayStep() }
        catch {
            assertionFailure("Recorder could not obtain its next replay step: \(error)")
            return
        }
        let context = recorderTargetContexts[step.index]
        do {
            if let reason = recorderReplayBlockReason(continuing: true) { throw RecorderReplayError(message: reason) }
            if step.command.requiresResolvedFloatingSelection,
               let reason = FloatingControlsLogic.resolveFirstGate(floatingState) {
                throw RecorderReplayError(message: reason)
            }
            if Self.recorderCommandNeedsTarget(step.command) {
                guard let context else { throw RecorderReplayError(message: "This command has no captured target context; record it again.") }
                switch context {
                case .unavailable(let reason): throw RecorderReplayError(message: reason)
                case .layer(let layer):
                    guard layers.contains(where: { $0.id == layer }) else {
                        throw RecorderReplayError(message: "The recorded layer is no longer in this image.")
                    }
                case .target:
                    guard captureRecorderContext(for: step.command).map({ Self.recorderContextsMatch($0, context) }) == true else {
                        throw RecorderReplayError(message: "The recorded layer, channel, mask or Quick Mask target has changed.")
                    }
                }
            }
        } catch {
            settleRecorderReplay(step.token, generation: generation, result: .failure(error))
            return
        }
        // This private route bypasses only the live-edit replay gate. All other
        // admission gates above and native target checks below remain in force.
        enqueue(on: inputQueue, input: true, afterFinish: { [weak self] in
            DispatchQueue.main.async { self?.continueRecorderReplay(generation: generation) }
        }) { [session, image] in
            let result = Result {
                if step.command.requiresResolvedFloatingSelection,
                   let reason = FloatingControlsLogic.resolveFirstGate(try session.floatingSelection(image)) {
                    throw RecorderReplayError(message: reason)
                }
                if let context { try Self.requireRecorderContext(context, session: session, image: image) }
                if case .layer(let layer)? = context {
                    try step.command.apply(session: session, image: image, layer: layer)
                } else {
                    try step.command.apply(session: session, image: image)
                }
            }
            DispatchQueue.main.async {
                self.settleRecorderReplay(step.token, generation: generation, result: result)
            }
        }
    }

    private func settleRecorderReplay(_ token: RecorderLog<SemanticImageCommand>.ReplayToken,
                                      generation: UUID, result: Result<Void, Error>) {
        // Cancellation/close do not interrupt already accepted native work.
        // Its result still reaches the error channel but cannot restart replay.
        if case .failure(let error) = result { onError?(String(describing: error)) }
        guard generation == recorderReplayGeneration, recorder.isReplaying, !isClosing else { return }
        let outcome: RecorderLog<SemanticImageCommand>.ReplayOutcome
        switch result {
        case .success: outcome = .success
        case .failure(let error): outcome = .failure(String(describing: error))
        }
        do { try recorder.acknowledgeReplay(token, outcome: outcome) }
        catch {
            assertionFailure("Recorder could not acknowledge its accepted replay step: \(error)")
            return
        }
        notifyRecorderChanged()
    }

    private nonisolated static func recorderCommandNeedsTarget(_ command: SemanticImageCommand) -> Bool {
        switch command {
        case .selectColor(_, let options): return !options.sampleMerged
        case .selectCommand(.fromAlpha, _): return true
        case .layerProperties: return true
        default: return false
        }
    }

    private func captureRecorderContext(for command: SemanticImageCommand, explicitLayer: Int32? = nil) -> RecorderContext? {
        guard Self.recorderCommandNeedsTarget(command) else { return nil }
        if case .layerProperties = command {
            guard let layer = explicitLayer, layer > 0 else {
                return .unavailable("The explicit layer could not be identified when this change was recorded.")
            }
            // Native ownership is confirmed behind accepted input. A layer
            // property is not bound to the current paint drawable or selection.
            return .layer(layer)
        }
        guard pendingTargetPick == nil, pendingLayerSelection == nil, pendingChannelSelection == nil,
              pendingTargetCommands.isEmpty, quickMaskIntent == nil,
              let target = paintTarget, let quickMask = quickMaskState else {
            return .unavailable("The target was not settled when this command was recorded; record it again after target changes finish.")
        }
        var masks: [Int32: EngineSession.MaskState] = [:]
        for layer in selectedLayerIDs {
            guard let row = layers.first(where: { $0.id == layer }) else {
                return .unavailable("The recorded layer target could not be identified; record this command again.")
            }
            if row.hasMask {
                guard let mask = maskStates[layer] else {
                    return .unavailable("The layer-mask target was unavailable when this command was recorded.")
                }
                masks[layer] = mask
            } else { masks[layer] = EngineSession.MaskState() }
        }
        return .target(RecorderTargetContext(layers: selectedLayerIDs, channels: selectedChannelIDs,
                                            target: target, masks: masks, quickMask: quickMask))
    }

    private nonisolated static func recorderContextsMatch(_ first: RecorderContext, _ second: RecorderContext) -> Bool {
        if case .target(let a) = first, case .target(let b) = second { return a == b }
        return false
    }

    private nonisolated static func requireRecorderContext(_ context: RecorderContext,
                                                           session: EngineSession, image: Int32) throws {
        if case .layer(let layer) = context {
            guard layer > 0, try session.layers(image).contains(where: { $0.id == layer }) else {
                throw RecorderReplayError(message: "The recorded layer no longer belongs to this native image.")
            }
            return
        }
        guard case .target(let expected) = context else {
            throw RecorderReplayError(message: "This recording has no executable target binding.")
        }
        let layers = try session.selectedLayers(image)
        let channels = try session.selectedItems(.channel, image: image)
        let quickMask = try session.quickMask(image)
        var masks: [Int32: EngineSession.MaskState] = [:]
        for layer in layers { masks[layer] = try session.layerMask(layer, image: image) }
        let target: PaintTarget?
        if let channel = channels.first {
            target = .channel(channel)
        } else if let layer = layers.first {
            if layers.count == 1, let mask = masks[layer], mask.mask != 0, mask.editing {
                target = .mask(layer: layer, drawable: mask.mask)
            } else { target = .layer(layer) }
        } else { target = nil }
        guard layers == expected.layers, channels == expected.channels, masks == expected.masks,
              quickMask == expected.quickMask, target == expected.target else {
            throw RecorderReplayError(message: "The native layer, channel, mask or Quick Mask target differs from the recording.")
        }
    }

    private func reserveRecording(_ command: SemanticImageCommand?, explicitLayer: Int32? = nil) throws -> RecorderCapture? {
        guard let command, recorder.isRecording else { return nil }
        return try reserveRecording(context: captureRecorderContext(for: command, explicitLayer: explicitLayer))
    }

    private func reserveRecording(context: RecorderContext?) throws -> RecorderCapture {
        let reservation = try recorder.reserve()
        recorderRevision = UUID()
        if let context { recorderTargetContexts[reservation.ordinal] = context }
        var targets: [RecorderRuntimeTarget] = []
        switch context {
        case .layer(let layer)?: targets = [.layer(layer)]
        case .target(let target)?:
            targets = target.layers.map { .layer($0) } + target.channels.map { .channel($0) }
            switch target.target {
            case .layer(let layer), .mask(let layer, _): targets.append(.layer(layer))
            case .channel(let channel): targets.append(.channel(channel))
            }
            if target.quickMask.enabled { targets.append(.channel(target.quickMask.channel)) }
        case .unavailable?, nil: break
        }
        var symbols: [RecorderRuntimeTarget: UUID] = [:]
        for target in targets {
            let symbol = recorderSymbols[target] ?? UUID()
            recorderSymbols[target] = symbol
            symbols[target] = symbol
        }
        return RecorderCapture(reservation: reservation, context: context, symbols: symbols)
    }

    private nonisolated static func confirmRecordingContext(_ context: RecorderContext?,
                                                            session: EngineSession, image: Int32) -> RecorderContext? {
        guard let context else { return nil }
        do { try requireRecorderContext(context, session: session, image: image); return context }
        catch {
            // Capture is observational: an unavailable binding may refuse later
            // replay, but must not change the admitted live edit's behavior.
            return .unavailable("The original native target could not be confirmed: \(error)")
        }
    }

    private nonisolated static func confirmRecordingCapture(_ capture: RecorderCapture?, session: EngineSession,
                                                            image: Int32) -> ConfirmedRecorderCapture {
        guard let capture else { return ConfirmedRecorderCapture(context: nil, binding: .none, descriptions: [:]) }
        let context = confirmRecordingContext(capture.context, session: session, image: image)
        var observations: [UUID: RecorderDescriptionObservation] = [:]
        do {
            if case .unavailable(let reason)? = context { throw RecorderReplayError(message: reason) }
            guard let context else { return ConfirmedRecorderCapture(context: nil, binding: .none, descriptions: [:]) }
            let layers: [EngineSession.Layer]
            if capture.symbols.keys.contains(where: { if case .layer = $0 { return true }; return false }) {
                layers = try session.layers(image)
            } else { layers = [] }
            let needsChannels = capture.symbols.keys.contains { if case .channel = $0 { return true }; return false }
            let channels: [EngineSession.Channel]
            let info: EngineSession.ImageInfo?
            if needsChannels {
                channels = try session.channels(image)
                info = try session.info(image)
            } else { channels = []; info = nil }
            for (target, symbol) in capture.symbols {
                let description: RecorderTargetDescription
                switch target {
                case .layer(let id): description = try describeRecordedLayer(id, in: layers)
                case .channel(let id):
                    let quickMask: Bool
                    if case .target(let expected) = context {
                        quickMask = expected.quickMask.enabled && expected.quickMask.channel == id
                    } else { quickMask = false }
                    guard let info else { throw RecorderReplayError(message: "The recorded channel dimensions were unavailable.") }
                    let row = channels.first { $0.id == id }
                    guard quickMask || row != nil else { throw RecorderReplayError(message: "The recorded channel description was unavailable.") }
                    description = RecorderTargetDescription(name: row?.name ?? "Quick Mask", kind: quickMask ? .quickMask : .channel,
                        ancestors: [], siblingIndex: quickMask ? 0 : channels.firstIndex(where: { $0.id == id })!,
                        bounds: .init(x: 0, y: 0, width: Double(info.width), height: Double(info.height)))
                }
                observations[symbol] = .available(description)
            }
            let binding = try describeRecordedBinding(context, symbols: capture.symbols)
            return ConfirmedRecorderCapture(context: context, binding: binding, descriptions: observations)
        } catch {
            let reason = "The original target description could not be captured: \(error)"
            for symbol in capture.symbols.values where observations[symbol] == nil {
                observations[symbol] = .unavailable(reason)
            }
            return ConfirmedRecorderCapture(context: context, binding: .unavailable(reason), descriptions: observations)
        }
    }

    private nonisolated static func recordedKind(_ kind: EngineSession.LayerKind) -> RecorderTargetDescription.Kind {
        switch kind {
        case .pixel: return .pixel
        case .group: return .group
        case .text: return .text
        case .link: return .link
        case .vector: return .vector
        }
    }

    private nonisolated static func describeRecordedLayer(_ id: Int32, in layers: [EngineSession.Layer]) throws -> RecorderTargetDescription {
        guard let row = layers.first(where: { $0.id == id }) else {
            throw RecorderReplayError(message: "The original layer description was unavailable.")
        }
        func index(_ row: EngineSession.Layer) -> Int {
            layers.filter { $0.parent == row.parent }.firstIndex { $0.id == row.id }!
        }
        var ancestors: [RecorderTargetDescription.Ancestor] = []
        var parent = row.parent, seen: Set<Int32> = [row.id]
        while parent != 0 {
            guard seen.insert(parent).inserted, let ancestor = layers.first(where: { $0.id == parent }) else {
                throw RecorderReplayError(message: "The original layer ancestry was unavailable.")
            }
            ancestors.append(.init(name: ancestor.name, kind: recordedKind(ancestor.kind), siblingIndex: index(ancestor)))
            parent = ancestor.parent
        }
        return RecorderTargetDescription(name: row.name, kind: recordedKind(row.kind), ancestors: Array(ancestors.reversed()),
            siblingIndex: index(row), bounds: .init(x: Double(row.bounds.origin.x), y: Double(row.bounds.origin.y),
                                                   width: Double(row.bounds.width), height: Double(row.bounds.height)))
    }

    private nonisolated static func describeRecordedBinding(_ context: RecorderContext,
                                                            symbols: [RecorderRuntimeTarget: UUID]) throws -> RecorderBindingDescription {
        func symbol(_ target: RecorderRuntimeTarget) throws -> UUID {
            guard let value = symbols[target] else { throw RecorderReplayError(message: "The captured target symbol was unavailable.") }
            return value
        }
        switch context {
        case .unavailable(let reason): return .unavailable(reason)
        case .layer(let layer): return .layer(try symbol(.layer(layer)))
        case .target(let expected):
            let target: RecorderBindingDescription.Target
            switch expected.target {
            case .layer(let layer): target = .layer(try symbol(.layer(layer)))
            case .mask(let layer, _): target = .mask(owner: try symbol(.layer(layer)))
            case .channel(let channel):
                let value = try symbol(.channel(channel))
                target = expected.quickMask.enabled && expected.quickMask.channel == channel ? .quickMask(value) : .channel(value)
            }
            let masks = try expected.layers.map { layer -> RecorderBindingDescription.Mask in
                guard let mask = expected.masks[layer] else { throw RecorderReplayError(message: "The captured mask role was unavailable.") }
                return .init(owner: try symbol(.layer(layer)), isPresent: mask.mask != 0,
                             enabled: mask.enabled, editing: mask.editing, showing: mask.showing)
            }
            let quickMaskSymbol: UUID?
            if expected.quickMask.enabled { quickMaskSymbol = try symbol(.channel(expected.quickMask.channel)) }
            else { quickMaskSymbol = nil }
            let quickMask = RecorderBindingDescription.QuickMask(enabled: expected.quickMask.enabled,
                symbol: quickMaskSymbol,
                inverted: expected.quickMask.inverted, color: try EngineSession.recorderColor(expected.quickMask.color))
            return .context(.init(layers: try expected.layers.map { try symbol(.layer($0)) },
                channels: try expected.channels.map { try symbol(.channel($0)) }, target: target, masks: masks, quickMask: quickMask))
        }
    }

    private nonisolated func settleRecording(_ capture: RecorderCapture?, result: Result<SemanticImageCommand, Error>,
                                             confirmed: ConfirmedRecorderCapture) {
        guard let capture else { return }
        let resolution: RecorderLog<SemanticImageCommand>.Resolution
        switch result {
        case .success(let command): resolution = .success(command)
        case .failure(let error): resolution = .failure(String(describing: error))
        }
        DispatchQueue.main.async {
            self.resolveRecording(capture.reservation, with: resolution, confirmed: confirmed)
        }
    }

    /// Canvas resize alone supplies its final immutable command after the
    /// worker resolves and uses the caller's copied color exactly once.
    private func runDeferredImageCommand(_ work: @escaping (EngineSession, Int32) throws -> SemanticImageCommand) {
        guard !isClosing, !refuseWhileEditingUnavailable() else { return }
        let capture: RecorderCapture?
        do {
            if recorder.isRecording { capture = try reserveRecording(context: nil) }
            else { capture = nil }
        }
        catch { assertionFailure("A recording log refused an admitted canvas resize: \(error)"); return }
        enqueue(on: inputQueue, input: true) { [session, image] in
            let confirmed = Self.confirmRecordingCapture(capture, session: session, image: image)
            let result = Result { try work(session, image) }
            if case .failure(let error) = result { self.report(error) }
            self.settleRecording(capture, result: result, confirmed: confirmed)
        }
        if capture != nil { notifyRecorderChanged() }
    }

    @discardableResult
    func run(effect: CommandEffect = .changesImage, semantic: SemanticImageCommand? = nil, recorderLayer: Int32? = nil,
             _ work: @escaping (EngineSession, Int32) throws -> Void) -> Bool {
        guard !isClosing else { return false }
        if effect != .readsPixels && refuseWhileEditingUnavailable(forPreviewWork: effect == .changesPreview) {
            return false
        }
        let capture: RecorderCapture?
        do { capture = try reserveRecording(semantic, explicitLayer: recorderLayer) }
        catch {
            assertionFailure("A recording log refused an admitted command: \(error)")
            return false
        }
        enqueue(on: inputQueue, input: effect == .changesImage) { [session, image] in
            let confirmed = Self.confirmRecordingCapture(capture, session: session, image: image)
            let result = Result { try work(session, image) }
            if case .failure(let error) = result { self.report(error) }
            if let semantic { self.settleRecording(capture, result: result.map { semantic }, confirmed: confirmed) }
        }
        // Notify only after queue admission/counting: a listener may close the
        // document or start a fresh epoch, and accepted work must still drain.
        if capture != nil { notifyRecorderChanged() }
        return true
    }

    private func resolveRecording(_ reservation: RecorderLog<SemanticImageCommand>.Reservation,
                                  with resolution: RecorderLog<SemanticImageCommand>.Resolution,
                                  confirmed: ConfirmedRecorderCapture) {
        do {
            try recorder.resolve(reservation, with: resolution)
            // Resolve verifies the epoch first; stale callbacks must never
            // replace a newer recording's binding at the same ordinal.
            if let context = confirmed.context { recorderTargetContexts[reservation.ordinal] = context }
            recorderDescriptions.acceptFirst(confirmed.descriptions)
            recorderBindingDescriptions[reservation.ordinal] = confirmed.binding
            recorderRevision = UUID()
            notifyRecorderChanged()
        } catch RecorderLog<SemanticImageCommand>.Refusal.staleReservation {
            // Clear/start deliberately invalidate older callbacks.
        } catch {
            assertionFailure("An accepted Recorder reservation could not settle: \(error)")
        }
    }

    /// Queues engine work; the document counts it until it ran so a close
    /// can wait. `input` jobs go through the input queue — all edits —
    /// and count as unsaved changes while they wait or run. `teardown`
    /// jobs (filter aborts) are cleanup: they queue and count even while
    /// closing, so the drain never destroys an image out from under them.
    private func enqueue(on queue: DispatchQueue, input: Bool = false, teardown: Bool = false,
                         afterFinish: (@MainActor () -> Void)? = nil,
                         _ work: @escaping () -> Void) {
        guard teardown || !isClosing else { return }
        pendingWork += 1
        if input { pendingInput += 1 }
        EngineActivity.shared.whenIdle {
            queue.async {
                work()
                DispatchQueue.main.async {
                    self.jobDidFinish(input: input)
                    afterFinish?()
                }
            }
        }
    }

    /// Count the whole exclusive operation, including its input drain,
    /// so a close cannot destroy the image while a file call is waiting.
    private func enqueueExclusive(effect: CommandEffect = .changesImage, label: String,
                                  admission: (() -> Bool)? = nil,
                                  rejected: @escaping @MainActor () -> Void,
                                  _ work: @escaping () -> Void) {
        guard !isClosing, !recorder.isReplaying || effect == .readsPixels else { return rejected() }
        onUserCommand?()
        // The observer can start replay or close; reject with the original
        // completion rather than silently dropping an admitted write.
        guard !isClosing, !recorder.isReplaying || effect == .readsPixels else { return rejected() }
        // Source vectors also revalidate after this observer: a field action
        // may have changed cached targets or started another operation.
        guard admission?() != false else { return rejected() }
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
        if pendingWork == 0, let generation = recorderReplayWaitingGeneration {
            recorderReplayWaitingGeneration = nil
            DispatchQueue.main.async { self.continueRecorderReplay(generation: generation) }
        }
        // State callbacks above may have accepted thumbnail reads. Refresh
        // only after their actual final drain, without changing command
        // notifications or turning pointer samples into presentation events.
        if pendingWork == 0 && !strokeIsActive { notifyRecorderPresentationChanged() }
    }

    private nonisolated func report(_ error: Error) {
        let message = String(describing: error)
        DispatchQueue.main.async { self.onError?(message) }
    }
}
