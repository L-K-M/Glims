import AppKit
import RigiUI
import UniformTypeIdentifiers

/// A document window: the engine canvas in a scroll view above Rigi's status
/// strip. It handles the imageDocument's menu commands through the responder
/// chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let imageDocument: ImageDocument
    let canvas: EngineCanvasView
    let rotationView: CanvasRotationView
    var screenModeState = DocumentScreenModeState()
    var screenModeSnapshot: DocumentScreenModeSnapshot?
    private var viewAngleAlert: NSAlert?
    private var paintSourceAlert: NSAlert?
    private var textSourceAlert: NSAlert?
    private var batchRasterizeAlert: NSAlert?
    private var batchRestoreAlert: NSAlert?
    private(set) var softProofController: SoftProofController?
    private var savedSoftProof: CanvasSoftProof?
    private let preferences: EditorPreferences
    let statusBar = StatusBarView(frame: .zero)
    let statusInformation = StatusInformationPopUpButton()
    /// The scroll view hosting the canvas and its native ruler slots;
    /// readable for the smoke test's native-slot checks.
    let scrollView = CanvasScrollView()
    private lazy var engineUndoManager = EngineUndoManager(document: imageDocument)
    private let recorderPickerDefaults: RecorderFileCoordinator.PickerDefaults?
    private let exportDirectory: URL?
    private lazy var recorderFiles = RecorderFileCoordinator(owner: self, pickerDefaults: recorderPickerDefaults)

    var canPresentRecorderFileSheet: Bool { recorderFiles.canPresent }

    func presentRecorderFileAction(_ action: RecorderPaletteAction) throws {
        if action.needsFileSheet {
            try recorderFiles.perform(action)
        } else if (action == .record || action == .clear) && imageDocument.hasUnsavedRecordingChanges {
            guard recorderFiles.canPresent else { throw RecorderFileCoordinator.Refusal.windowUnavailable }
            recorderFiles.confirmLoss(.replace) { [weak self] approved in
                guard let self, let approved else { return }
                do {
                    guard try self.imageDocument.recorderInstallCheckpoint() == approved else {
                        throw RecorderFileCoordinator.Refusal.changed
                    }
                    try action.perform(on: self.imageDocument)
                } catch { self.imageDocument.onError?(error.localizedDescription) }
            }
        } else {
            try action.perform(on: imageDocument)
        }
    }
    /// The open filter preview, generic or dedicated; one at a time.
    private(set) var previewPanel: FilterPreviewPanel?
    /// Image ▸ Guides…'s sheet, retained by this window for its lifetime;
    /// nil while none is open. Two documents keep independent sheets
    /// through their own controllers — no global binding or singleton.
    private(set) var guidesSheet: GuidesSheetController?
    /// Edit ▸ Stroke Selection…'s sheet, retained by this window for its
    /// lifetime the same way; nil while none is open.
    private(set) var strokeSelectionSheet: StrokeSelectionSheetController?
    /// Edit ▸ Create Resource ▸ …'s sheet, retained by this window for its
    /// lifetime and capturing this window's document and creation kind at
    /// open, so two documents keep independent sheets — no global binding,
    /// no retarget to the front window. nil while none is open.
    private(set) var resourceSelectionSheet: ResourceSelectionSheetController?
    /// Edit ▸ Create Resource ▸ Gradient…'s sheet, retained by this window
    /// for its lifetime and capturing this window's document at open, so
    /// two documents keep independent sheets — no global binding, no
    /// retarget to the front window. nil while none is open.
    private(set) var gradientCreateSheet: GradientCreateSheetController?
    /// View ▸ Saved Sets…'s non-modal panel, retained by this window and
    /// capturing this window's document at open — no retarget to the front
    /// window. nil while none is open.
    private(set) var savedSetPanel: SavedSetPanelController?

    /// Image ▸ Mode ▸ Indexed…'s sheet, retained by this window for its
    /// lifetime and capturing this window's document at open, so Apply and
    /// the rasterization consent act on that document, never on the front
    /// one. nil while none is open.
    private(set) var indexedSheet: IndexedSheetController?

    /// View ▸ Show Guides' cached per-window state, defaulting to on.
    private(set) var guidesViewState = GuideViewState()
    /// Image ▸ Configure Grid…'s sheet, retained by this window for its
    /// lifetime; nil while none is open. Two documents keep independent
    /// sheets through their own controllers — no global binding.
    private(set) var gridSheet: GridSheetController?
    /// Image ▸ Metadata…'s sheet, retained by this window for its
    /// lifetime and capturing this window's document at open, so every
    /// read and write acts on that document, never on the front one.
    /// nil while none is open.
    private(set) var metadataSheet: MetadataSheetController?
    /// Layer ▸ New Adjustment Layer…'s creation sheet, retained by this
    /// window for its lifetime and capturing this window's document at
    /// open, so Create and the phase-2 editor act on that document, never
    /// on the front one. nil while none is open.
    private(set) var adjustmentSheet: AdjustmentLayerSheetController?
    /// View ▸ Show Grid's cached per-window state, defaulting to off.
    private(set) var gridViewState = GridViewState()

    /// View ▸ Show Rulers' cached per-window state, defaulting to on. Kept
    /// separate from the guides state — the two toggles never couple.
    private(set) var rulerViewState = RulerViewState()
    /// View ▸ Show Selection Edges' cached per-window state, defaulting to
    /// on. Hiding only stops the marching-ants drawing and its timer; the
    /// native selection and its cached state are untouched.
    private(set) var selectionEdgesViewState = SelectionEdgesViewState()
    /// View ▸ Show Layer Boundary's cached per-window state, defaulting to
    /// off. The outline is the current cached paint-target bounds, resolved
    /// per draw; toggling never touches engine state.
    private(set) var layerBoundaryViewState = LayerBoundaryViewState()
    /// The pixel rulers in the scroll view's native ruler slots. They read
    /// the canvas geometry through a weak reference at draw time, so no
    /// global ruler controller exists.
    let horizontalRuler = PixelRulerView(scrollView: nil, orientation: .horizontalRuler)
    let verticalRuler = PixelRulerView(scrollView: nil, orientation: .verticalRuler)
    /// Whether the ruler geometry observers are currently registered.
    /// They are removed when the window closes (and in deinit), so a
    /// closing window leaves no observation behind.
    private(set) var rulerObserversActive = false

    /// Bumped by every filter start and every cancellation, so a begin
    /// that lands late can tell it is stale and abort its session.
    private var previewRequest = 0
    /// A begin job is queued behind pending input; while it waits, edits
    /// and file writes gate exactly as if the panel were already open.
    private var previewStartIsPending = false
    private var filterSourceChooser: FilterSourceChooserController?
    private var filterSourceRequest = 0
    /// An open panel or a start still queued on the input queue.
    private var previewBusy: Bool { previewPanel != nil || previewStartIsPending }
    /// A print job anywhere between Print… and the end of the run: a
    /// second Print is refused, and a close asked for during the engine
    /// render drops the snapshot instead of attaching a sheet.
    private(set) var printJobIsOpen = false
    /// A close asked for while the snapshot still renders; the job ends
    /// without attaching the print sheet and the close goes on.
    private var printJobDropped = false
    private var activePrintOperation: NSPrintOperation?
    private var pageLayout: NSPageLayout?
    /// Substitute for the print-panel sheet (tests); whoever runs the
    /// job must report back through `printJobDidFinish(printed:)`.
    var printJobRunner: ((ImagePrintView, NSPrintInfo, NSWindow,
                         @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Substitute for the NSPageLayout sheet (tests).
    var pageSetupRunner: ((NSPrintInfo, NSWindow,
                          @escaping @MainActor (NSPrintInfo?) -> Void) -> Void)?
    var onClose: ((DocumentWindowController) -> Void)?
    let fileAccessID = UUID()
    var reserveWrite: ((URL) throws -> (() -> Void))?
    /// Whoever owns the open documents binds this: a confirmed Revert
    /// asks it to reload `URL` from disk and replace this window's
    /// document with the result. `nil` where nothing can adopt a
    /// document — the menu item stays disabled then.
    var revertHandler: ((URL, @escaping @MainActor (Result<DocumentWindowController, Error>) -> Void) -> Void)?

    init(document imageDocument: ImageDocument, preferences: EditorPreferences? = nil,
         recorderPickerDefaults: RecorderFileCoordinator.PickerDefaults? = nil,
         exportDirectory: URL? = nil) {
        self.recorderPickerDefaults = recorderPickerDefaults
        self.exportDirectory = exportDirectory
        self.imageDocument = imageDocument
        self.preferences = preferences ?? .shared
        let canvas = EngineCanvasView(document: imageDocument)
        self.canvas = canvas
        self.rotationView = CanvasRotationView(canvas: canvas)

        let window = ClassicWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        window.delegate = self
        window.representedURL = imageDocument.fileState.nativeURL

        layOutContent(in: window)
        observeRulerGeometry()
        NotificationCenter.default.addObserver(self, selector: #selector(applyPreferences),
                                               name: EditorPreferences.didChange, object: self.preferences)
        applyPreferences()
        imageDocument.onProjectionChange = { [weak self] rect in self?.canvas.imageDidChange(in: rect) }
        imageDocument.onStateChange = { [weak self] in self?.stateDidChange() }
        imageDocument.onError = { [weak self] message in
            self?.showStatusError(message)
            self?.previewPanel?.showError(message)
            // Fan out to the guides and grid sheets as well, alongside the
            // existing handlers — the sheets never install their own callback.
            self?.guidesSheet?.showError(message)
            self?.strokeSelectionSheet?.showError(message)
            self?.resourceSelectionSheet?.showError(message)
            self?.gradientCreateSheet?.showError(message)
            self?.savedSetPanel?.showError(message)

            self?.gridSheet?.showError(message)

            self?.indexedSheet?.showError(message)

            self?.metadataSheet?.showError(message)
            self?.adjustmentSheet?.showError(message)

        }
        // Palette picks and structural or lock changes first commit any
        // field/text edit and end an active stroke; each command also
        // lets a remembered refusal go.
        imageDocument.onWillChangeLayers = { [weak self] in self?.endPendingEdits() }
        imageDocument.onUserCommand = { [weak self] in self?.statusIsError = false }
        imageDocument.onPaintNeedsRasterize = { [weak self] layer, version in
            self?.presentPaintSourceConfirmation(layer: layer, stateVersion: version)
        }
        imageDocument.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.canvas.selectionOutline = self.imageDocument.selectionOutline
        }
        imageDocument.onSizeChange = { [weak self] in
            self?.canvas.imageSizeDidChange()
            self?.stateDidChange()
        }
        canvas.tools.onStatus = { [weak self] message in
            self?.statusIsError = false
            self?.statusBar.message = message
        }
        canvas.tools.onTextNeedsRestore = { [weak self] layer, version in
            self?.presentTextSourceConfirmation(layer: layer, stateVersion: version)
        }
        canvas.tools.onHintChange = { [weak self] reason in self?.refreshIdleStatus(reason) }
        canvas.tools.onZoom = { [weak self] zoomIn, point in
            guard let self else { return }
            self.zoom(to: zoomIn ? ZoomLadder.zoomIn(from: self.canvas.zoomPercent)
                                 : ZoomLadder.zoomOut(from: self.canvas.zoomPercent))
            self.center(on: point)
        }
        // Trackpad pinch/rotate view navigation, anchored at the pointer.
        // The closures capture THIS controller weakly, so the callbacks act
        // on the owning window's document even when another document is
        // frontmost.
        canvas.onTrackpadZoom = { [weak self] percent, anchor in
            self?.applyTrackpadNavigation(zoomPercent: percent, rotationDegrees: nil, anchorWindowPoint: anchor)
        }
        canvas.trackpadRotationDegrees = { [weak self] in self?.rotationView.rotationDegrees ?? 0 }
        canvas.onTrackpadRotate = { [weak self] degrees, anchor in
            self?.applyTrackpadNavigation(zoomPercent: nil, rotationDegrees: degrees, anchorWindowPoint: anchor)
        }
        // Option-scroll zoom: the scroll view intercepts the wheel and forwards
        // admitted events to the canvas; the owning controller stays weak.
        scrollView.onOptionScroll = { [weak self] event in
            self?.canvas.handleOptionScroll(event) ?? false
        }
        statusBar.onZoomIn = { [weak self] in self?.zoom(to: ZoomLadder.zoomIn(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomOut = { [weak self] in self?.zoom(to: ZoomLadder.zoomOut(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomReset = { [weak self] in self?.zoom(to: ZoomLadder.actualPixels) }
        statusBar.isZoomEditable = true
        statusBar.onZoomTo = { [weak self] percent in self?.zoom(to: ZoomLadder.clamped(percent)) }
        statusBar.setZoom(percent: canvas.zoomPercent)
        statusBar.setAccessoryViews([statusInformation])
        canvas.onRenderMetricsChange = { [weak self] _ in self?.refreshStatusInformation() }
        stateDidChange()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func applyPreferences() {
        let color = preferences.surround.color
        canvas.surroundColor = color
        rotationView.surroundColor = color
        scrollView.backgroundColor = color
    }

    /// How far each new document window steps from the previous one.
    static let cascadeStep = DocumentWindowPlacement.cascadeStep

    /// Where a new document window's top-left goes, given the previous
    /// window's frame: one step down and right, or back near the top-left
    /// of the visible screen area when that step would leave it.
    static func cascadedTopLeft(after previous: CGRect, size: CGSize, in visible: CGRect) -> CGPoint {
        let frame = DocumentWindowPlacement.frame(size: size, after: previous, in: visible)
        return CGPoint(x: frame.minX, y: frame.maxY)
    }

    private func layOutContent(in window: NSWindow) {
        scrollView.contentView = CanvasClipView()
        // This scroll view is below the title bar. Ruler reservation
        // must not also include automatic title-bar overlap insets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.documentView = rotationView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        // The pixel rulers live in the scroll view's native ruler slots; the
        // scroll view itself relayouts and redraws them on content-bounds
        // changes (scroll, ruler toggles), so AppKit keeps the scroll
        // layout and the accessibility semantics.
        horizontalRuler.canvas = canvas
        verticalRuler.canvas = canvas
        horizontalRuler.clientView = canvas
        verticalRuler.clientView = canvas
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.horizontalRulerView = horizontalRuler
        scrollView.verticalRulerView = verticalRuler
        scrollView.rulersVisible = rulerViewState.showsRulers

        let content = DocumentContentView()
        for view in [scrollView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: ClassicMetrics.statusBarHeight),
        ])

        window.contentView = content
    }

    @objc private func viewportChanged() {
        canvas.setNeedsRender()
        // Scrolling moves the rulers with the content; the scroll view also
        // relayouts its native ruler slots here.
        invalidateRulers()
    }

    /// Watches the geometry the rulers depend on besides the scroll offset:
    /// the canvas frame (zoom and image extent changes resize it) and the
    /// window's backing scale. Registered like the window's other
    /// notifications and removed when the window closes, so a closed window
    /// observes nothing.
    private func observeRulerGeometry() {
        NotificationCenter.default.addObserver(self, selector: #selector(canvasFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: canvas)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBackingChanged(_:)),
                                               name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        rulerObserversActive = true
    }

    @objc private func canvasFrameChanged() { invalidateRulers() }

    @objc private func windowBackingChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === self.window else { return }
        invalidateRulers()
    }

    private func removeRulerObservers() {
        guard rulerObserversActive else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: canvas)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        rulerObserversActive = false
    }

    /// Redraws both rulers from the live canvas geometry. Display-only.
    private func invalidateRulers() {
        horizontalRuler.invalidateHashMarks()
        verticalRuler.invalidateHashMarks()
        horizontalRuler.needsDisplay = true
        verticalRuler.needsDisplay = true
    }

    /// The image-space point at the viewport's center; a revert
    /// restores it on the replacement document.
    var canvasCenter: CGPoint {
        let visible = scrollView.contentView.bounds
        let point = canvas.convert(CGPoint(x: visible.midX, y: visible.midY), from: scrollView.contentView)
        return CGPoint(x: point.x / canvas.scale, y: point.y / canvas.scale)
    }

    /// Scrolls so `point` (image pixels) is in the middle of the view.
    func center(on point: CGPoint) {
        let clip = scrollView.contentView
        let point = rotationView.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), from: canvas)
        let target = CGRect(x: point.x - clip.bounds.width / 2, y: point.y - clip.bounds.height / 2,
                            width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func zoom(to percent: Int) {
        let imageCenter = canvasCenter
        canvas.setZoom(percent: percent)
        rotationView.layoutCanvas()
        center(on: imageCenter)
        statusBar.setZoom(percent: percent)
        stateDidChange()
    }

    @discardableResult
    func setViewRotation(degrees: Double) -> Bool {
        guard degrees.isFinite, !closeStarted, !imageDocument.isClosing else { return false }
        let centerBefore = canvasCenter
        canvas.guideDrag.cancel()
        canvas.tools.cancelMoveSnap()
        canvas.tools.cancelFloatingMove()
        guard rotationView.setRotationDegrees(degrees) else { return false }
        scrollView.rulersVisible = rulerViewState.showsRulers
        window?.contentView?.layoutSubtreeIfNeeded()
        center(on: centerBefore)
        canvas.needsDisplay = true
        canvas.setNeedsRender()
        invalidateRulers()
        stateDidChange()
        return true
    }

    /// One trackpad navigation step (pinch zoom and/or view rotation),
    /// anchored at the pointer: the image pixel under the gesture stays
    /// under it. View-only — no engine call and no image, history, dirty or
    /// settings change, and no engine-busy gate; only the close guard and
    /// the canvas's own interaction guards apply, so a late event after
    /// close is ignored.
    ///
    /// The pointer's viewport offset (event window point converted to the
    /// clip, minus the clip's bounds origin) and the image point under the
    /// pointer are captured BEFORE any geometry change. The zoom/rotation
    /// is then applied through the existing `zoom(to:)`/`setViewRotation`
    /// methods; the captured image point times the NEW canvas scale is
    /// converted to the rotation host and the clip scrolls to
    /// (host point - saved viewport offset), clamped by
    /// `constrainBoundsRect` (which centre-pins when the clamp bites).
    func applyTrackpadNavigation(zoomPercent: Int?, rotationDegrees: Double?, anchorWindowPoint: CGPoint) {
        guard !closeStarted, !imageDocument.isClosing else { return }
        let clip = scrollView.contentView
        let inClip = clip.convert(anchorWindowPoint, from: nil)
        let viewportOffset = CGPoint(x: inClip.x - clip.bounds.origin.x, y: inClip.y - clip.bounds.origin.y)
        let imagePoint = canvas.imagePoint(at: canvas.convert(anchorWindowPoint, from: nil))
        guard imagePoint.x.isFinite, imagePoint.y.isFinite else { return }
        if let zoomPercent { zoom(to: ZoomLadder.clamped(zoomPercent)) }
        if let rotationDegrees { _ = setViewRotation(degrees: rotationDegrees) }
        let hostPoint = rotationView.convert(CGPoint(x: imagePoint.x * canvas.scale, y: imagePoint.y * canvas.scale),
                                              from: canvas)
        let target = CGRect(x: hostPoint.x - viewportOffset.x, y: hostPoint.y - viewportOffset.y,
                            width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The title shows cached working-image color state, independently of
    /// the window's display destination and soft-proof settings.
    static func title(name: String, zoomPercent: Int, isDirty: Bool,
                      mode: EngineSession.ColorMode, precision: String,
                      profileLabel: String? = nil, viewRotation: Double = 0) -> String {
        let profile = profileLabel.map { " · \($0.isEmpty ? "Profile unavailable" : $0)" } ?? ""
        let rotation = viewRotation == 0 ? "" : " · View \(viewRotation.formatted(.number.precision(.fractionLength(0...2))))°"
        return "\(isDirty ? "• " : "")\(name) @ \(zoomPercent)% (\(mode.title), \(precision)\(profile))\(rotation)"
    }

    /// While true the status bar shows a refusal the user should read;
    /// generic state reloads leave it alone until the next command.
    private var statusIsError = false
    private var statusProgressActive = false
    private var lastIdleStatus: String?

    private func refreshIdleStatus(_ reason: ToolHintPolicy.Refresh) {
        let undo = imageDocument.undoInfo.nextUndo.isEmpty ? "" : " · Undo \(imageDocument.undoInfo.nextUndo)"
        let multichannel = imageDocument.colorInfo.mode.usesInkChannels
        let count = multichannel ? imageDocument.channels.count : imageDocument.info.layerCount
        let item = multichannel ? "ink channel" : "layer"
        let summary = "\(imageDocument.info.width) × \(imageDocument.info.height) px · \(count) \(item)\(count == 1 ? "" : "s")\(undo)"
        let current = statusBar.message
        let message = ToolHintPolicy.status(current: current, isError: statusIsError,
            progressActive: statusProgressActive, activity: EngineActivity.shared.label,
            actionIsVisible: current != lastIdleStatus, refresh: reason,
            hint: canvas.tools.hint, summary: summary)
        if message != current { statusBar.message = message }
        if !statusIsError, !statusProgressActive, EngineActivity.shared.label == nil,
           !(reason == .afterAction && current != lastIdleStatus) {
            lastIdleStatus = message
        }
    }

    private func showStatusError(_ message: String) {
        statusIsError = true
        statusBar.message = message
    }

    /// Commits in-flight field and canvas-text edits and ends an active
    /// stroke; runs before a user layer selection or a structural/lock
    /// change so those never race a half-committed edit. Only edits that
    /// belong to this document end: its own window and dialogs plus the
    /// palettes aimed at it — a routine layer command must not commit
    /// another document's field or palette edits.
    private func endPendingEdits() {
        window?.endEditing(for: nil)
        previewPanel?.window?.endEditing(for: nil)
        guidesSheet?.commitFieldEdit()
        strokeSelectionSheet?.commitFieldEdit()
        resourceSelectionSheet?.commitFieldEdit()
        gradientCreateSheet?.commitFieldEdit()
        savedSetPanel?.commitFieldEdit()

        gridSheet?.commitFieldEdit()

        indexedSheet?.commitFieldEdit()

        metadataSheet?.commitFieldEdit()
        adjustmentSheet?.commitFieldEdit()

        for paletteWindow in PaletteEditScope.windowsEditing(imageDocument) {
            paletteWindow.endEditing(for: nil)
        }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
    }

    /// Whether a background recovery copy may start now. The engine-wide
    /// input drain that precedes a file call commits every open
    /// document's in-flight text and field edits — the same ones
    /// `endPendingEdits` commits — so a recovery pass must not admit
    /// this document while any of them is open. It checks the same
    /// scope instead of committing, and the scheduler checks every
    /// tracked window before it admits any.
    var isReadyForRecoveryCopy: Bool {
        guard !canvas.tools.hasPendingInteraction else { return false }
        let scoped = [window, previewPanel?.window].compactMap { $0 }
            + PaletteEditScope.windowsEditing(imageDocument)
        return scoped.allSatisfy { !PaletteEditScope.isFieldEditing($0) }
    }

    private func refreshStatusInformation() {
        let info = imageDocument.info
        let color = imageDocument.colorInfo
        statusInformation.update(StatusInformationSnapshot(width: info.width, height: info.height,
            profileLabel: color.profileLabel,
            precisionLabel: ColorForms.precisionLabel(color),
            renderMetrics: canvas.renderMetrics))
        refreshStatusInformationVisibility()
    }

    /// Progress and its Cancel control take priority over this optional
    /// readout when the document is narrow. Keep the selected choice for
    /// when the operation finishes or the window grows again.
    private func refreshStatusInformationVisibility() {
        let width = window?.contentLayoutRect.width ?? statusBar.bounds.width
        let hidden = statusBar.isShowingProgress && width < 560
        if statusInformation.isHidden != hidden { statusInformation.isHidden = hidden }
    }

    func windowDidResize(_ notification: Notification) {
        refreshStatusInformationVisibility()
    }

    private func stateDidChange() {
        window?.title = Self.title(name: imageDocument.name, zoomPercent: canvas.zoomPercent,
                                   isDirty: imageDocument.hasUnsavedChanges,
                                   mode: imageDocument.colorInfo.mode,
                                   precision: ColorForms.precisionLabel(imageDocument.colorInfo),
                                   profileLabel: imageDocument.colorInfo.profileLabel,
                                   viewRotation: rotationView.rotationDegrees)
        refreshStatusInformation()
        refreshIdleStatus(.stateChange)
        (PaletteCenter.shared.registeredPalette(for: LayersPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: ChannelsPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: PathsPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: HistoryPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: RecorderPaletteController.definition.kind))?.retarget()
        // Path shapes arrive with the state; the canvas draws them, and
        // the cached guide list arrives with it too (reloadGuides fires
        // this same callback), so the canvas redraws the guide overlay.
        canvas.needsDisplay = true
        // Image-size changes arrive with the state too; the rulers track
        // the new extent on the next draw.
        invalidateRulers()
        // Fan out to the guides sheet through this existing hook.

        guidesSheet?.documentStateDidChange()
        strokeSelectionSheet?.documentStateDidChange()
        resourceSelectionSheet?.documentStateDidChange()
        gradientCreateSheet?.documentStateDidChange()
        savedSetPanel?.documentStateDidChange()

        gridSheet?.documentStateDidChange()

        indexedSheet?.documentStateDidChange()
        ResourceDuplicateFormController.documentStateChanged(imageDocument)
        ResourceMutationFormController.documentStateChanged(imageDocument)
        filterSourceChooser?.refresh()

        metadataSheet?.documentStateDidChange()
        adjustmentSheet?.documentStateDidChange()

        // The transform options' numeric rows track the selected layer's
        // preview through this same state hook, so a target, bounds or
        // selection change refreshes unfocused fields and readiness.
        canvas.tools.transformDocumentStateDidChange()
    }

    // MARK: Menu commands

    @objc override func deleteBackward(_ sender: Any?) { clearPixels(sender) }
    @objc override func cancelOperation(_ sender: Any?) {
        if let previewPanel { previewPanel.cancel() }
        else if previewStartIsPending { cancelPendingPreview() }
        else if screenMode != .windowed { setScreenMode(.windowed) }
        // NSWindowController's superclass does not implement this optional
        // key-binding action. An idle Escape reaching us has nothing to cancel.
    }

    /// Cancels a filter start still waiting behind pending input; its
    /// begin completion lands stale and unwinds whatever it created.
    private func cancelPendingPreview() {
        guard previewStartIsPending else { return }
        previewRequest += 1
        previewStartIsPending = false
        imageDocument.filterPreviewIsOpen = false
        stateDidChange()
    }

    /// The shared start every filter preview takes: pending edits commit
    /// first, the begin job queues behind them on the input queue, and
    /// only its main-actor completion may build a panel. The document's
    /// `filterPreviewIsOpen` marks the wait so edits, file writes and
    /// other filters refuse before a session exists; Escape, close or a
    /// stale request unwinds the begun session instead of showing it.
    private func startPreview(title: String,
                              begin: (@escaping @MainActor (Result<ImageDocument.FilterPreviewStart, Error>) -> Void) -> Void,
                              started: (@MainActor (Result<Void, Error>) -> Void)? = nil,
                              buildPanel: @escaping @MainActor (ImageDocument.FilterPreviewStart) -> FilterPreviewPanel?) {
        // A catalog reply may arrive after windowWillClose cancels
        // previews, while rendering drains after document admission stops.
        guard !closeStarted, !imageDocument.isClosing else {
            started?(.failure(ImageDocument.DocumentError.closed)); return
        }
        previewRequest += 1
        let request = previewRequest
        previewStartIsPending = true
        imageDocument.filterPreviewIsOpen = true
        statusBar.message = "\(title)…"
        begin {
            [weak self, imageDocument] result in
            guard let self, self.previewStartIsPending, self.previewRequest == request else {
                // Stale: cancelled, closed or superseded after the begin
                // was queued. A begun session is teardown-aborted — that
                // job counts toward the close drain too.
                if case .success(let start) = result {
                    imageDocument.finishFilter(start.filter, commit: false) { _ in }
                }
                started?(.failure(ImageDocument.DocumentError.closed))
                return
            }
            self.previewStartIsPending = false
            switch result {
            case .failure(let error):
                self.imageDocument.filterPreviewIsOpen = false
                self.statusBar.message = "\(title) could not start on this layer."
                started?(.failure(error))
                NSSound.beep()
            case .success(let start):
                guard let panel = buildPanel(start) else {
                    self.imageDocument.finishFilter(start.filter, commit: false) { _ in }
                    self.imageDocument.filterPreviewIsOpen = false
                    self.statusBar.message = "\(title) could not start on this layer."
                    started?(.failure(ImageDocument.DocumentError.busy))
                    NSSound.beep()
                    return
                }
                panel.onFinish = { [weak self] in
                    self?.previewPanel = nil
                    self?.imageDocument.filterPreviewIsOpen = false
                }
                self.previewPanel = panel
                panel.showWindow(nil)
                started?(.success(()))
            }
        }
    }

    private func startFilterPreview(title: String, operation: String,
                                    properties: [EngineSession.FilterProperty] = [],
                                    buildPanel: @escaping @MainActor (Int32, [String: EngineSession.FilterValue]) -> FilterPreviewPanel?) {
        startPreview(title: title, begin: { [imageDocument] completion in
            imageDocument.beginFilterPreview(operation: operation, properties: properties,
                                             completion: completion)
        }, buildPanel: { buildPanel($0.filter, $0.values) })
    }

    /// A begin on a committed effect's own edit session; the shared
    /// start is identical from there.
    private func startEffectPreview(title: String, effect: Int32, drawable: Int32,
                                    properties: [EngineSession.FilterProperty],
                                    operation: String? = nil,
                                    buildPanel: @escaping @MainActor (Int32, [String: EngineSession.FilterValue]) -> FilterPreviewPanel?) {
        startPreview(title: title, begin: { [imageDocument] completion in
            imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: properties,
                                             operation: operation,
                                             completion: completion)
        }, buildPanel: { buildPanel($0.filter, $0.values) })
    }

    /// The Layers palette's Edit Parameters on a committed effect: the
    /// generic form drives a live edit session on the effect's own
    /// stack position — the same nonmodal preview lifecycle a new
    /// filter takes. `effect` and `drawable` name the row explicitly;
    /// the begin job re-validates them behind pending input.
    func editEffectParameters(_ effect: Int32, on drawable: Int32, operationName: String) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        guard let operation = NativeFilterCatalog.shared.operation(named: operationName),
              NativeFilterMenuLayout.supportsParameterEditor(operation) else {
            statusBar.message = "This filter's parameters cannot be edited here yet."
            return
        }
        endPendingEdits()
        statusBar.message = "\(operation.title)…"
        if NativeFilterMenuLayout.usesCurvesEditor(operation) {
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: [],
                                                 operation: operation.name, completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.curves else { return nil }
                return CurvesPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesLevelsEditor(operation) {
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: [],
                                                 operation: operation.name, completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.levels else { return nil }
                return LevelsPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesHueSaturationEditor(operation) {
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: [],
                                                 operation: operation.name, completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.hueSaturation else { return nil }
                return HueSaturationPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesColorBalanceEditor(operation) {
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: [],
                                                 operation: operation.name, completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.colorBalance else { return nil }
                return ColorBalancePanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesBrightnessContrastEditor(operation) {
            startEffectPreview(title: operation.title, effect: effect, drawable: drawable,
                               properties: [], operation: operation.name) { [imageDocument] filter, values in
                BrightnessContrastPanel(document: imageDocument, filter: filter, initialValues: values)
            }
            return
        }
        NativeFilterCatalog.shared.properties(for: operation, using: imageDocument.session) { [weak self] properties in
            guard let self, !self.imageDocument.isClosing else { return }
            guard let properties else {
                self.statusBar.message = "\(operation.title) is not available."
                NSSound.beep()
                return
            }
            // The gates can have changed while the catalog answered.
            guard !self.previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
                  !self.imageDocument.isSavingForClose, !self.imageDocument.isTransferringClipboard else {
                self.statusBar.message = "Apply or cancel the current filter first."
                return
            }
            self.startEffectPreview(title: operation.title, effect: effect, drawable: drawable,
                                    properties: properties) { [imageDocument] filter, values in
                NativeFilterPanel.parameterPanel(document: imageDocument, operation: operation,
                                                 properties: properties, filter: filter, initialValues: values)
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { zoom(to: ZoomLadder.zoomIn(from: canvas.zoomPercent)) }
    @objc func zoomOut(_ sender: Any?) { zoom(to: ZoomLadder.zoomOut(from: canvas.zoomPercent)) }
    @objc func actualPixels(_ sender: Any?) { zoom(to: ZoomLadder.actualPixels) }
    @objc func rotateViewClockwise(_ sender: Any?) {
        endPendingEdits()
        setViewRotation(degrees: rotationView.rotationDegrees + 15)
    }
    @objc func rotateViewCounterclockwise(_ sender: Any?) {
        endPendingEdits()
        setViewRotation(degrees: rotationView.rotationDegrees - 15)
    }
    @objc func resetViewRotation(_ sender: Any?) {
        endPendingEdits()
        setViewRotation(degrees: 0)
    }
    @objc func setViewAngle(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil else { return }
        endPendingEdits()
        let alert = NSAlert()
        alert.messageText = "Rotate View"
        alert.informativeText = "Angle in degrees, clockwise. This changes the view without rotating image pixels."
        let field = NSTextField(string: String(rotationView.rotationDegrees))
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        field.setAccessibilityLabel("View angle in degrees")
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        viewAngleAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.viewAngleAlert = nil
            guard response == .alertFirstButtonReturn, !self.closeStarted, !self.imageDocument.isClosing else { return }
            guard let angle = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), angle.isFinite else {
                self.showStatusError("Enter a finite angle in degrees, such as 22.5.")
                return
            }
            self.setViewRotation(degrees: angle)
        }
    }
    @objc func fitImage(_ sender: Any?) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize
        let extent = CanvasRotationView.rotatedSize(
            CGSize(width: imageDocument.info.width, height: imageDocument.info.height),
            degrees: rotationView.rotationDegrees)
        zoom(to: ZoomLadder.fit(imageWidth: Double(extent.width), imageHeight: Double(extent.height),
                               viewportWidth: Double(viewport.width), viewportHeight: Double(viewport.height),
                               backingFactor: Double(window?.backingScaleFactor ?? 1)))
        center(on: CGPoint(x: Double(imageDocument.info.width) / 2, y: Double(imageDocument.info.height) / 2))
    }

    @objc func gaussianBlur(_ sender: Any?) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        endPendingEdits()
        startFilterPreview(title: "Gaussian Blur", operation: GaussianBlurPanel.operation) { [imageDocument] filter, _ in
            GaussianBlurPanel(document: imageDocument, filter: filter)
        }
    }

    /// Image ▸ New Snapshot: an independent copy opened as a new document.
    @objc func newSnapshot(_ sender: Any?) { imageDocument.newSnapshot() }

    // MARK: Guides

    /// Image ▸ Guides…: opens this document's guide management sheet. The
    /// sheet is owned by this window controller and reads only the cached
    /// document state, so opening it never makes a native call.
    @objc func showGuides(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              guidesSheet == nil else { return }
        let sheet = GuidesSheetController(document: imageDocument, hostWindow: window)
        guidesSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.guidesSheet === sheet else { return }
            sheet.invalidate()
            self.guidesSheet = nil
        }
    }

    /// View ▸ Show Guides: flips this window's cached flag and redraws the
    /// canvas. Pure view state — no native guide edit, no pixel, dirty,
    /// export or print change.
    @objc func toggleShowGuides(_ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        guidesViewState.toggle()
        canvas.showsGuides = guidesViewState.showsGuides
        canvas.needsDisplay = true
        if let item = sender as? NSMenuItem { item.state = guidesViewState.menuState }
    }

    // MARK: Grid

    /// Image ▸ Configure Grid…: opens this window's grid configuration
    /// sheet. The sheet is owned by this window controller, captures this
    /// document and seeds its draft from the cached grid only, so opening
    /// it never makes a native call.
    @objc func configureGrid(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              gridSheet == nil else { return }
        let sheet = GridSheetController(document: imageDocument, hostWindow: window)
        gridSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.gridSheet === sheet else { return }
            sheet.invalidate()
            self.gridSheet = nil
        }
    }

    /// Image ▸ Metadata…: opens this document's metadata sheet. The
    /// sheet is owned by this window controller and captures this
    /// document at open; its first tag-catalog read is queued as counted
    /// document work, so opening makes no native call on the main thread.
    /// Metadata is image-level: a mask or channel target does not
    /// restrict it. The sheet must not stack on another sheet of this
    /// window.
    @objc func showMetadata(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              metadataSheet == nil else { return }
        let sheet = MetadataSheetController(document: imageDocument, hostWindow: window)
        metadataSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.metadataSheet === sheet else { return }
            sheet.invalidate()
            self.metadataSheet = nil
        }
    }

    /// View ▸ Saved Sets…: opens this document's non-modal saved-set panel.
    /// One per window; opening makes no native call — the first catalog
    /// read is queued as counted document work.
    @objc func showSavedSets(_ sender: Any?) {
        guard !imageDocument.isClosing, savedSetPanel == nil else { return }
        let panel = SavedSetPanelController(document: imageDocument, host: self)
        savedSetPanel = panel
        panel.showWindow(nil)
    }

    /// The panel's own window closing clears the window's reference.
    func clearSavedSetPanel(_ panel: SavedSetPanelController) {
        if savedSetPanel === panel { savedSetPanel = nil }
    }

    /// View ▸ Show Grid: flips this window's cached flag and redraws the
    /// canvas. Pure view state — no image pixels, file, dirty, history,
    /// selection, export or print change — so it works while the engine
    /// is busy.
    @objc func toggleShowGrid(_ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        gridViewState.toggle()
        canvas.showsGrid = gridViewState.showsGrid
        canvas.needsDisplay = true
        if let item = sender as? NSMenuItem { item.state = gridViewState.menuState }
    }

    /// View ▸ Show Rulers: flips this window's cached flag and the scroll
    /// view's native ruler slots, which relayout the viewport around them.
    /// Pure view state — no engine call, no pixel, file, dirty, history,
    /// selection, export or print change — and it never waits for the
    /// engine, so the toggle works while the engine is busy.
    @objc func toggleShowRulers(_ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        rulerViewState.toggle()
        scrollView.rulersVisible = rulerViewState.showsRulers
        scrollView.tile()
        invalidateRulers()
        if let item = sender as? NSMenuItem { item.state = rulerViewState.menuState }

    }

    /// View ▸ Show Layer Boundary: flips this window's cached flag and
    /// redraws the canvas. Pure view state — no engine call, no pixel,
    /// dirty, history, selection, export or print change — so it works
    /// while the engine is busy.
    @objc func toggleLayerBoundary(_ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        layerBoundaryViewState.toggle()
        canvas.showsLayerBoundary = layerBoundaryViewState.showsLayerBoundary
        canvas.needsDisplay = true
        if let item = sender as? NSMenuItem { item.state = layerBoundaryViewState.menuState }
    }

    /// View ▸ Show Selection Edges: flips this window's cached flag and
    /// redraws. Hiding only stops the marching-ants outline and its
    /// timer; the native selection, its cached bounds and every command
    /// stay unchanged. Pure view state, so it works while the engine is
    /// busy.
    @objc func toggleSelectionEdges(_ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        selectionEdgesViewState.toggle()
        canvas.showsSelectionEdges = selectionEdgesViewState.showsSelectionEdges
        canvas.needsDisplay = true
        if let item = sender as? NSMenuItem { item.state = selectionEdgesViewState.menuState }
    }

    @objc func toggleSoftProof(_ sender: Any?) {
        guard !closeStarted, !imageDocument.isClosing, window?.attachedSheet == nil else { return }
        if canvas.softProof != nil {
            canvas.setSoftProof(nil)
        } else if let proof = savedSoftProof {
            canvas.setSoftProof(proof)
        } else {
            showSoftProofSetup(sender)
        }
        if let item = sender as? NSMenuItem { item.state = canvas.softProof == nil ? .off : .on }
    }

    @objc func showSoftProofSetup(_ sender: Any?) {
        guard let window, !closeStarted, !imageDocument.isClosing,
              window.attachedSheet == nil, softProofController == nil else { return }
        let document = imageDocument
        let controller = SoftProofController(document: document, initial: savedSoftProof,
            destination: { [weak self] in CanvasDisplayDestination.snapshot(window: self?.window) },
            onApply: { [weak self] proof in
                guard let self, !self.closeStarted, !document.isClosing,
                      self.imageDocument === document else { return }
                self.savedSoftProof = proof
                self.canvas.setSoftProof(proof)
            }, onDismiss: { [weak self] in self?.softProofController = nil })
        softProofController = controller
        controller.present(on: window)
    }

    // MARK: Snap To

    /// View ▸ Snap To ▸ Guides: flips this window's cached snap entry and
    /// redraws. Pure view state — no engine call, no pixel, dirty, history,
    /// selection, export or print change.
    @objc func toggleSnapToGuides(_ sender: Any?) { toggleSnapTo(.guides, sender) }

    /// View ▸ Snap To ▸ Grid. Same contract as Guides.
    @objc func toggleSnapToGrid(_ sender: Any?) { toggleSnapTo(.grid, sender) }

    /// View ▸ Snap To ▸ Canvas (the image edge and centre). Same contract.
    @objc func toggleSnapToCanvas(_ sender: Any?) { toggleSnapTo(.canvas, sender) }

    /// View ▸ Snap To ▸ Layer Bounds (other layers' edges and centres).
    /// Same contract.
    @objc func toggleSnapToLayerBounds(_ sender: Any?) { toggleSnapTo(.layerBounds, sender) }

    private func toggleSnapTo(_ kind: SnapToKind, _ sender: Any?) {
        guard !imageDocument.isClosing else { return }
        canvas.snapTo.toggle(kind)
        canvas.needsDisplay = true
        if let item = sender as? NSMenuItem { item.state = canvas.snapTo.menuState(kind) }
    }

    /// A catalog item in a Filter category: opens its generic form.
    @objc func runNativeFilter(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? NativeFilterCommand else { return }
        openNativeFilter(command.operation)
    }

    /// Opens the operation's form after committing in-flight edits, so
    /// the filter session begins on the committed layer. Property rows
    /// load off the main queue through the catalog; the shared preview
    /// start then queues the session's begin and initial reads behind
    /// pending input, and the panel builds when they land.
    func openNativeFilter(_ operation: EngineSession.FilterOperation) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        if operation.name == SourceFilterOperation.oilify.rawValue {
            guard imageDocument.session.supportsOilifySources, NativeFilterMenuLayout.usesSourceChooser(operation) else {
                statusBar.message = "Oilify is not available in this image engine."
                return
            }
            return openFilterSourceChooser(operation)
        }
        if NativeFilterMenuLayout.usesSourceChooser(operation) {
            return openFilterSourceChooser(operation)
        }
        if NativeFilterMenuLayout.usesCurvesEditor(operation) {
            endPendingEdits()
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginFilterPreview(operation: operation.name, properties: [], completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.curves else { return nil }
                return CurvesPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesLevelsEditor(operation) {
            endPendingEdits()
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginFilterPreview(operation: operation.name, properties: [], completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.levels else { return nil }
                return LevelsPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesHueSaturationEditor(operation) {
            endPendingEdits()
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginFilterPreview(operation: operation.name, properties: [], completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.hueSaturation else { return nil }
                return HueSaturationPanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesColorBalanceEditor(operation) {
            endPendingEdits()
            startPreview(title: operation.title, begin: { [imageDocument] reply in
                imageDocument.beginFilterPreview(operation: operation.name, properties: [], completion: reply)
            }) { [imageDocument] start in
                guard let settings = start.colorBalance else { return nil }
                return ColorBalancePanel(document: imageDocument, filter: start.filter, settings: settings)
            }
            return
        }
        if NativeFilterMenuLayout.usesBrightnessContrastEditor(operation) {
            endPendingEdits()
            startFilterPreview(title: operation.title, operation: operation.name) { [imageDocument] filter, values in
                BrightnessContrastPanel(document: imageDocument, filter: filter, initialValues: values)
            }
            return
        }
        guard operation.support == .supported else {
            if let reason = NativeFilterMenuLayout.unavailableReason(operation.support) {
                statusBar.message = "\(operation.title) \(reason) — not supported yet."
            }
            return
        }
        endPendingEdits()
        statusBar.message = "\(operation.title)…"
        NativeFilterCatalog.shared.properties(for: operation, using: imageDocument.session) { [weak self] properties in
            guard let self, !self.imageDocument.isClosing else { return }
            guard let properties else {
                self.statusBar.message = "\(operation.title) is not available."
                NSSound.beep()
                return
            }
            // The gates can have changed while the catalog answered.
            guard !self.previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
                  !self.imageDocument.isSavingForClose, !self.imageDocument.isTransferringClipboard else {
                self.statusBar.message = "Apply or cancel the current filter first."
                return
            }
            self.startFilterPreview(title: operation.title, operation: operation.name,
                                    properties: properties) { [imageDocument] filter, values in
                NativeFilterPanel.parameterPanel(document: imageDocument, operation: operation,
                                                 properties: properties, filter: filter, initialValues: values)
            }
        }
    }

    // MARK: Layer menu

    private func openFilterSourceChooser(_ operation: EngineSession.FilterOperation) {
        guard let target = imageDocument.activeLayer,
              let sourceOperation = SourceFilterOperation(rawValue: operation.name),
              NativeFilterMenuLayout.usesSourceChooser(operation) else { return }
        if sourceOperation == .displace || sourceOperation == .oilify {
            return openPairedSourceChooser(operation, sourceOperation: sourceOperation, target: target)
        }
        guard imageDocument.sourceFilterRefusal(target: target) == nil else {
            statusBar.message = imageDocument.sourceFilterRefusal(target: target) ?? "Choose a pixel layer first."
            return
        }
        if let filterSourceChooser, !filterSourceChooser.isInvalidated {
            if filterSourceChooser.operation == sourceOperation { filterSourceChooser.show(); return }
            filterSourceChooser.invalidate()
        }
        filterSourceRequest += 1
        let request = filterSourceRequest
        let targetName = imageDocument.layers.first { $0.id == target }?.name ?? "Layer"
        let rows: () -> [FilterSourceChoice] = { [weak self] in
            guard let self else { return [] }
            var rows: [FilterSourceChoice] = []
            for layer in self.imageDocument.layers {
                rows.append(.init(id: layer.id, name: layer.name))
                if let mask = self.imageDocument.maskStates[layer.id]?.mask, mask > 0 {
                    rows.append(.init(id: mask, name: "\(layer.name) — Mask"))
                }
            }
            rows += self.imageDocument.channels.map { .init(id: $0.id, name: "\($0.name) — Channel") }
            return rows
        }
        let refusal: () -> String? = { [weak self] in
            self?.imageDocument.sourceFilterRefusal(target: target) ?? (self == nil ? "The document is closed." : nil)
        }
        let preview: (Int32?, @escaping (Result<Void, Error>) -> Void) -> Void = { [weak self] source, completion in
            guard let self, self.filterSourceRequest == request, !self.closeStarted, !self.previewBusy,
                  self.imageDocument.sourceFilterRefusal(target: target) == nil else {
                completion(.failure(ImageDocument.DocumentError.busy)); return
            }
            self.endPendingEdits()
            self.imageDocument.loadFilterProperties(operation.name) { [weak self] result in
                guard let self, self.filterSourceRequest == request, !self.closeStarted, !self.imageDocument.isClosing,
                      self.filterSourceChooser?.isInvalidated == false else {
                    completion(.failure(ImageDocument.DocumentError.closed)); return
                }
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let properties):
                    guard !self.previewBusy, self.imageDocument.sourceFilterRefusal(target: target) == nil else {
                        completion(.failure(ImageDocument.DocumentError.busy)); return
                    }
                    self.startPreview(title: operation.title, begin: { [imageDocument = self.imageDocument] reply in
                        imageDocument.beginFilterPreview(operation: operation.name, properties: properties,
                                                         target: target, source: source, completion: reply)
                    }, started: completion) { [imageDocument = self.imageDocument] start in
                        NativeFilterPanel(document: imageDocument, operation: operation, properties: properties,
                                          filter: start.filter, initialValues: start.values, mergesPixels: true)
                    }
                }
            }
        }
        let chooser: FilterSourceChooserController
        if sourceOperation == .lensBlur {
            chooser = FilterSourceChooserController(lensBlurTargetName: targetName, rows: rows,
                refusal: refusal, hostWindow: window, previewLensBlur: preview)
        } else {
            chooser = FilterSourceChooserController(targetName: targetName, preferredSource: target,
                operation: sourceOperation, rows: rows, refusal: refusal, hostWindow: window,
                preview: { source, reply in preview(source, reply) })
        }
        chooser.onClosed = { [weak self] in
            guard let self, self.filterSourceRequest == request else { return }
            self.filterSourceRequest += 1; self.filterSourceChooser = nil
        }
        filterSourceChooser = chooser; chooser.show()
    }

    /// Owns its original document, target and explicit map choices. A
    /// parameter-catalog reply never follows the front window or selection.
    private func openPairedSourceChooser(_ operation: EngineSession.FilterOperation,
                                         sourceOperation: SourceFilterOperation, target: Int32) {
        guard imageDocument.sourceFilterRefusal(target: target) == nil else {
            statusBar.message = imageDocument.sourceFilterRefusal(target: target) ?? "Choose a pixel layer first."
            return
        }
        if let filterSourceChooser, !filterSourceChooser.isInvalidated {
            if filterSourceChooser.operation == sourceOperation { filterSourceChooser.show(); return }
            filterSourceChooser.invalidate()
        }
        filterSourceRequest += 1
        let request = filterSourceRequest
        let targetName = imageDocument.layers.first { $0.id == target }?.name ?? "Layer"
        let rows: () -> [FilterSourceChoice] = { [weak self] in
            guard let self else { return [] }
            var rows: [FilterSourceChoice] = []
            for layer in self.imageDocument.layers {
                rows.append(.init(id: layer.id, name: layer.name))
                if let mask = self.imageDocument.maskStates[layer.id]?.mask, mask > 0 {
                    rows.append(.init(id: mask, name: "\(layer.name) — Mask"))
                }
            }
            rows += self.imageDocument.channels.map { .init(id: $0.id, name: "\($0.name) — Channel") }
            return rows
        }
        let refusal: () -> String? = { [weak self] in
            self?.imageDocument.sourceFilterRefusal(target: target) ?? (self == nil ? "The document is closed." : nil)
        }
        let preview: (Int32?, Int32?, @escaping (Result<Void, Error>) -> Void) -> Void = { [weak self] first, second, completion in
            guard let self, self.filterSourceRequest == request, !self.closeStarted, !self.previewBusy,
                  self.imageDocument.sourceFilterRefusal(target: target) == nil else {
                completion(.failure(ImageDocument.DocumentError.busy)); return
            }
            self.endPendingEdits()
            self.imageDocument.loadFilterProperties(operation.name) { [weak self] result in
                guard let self, self.filterSourceRequest == request, !self.closeStarted, !self.imageDocument.isClosing,
                      self.filterSourceChooser?.isInvalidated == false else {
                    completion(.failure(ImageDocument.DocumentError.closed)); return
                }
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let properties):
                    guard !self.previewBusy, self.imageDocument.sourceFilterRefusal(target: target) == nil else {
                        completion(.failure(ImageDocument.DocumentError.busy)); return
                    }
                    self.startPreview(title: operation.title, begin: { [imageDocument = self.imageDocument] reply in
                        if sourceOperation == .oilify {
                            imageDocument.beginOilifyPreview(properties: properties, target: target,
                                                             radiusSource: first, exponentSource: second, completion: reply)
                        } else if let first, let second {
                            imageDocument.beginDisplacePreview(properties: properties, target: target,
                                                               xSource: first, ySource: second, completion: reply)
                        } else {
                            reply(.failure(ImageDocument.DocumentError.busy))
                        }
                    }, started: completion) { [imageDocument = self.imageDocument] start in
                        NativeFilterPanel(document: imageDocument, operation: operation, properties: properties,
                                          filter: start.filter, initialValues: start.values, mergesPixels: true)
                    }
                }
            }
        }
        let chooser: FilterSourceChooserController
        if sourceOperation == .oilify {
            chooser = FilterSourceChooserController(oilifyTargetName: targetName, rows: rows,
                                                   refusal: refusal, hostWindow: window, previewOilify: preview)
        } else {
            chooser = FilterSourceChooserController(displaceTargetName: targetName, rows: rows,
                                                   refusal: refusal, hostWindow: window, previewDisplace: { x, y, reply in
                preview(x, y, reply)
            })
        }
        chooser.onClosed = { [weak self] in
            guard let self, self.filterSourceRequest == request else { return }
            self.filterSourceRequest += 1; self.filterSourceChooser = nil
        }
        filterSourceChooser = chooser; chooser.show()
    }

    @objc func newLayer(_ sender: Any?) { imageDocument.layerCommand(.new) }
    @objc func duplicateLayer(_ sender: Any?) {
        if imageDocument.hasMultipleSelectedLayers { imageDocument.duplicateSelectedLayers() }
        else { imageDocument.layerCommand(.duplicate) }
    }
    @objc func deleteLayer(_ sender: Any?) { imageDocument.layerCommand(.delete) }
    @objc func bringLayerToFront(_ sender: Any?) { imageDocument.layerCommand(.toTop) }
    @objc func bringLayerForward(_ sender: Any?) { imageDocument.layerCommand(.raise) }
    @objc func sendLayerBackward(_ sender: Any?) { imageDocument.layerCommand(.lower) }
    @objc func sendLayerToBack(_ sender: Any?) { imageDocument.layerCommand(.toBottom) }
    @objc func layerToImageSize(_ sender: Any?) { imageDocument.layerCommand(.fitToImage) }
    @objc func trimLayerToContent(_ sender: Any?) { imageDocument.layerCommand(.trimToContent) }
    @objc func mergeDown(_ sender: Any?) { imageDocument.layerCommand(.mergeDown) }
    @objc func flattenImage(_ sender: Any?) { imageDocument.layerCommand(.flatten) }

    /// Layer ▸ New Layer Group.
    @objc func newLayerGroup(_ sender: Any?) { imageDocument.createGroup() }

    /// Layer ▸ New Adjustment Layer…: opens this document's creation
    /// sheet. The open gate reads only cached state — closing, busy,
    /// preview, another attached sheet — plus the cached color-mode gate:
    /// RGB and grayscale only. The sheet is owned by this window and captures
    /// this window's document, so nothing redirects to the front document.
    @objc func newAdjustmentLayer(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              adjustmentSheet == nil, imageDocument.acceptsEdits, !previewBusy,
              !imageDocument.targetCommandIsPending, !imageDocument.floatingState.isActive else { return }
        if let reason = AdjustmentLayerLogic.modeAdmission(imageDocument.colorInfo.mode).reason {
            statusBar.message = reason
            NSSound.beep()
            return
        }
        let sheet = AdjustmentLayerSheetController(document: imageDocument, hostWindow: window)
        sheet.host = self
        adjustmentSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.adjustmentSheet === sheet else { return }
            sheet.invalidate()
            self.adjustmentSheet = nil
        }
    }

    /// Phase 2 of New Adjustment Layer: opens the existing modeless
    /// effect-parameter editor on the created effect and layer. Called
    /// through the creation sheet's captured host, never the front window;
    /// a host whose document or window closed before the creation
    /// completed skips the editor — the committed adjustment layer stays.
    func openAdjustmentEditor(effect: Int32, on layer: Int32, operationName: String) {
        guard !closeStarted, !imageDocument.isClosing else { return }
        editEffectParameters(effect, on: layer, operationName: operationName)
    }

    // MARK: Layer mask menu

    /// Layer ▸ Mask ▸ Add…: the native source form on the active layer.
    @objc func addLayerMask(_ sender: Any?) {
        guard let window, let id = imageDocument.activeLayer else { return }
        AddMaskForm.present(for: imageDocument, on: window)
    }
    @objc func applyLayerMask(_ sender: Any?) { imageDocument.applyMask() }
    @objc func deleteLayerMask(_ sender: Any?) { imageDocument.deleteMask() }
    @objc func toggleMaskEnabled(_ sender: Any?) { imageDocument.toggleMaskEnabled() }
    @objc func toggleMaskEditing(_ sender: Any?) { imageDocument.toggleMaskEditing() }

    @objc func toggleQuickMask(_ sender: Any?) {
        guard !imageDocument.colorInfo.mode.usesInkChannels else { return }
        imageDocument.setQuickMask(!(imageDocument.quickMaskState?.enabled ?? false))
    }

    @objc func saveSelectionAsChannel(_ sender: Any?) {
        guard let window, !imageDocument.colorInfo.mode.usesInkChannels else { return }
        endPendingEdits()
        ChannelForms.saveSelection(in: imageDocument, on: window)
    }

    func editChannelAttributes(_ id: Int32) {
        guard let window else { return }
        endPendingEdits()
        ChannelForms.edit(id, in: imageDocument, on: window)
    }

    // MARK: Channel menu

    // Known channel picks are mirrored before they settle and do not set
    // targetCommandIsPending. Counted work must drain before resolving a
    // main-menu target; explicit palette row commands retain their own IDs.
    private var channelMenuBaseAllowed: Bool {
        ChannelMenuPolicy.baseEditingAllowed(
            acceptsEdits: imageDocument.acceptsEdits,
            isBusy: EngineActivity.shared.isBusy || PlugInCommands.isRunning
                || imageDocument.pendingWork != 0,
            previewBusy: previewBusy,
            sheetAttached: window?.attachedSheet != nil,
            isClosing: closeStarted || imageDocument.isClosing,
            targetCommandIsPending: imageDocument.targetCommandIsPending)
    }

    private var selectedSavedChannelMenuTarget: EngineSession.Channel? {
        ChannelMenuPolicy.savedTarget(in: imageDocument.channels, selectedIDs: imageDocument.selectedChannelIDs)
    }

    @objc func channelAttributesMenu(_ sender: Any?) {
        guard channelMenuBaseAllowed, !imageDocument.floatingState.isActive,
              let channel = selectedSavedChannelMenuTarget else { return }
        editChannelAttributes(channel.id)
    }

    @objc func duplicateChannelMenu(_ sender: Any?) {
        guard !imageDocument.colorInfo.mode.usesInkChannels,
              channelMenuBaseAllowed, !imageDocument.floatingState.isActive,
              let channel = selectedSavedChannelMenuTarget else { return }
        imageDocument.duplicateChannel(channel.id)
    }

    @objc func deleteChannelMenu(_ sender: Any?) {
        guard !imageDocument.colorInfo.mode.usesInkChannels,
              channelMenuBaseAllowed, !imageDocument.floatingState.isActive,
              let channel = selectedSavedChannelMenuTarget else { return }
        imageDocument.deleteChannel(channel.id)
    }

    @objc func returnToLayersMenu(_ sender: Any?) {
        guard canReturnToLayersFromMenu else { return }
        imageDocument.returnToLayers()
    }

    private var canReturnToLayersFromMenu: Bool {
        channelMenuBaseAllowed && imageDocument.isChannelTargetActive
            && imageDocument.activeLayer != nil && !imageDocument.floatingState.isActive
    }

    @objc func channelToSelectionMenu(_ sender: NSMenuItem) {
        guard !imageDocument.colorInfo.mode.usesInkChannels,
              channelMenuBaseAllowed, let channel = selectedSavedChannelMenuTarget,
              let tag = UInt32(exactly: sender.tag),
              let operation = EngineSession.SelectOperation(rawValue: tag) else { return }
        imageDocument.channelToSelection(channel.id, operation: operation)
    }
    @objc func toggleMaskShowing(_ sender: Any?) { imageDocument.toggleMaskShowing() }

    /// Layer ▸ Mask ▸ Mask to Selection ▸ …; the item's tag carries the
    /// operation's raw value.
    @objc func maskToSelection(_ sender: NSMenuItem) {
        guard let operation = EngineSession.SelectOperation(rawValue: UInt32(sender.tag)) else { return }
        imageDocument.maskToSelection(operation)
    }

    /// The active layer's mask state, when it has one.
    private var activeMask: EngineSession.MaskState? {
        guard let id = imageDocument.activeLayer else { return nil }
        return imageDocument.maskStates[id]
    }

    /// The active layer, when the menu has one to act on.
    private var activeLayerInfo: EngineSession.Layer? {
        guard let id = imageDocument.activeLayer else { return nil }
        return imageDocument.layers.first(where: { $0.id == id })
    }

    /// Layer ▸ Lock ▸ …: toggles the active item's own lock; the item's
    /// tag carries the lock's raw value.
    @objc func toggleLayerLock(_ sender: NSMenuItem) {
        guard let id = imageDocument.activeLayer else { return }
        imageDocument.toggleLocks(id, EngineSession.LayerLocks(rawValue: UInt32(sender.tag)))
    }

    /// What a lock item cannot see from its checkmark alone: locks a
    /// parent group or a layer inside enforces.
    static func lockNote(_ lock: EngineSession.LayerLocks,
                         sources: LayerTree.LockSources?) -> String? {
        guard let sources else { return nil }
        var notes: [String] = []
        if sources.inherited.contains(lock) { notes.append("locked by a parent group") }
        if sources.descendant.contains(lock) { notes.append("a layer inside is locked") }
        return notes.isEmpty ? nil : "\(LayerRowView.lockNames(lock).capitalized): \(notes.joined(separator: "; "))"
    }

    /// Name, blend mode and visibility of the selected layer.
    @objc func layerProperties(_ sender: Any?) {
        guard let window, let id = imageDocument.activeLayer,
              let layer = imageDocument.layers.first(where: { $0.id == id }) else { return }
        // Layer Properties is a single-layer command; under a
        // multi-selection it refuses instead of editing the primary alone.
        guard !imageDocument.refuseSingleLayerCommand("Layer Properties") else { return }
        let name = NSTextField(string: layer.name)
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: Self.blendModes)
        mode.selectItem(withTitle: layer.mode)
        let visible = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
        visible.state = layer.isVisible ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "Mode:"), mode],
            [NSGridCell.emptyContentView, visible],
        ])
        grid.column(at: 0).xPlacement = .trailing
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 280, height: 110)

        let alert = NSAlert()
        alert.messageText = "Layer Properties"
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var change = EngineSession.LayerChange()
            if name.stringValue != layer.name, !name.stringValue.isEmpty { change.name = name.stringValue }
            if let title = mode.titleOfSelectedItem, title != layer.mode { change.mode = title }
            if (visible.state == .on) != layer.isVisible { change.isVisible = visible.state == .on }
            if change != EngineSession.LayerChange() { self.imageDocument.changeLayer(id, change) }
        }
    }

    /// GIMP's default (non-legacy) layer modes by their engine nicks
    /// (GimpLayerMode in app/operations/operations-enums.c), in the order
    /// GIMP's mode menu groups them.
    /// Layer blend modes only: the engine's paint-only modes (behind,
    /// erase, merge, split) do not apply to layers.
    static let blendModes = ["normal", "dissolve",
                             "lighten-only", "luma-lighten-only", "screen", "dodge", "addition",
                             "darken-only", "luma-darken-only", "multiply", "burn", "linear-burn",
                             "overlay", "softlight", "hardlight", "vivid-light", "pin-light", "linear-light", "hard-mix",
                             "difference", "exclusion", "subtract", "grain-extract", "grain-merge", "divide",
                             "hsv-hue", "hsv-saturation", "hsl-color", "hsv-value",
                             "lch-hue", "lch-chroma", "lch-color", "lch-lightness", "luminance"]

    // MARK: Color mode and precision

    /// Image ▸ Mode ▸ RGB / Grayscale; the item's tag carries the
    /// target `ColorMode` raw value. Asking for the current mode is a
    /// no-op in the document — no queued work, no undo step.
    @objc func convertImageMode(_ sender: NSMenuItem) {
        guard let mode = EngineSession.ColorMode(rawValue: UInt32(sender.tag)) else { return }
        imageDocument.convertMode(to: mode) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.showStatusError(String(describing: error))
        }
    }

    /// Image ▸ Mode ▸ Indexed…: opens this document's conversion policy
    /// sheet. The sheet is owned by this window controller and captures
    /// this document at open, so a retarget cannot redirect the
    /// conversion; it reads only cached state, so opening it never makes
    /// a native call.
    @objc func convertImageToIndexed(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              indexedSheet == nil else { return }
        // Cached eligibility: an already indexed image is a no-op, and a
        // wrong precision or a grouped stack is refused with its reason —
        // precision is never auto-converted and groups never auto-flattened.
        let info = imageDocument.colorInfo
        let eligibility = IndexedFormLogic.nativeEligibility(
            mode: info.mode, component: info.component, trc: info.trc,
            hasGroup: imageDocument.layers.contains { $0.kind == .group })
        if info.mode == .indexed { return }
        guard eligibility.allowed else {
            imageDocument.onError?(eligibility.reason ?? "This image cannot be converted to indexed.")
            return
        }
        endPendingEdits()
        let sheet = IndexedSheetController(document: imageDocument, hostWindow: window)
        indexedSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.indexedSheet === sheet else { return }
            sheet.invalidate()
            self.indexedSheet = nil
        }
    }

    /// Image ▸ Precision…: a sheet of component and transfer curve
    /// popups seeded from the cached color state.
    @objc func imagePrecision(_ sender: Any?) {
        guard let window else { return }
        endPendingEdits()
        ColorForms.presentPrecision(for: imageDocument, on: window)
    }

    /// Image ▸ Image Information…: a read-only sheet of the mode,
    /// precision and effective profile — the document's cached color
    /// state, not a fresh engine ask.
    @objc func imageInformation(_ sender: Any?) {
        guard let window else { return }
        ColorForms.presentInformation(for: imageDocument, on: window)
    }

    /// Image ▸ Color Profile ▸ Assign…: the shared profile form in its
    /// assign kind, seeded from the cached color state.
    @objc func assignColorProfile(_ sender: Any?) {
        guard let window else { return }
        endPendingEdits()
        ProfileForm.present(.assign, for: imageDocument, on: window)
    }

    /// Image ▸ Color Profile ▸ Convert…: the shared profile form in its
    /// convert kind. Disabled for indexed images in validation; the
    /// document guards the same rule on Apply.
    @objc func convertColorProfile(_ sender: Any?) {
        guard let window else { return }
        endPendingEdits()
        ProfileForm.present(.convert, for: imageDocument, on: window)
    }

    // MARK: Image size and transforms

    @objc func rotateImage90(_ sender: Any?) { imageDocument.transformImage(.rotate90) }
    @objc func rotateImage270(_ sender: Any?) { imageDocument.transformImage(.rotate270) }
    @objc func rotateImage180(_ sender: Any?) { imageDocument.transformImage(.rotate180) }
    @objc func flipImageHorizontally(_ sender: Any?) { imageDocument.transformImage(.flipHorizontal) }
    @objc func flipImageVertically(_ sender: Any?) { imageDocument.transformImage(.flipVertical) }
    @objc func setTransformModeFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              item.action == #selector(setTransformModeFromMenu(_:)),
              let mode = LayerTransformSession.Mode.from(menuTag: item.tag),
              canvas.tools.transformModeSelectionAllowed else { return }
        ToolState.shared.select(.transform)
        _ = canvas.tools.setTransformMode(mode)
    }

    @objc func rotateLayer90(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate90) }
    @objc func rotateLayer270(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate270) }
    @objc func rotateLayer180(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate180) }
    @objc func flipLayerHorizontally(_ sender: Any?) { imageDocument.transformActiveLayer(.flipHorizontal) }
    @objc func flipLayerVertically(_ sender: Any?) { imageDocument.transformActiveLayer(.flipVertical) }

    @objc func imageSize(_ sender: Any?) {
        askSize("Image Size", constrain: true) { [weak self] width, height in
            self?.imageDocument.scale(toWidth: width, height: height)
        }
    }

    /// The canvas grows or shrinks around the image's center; the new area
    /// takes the background color, as in classic editors.
    @objc func canvasSize(_ sender: Any?) {
        askSize("Canvas Size", constrain: false) { [weak self] width, height in
            guard let self else { return }
            let info = self.imageDocument.info
            let offset = CGPoint(x: ((width - info.width) / 2), y: ((height - info.height) / 2))
            self.imageDocument.resizeCanvas(width: width, height: height, offset: offset,
                                            fill: ToolState.shared.background)
        }
    }

    /// A sheet asking for a width and height in pixels; with `constrain`
    /// the proportions stay linked until the box is unchecked.
    private func askSize(_ title: String, constrain: Bool, _ apply: @escaping (Int, Int) -> Void) {
        guard let window else { return }
        let info = imageDocument.info
        let width = NSTextField(string: String(info.width))
        let height = NSTextField(string: String(info.height))
        let link = NSButton(checkboxWithTitle: "Constrain proportions", target: nil, action: nil)
        link.state = constrain ? .on : .off
        let linker = ProportionLinker(width: width, height: height, ratio: Double(info.width) / Double(info.height), link: link)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width (px):"), width],
            [NSTextField(labelWithString: "Height (px):"), height],
            [NSGridCell.emptyContentView, link],
        ])
        grid.column(at: 0).xPlacement = .trailing
        width.widthAnchor.constraint(equalToConstant: 90).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 80)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Now \(info.width) × \(info.height) px."
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = width
        alert.beginSheetModal(for: window) { response in
            withExtendedLifetime(linker) {}
            guard response == .alertFirstButtonReturn, width.integerValue > 0, height.integerValue > 0 else { return }
            apply(width.integerValue, height.integerValue)
        }
    }

    @objc func cropToSelection(_ sender: Any?) {
        imageDocument.cropToSelection()
    }

    // MARK: Select menu

    @objc override func selectAll(_ sender: Any?) { imageDocument.select(.all) }
    @objc func selectNone(_ sender: Any?) { imageDocument.select(.none) }
    @objc func selectInverse(_ sender: Any?) { imageDocument.select(.invert) }
    @objc func sharpenSelection(_ sender: Any?) { imageDocument.select(.sharpen) }
    @objc func selectFromAlpha(_ sender: Any?) { imageDocument.select(.fromAlpha) }
    @objc func featherSelection(_ sender: Any?) { askRadius("Feather Selection", .feather, default: 5) }
    @objc func growSelection(_ sender: Any?) { askRadius("Grow Selection", .grow, default: 1) }
    @objc func shrinkSelection(_ sender: Any?) { askRadius("Shrink Selection", .shrink, default: 1) }
    @objc func borderSelection(_ sender: Any?) { askRadius("Border Selection", .border, default: 5) }

    /// A small sheet asking for a radius in pixels.
    private func askRadius(_ title: String, _ command: EngineSession.SelectCommand, default value: Double) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Radius in pixels:"
        let field = NSTextField(string: String(Int(value)))
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, field.doubleValue > 0 else { return }
            self?.imageDocument.select(command, radius: field.doubleValue)
        }
    }

    // MARK: Plug-in commands

    @objc func runPlugIn(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? PlugInCommand else { return }
        run(command.procedure, mode: .interactive)
    }

    @objc func repeatLastFilter(_ sender: Any?) {
        guard let last = PlugInCommands.last else { return }
        run(last, mode: .withLastValues)
    }

    @objc func reshowLastFilter(_ sender: Any?) {
        guard let last = PlugInCommands.last else { return }
        run(last, mode: .interactive)
    }

    /// Runs a plug-in command on this document, as its menu item does.
    func run(_ procedure: EngineSession.Procedure, mode: EngineSession.RunMode) {
        guard !PlugInCommands.isRunning, !EngineActivity.shared.isBusy, !imageDocument.isClosing else { return }
        guard !imageDocument.filterPreviewIsOpen else {
            statusBar.message = "Apply or cancel the filter preview first."
            return
        }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let title = procedure.label.replacingOccurrences(of: "…", with: "")
        EngineActivity.shared.finishPendingInput()
        PlugInCommands.willRun(procedure, on: imageDocument)
        statusBar.message = mode == .interactive && procedure.label.hasSuffix("…")
            ? "\(title): waiting for its settings window" : "\(title)…"
        imageDocument.run(procedure, mode: mode) { [weak self] result in
            PlugInCommands.didRun(procedure, outcome: try? result.get())
            guard let self else { return }
            self.statusProgressActive = false
            self.statusBar.hideProgress()
            self.refreshStatusInformationVisibility()
            switch result {
            case .success(.completed): self.stateDidChange()
            case .success(.cancelled): self.statusBar.message = "\(title) was cancelled."
            case .failure(let error): self.statusBar.message = "\(title): \(error)"
            }
        }
    }

    /// Progress of the plug-in command running on this document.
    func showProgress(_ progress: EngineSession.Progress?) {
        statusProgressActive = progress != nil
        guard let progress else {
            statusBar.hideProgress()
            refreshStatusInformationVisibility()
            refreshIdleStatus(.stateChange)
            return
        }
        statusBar.showProgress(fraction: progress.fraction) { [weak self] in
            _ = self?.imageDocument.session.cancelProcedure()
        }
        refreshStatusInformationVisibility()
        if !progress.text.isEmpty {
            statusBar.message = progress.text
        }
    }

    /// Select ▸ From Path: the active path's area becomes the selection.
    @objc func selectFromPath(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.selectFromPath(path)
    }

    /// The window starts closing before its render queue can hand the
    /// image to the document's close drain. Gate direct actions as well
    /// as menu validation throughout that interval.
    private var pathActionsAvailable: Bool {
        !closeStarted && !previewBusy && window?.attachedSheet == nil && imageDocument.acceptsEdits
    }

    @objc func newPath(_ sender: Any?) {
        guard pathActionsAvailable else { return }
        imageDocument.addPath(VectorPath()) { _ in }
    }

    @objc func deletePath(_ sender: Any?) {
        guard pathActionsAvailable, let path = imageDocument.activePath else { return }
        imageDocument.deletePath(path)
    }

    /// Edit ▸ Stroke Path: draws the active path on the active layer in the
    /// foreground color at the Path tool's stroke width.
    @objc func strokePath(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.strokePath(path, settings: ToolState.shared.pathLine)
    }

    /// Edit ▸ Fill…: fills the current selection (or the whole drawable) with
    /// the chosen color at the chosen opacity.
    @objc func fill(_ sender: Any?) {
        guard let window else { return }
        endPendingEdits()
        FillForm.present(in: imageDocument, on: window)
    }

    /// Edit ▸ Stroke Selection…: opens this document's stroke-selection
    /// sheet. The sheet is owned by this window controller and captures
    /// the current brush settings by value at open, so two documents keep
    /// independent sheets and no global ToolState changes. The open gate
    /// reads only the cached document state — busy, preview, closing,
    /// empty selection, mask/channel/group target, locks and editable
    /// structured sources refuse with a reason, never a native call on
    /// the main thread.
    @objc func strokeSelection(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              strokeSelectionSheet == nil else { return }
        if let reason = imageDocument.strokeSelectionRefusal {
            imageDocument.onError?(reason)
            NSSound.beep()
            return
        }
        let sheet = StrokeSelectionSheetController(document: imageDocument, hostWindow: window)
        strokeSelectionSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.strokeSelectionSheet === sheet else { return }
            sheet.invalidate()
            self.strokeSelectionSheet = nil
        }
    }

    /// Edit ▸ Create Resource ▸ Brush from Selection….
    @objc func createBrushFromSelection(_ sender: Any?) {
        presentResourceSelectionSheet(.brush)
    }

    /// Edit ▸ Create Resource ▸ Pattern from Selection….
    @objc func createPatternFromSelection(_ sender: Any?) {
        presentResourceSelectionSheet(.pattern)
    }

    /// Opens this document's create-resource sheet for `kind`. The sheet
    /// captures this window's document and the kind at open; the open gate
    /// reads only the cached document state — busy, preview, closing, no
    /// selection or an oversized selection refuse with a reason, never a
    /// native call on the main thread.
    private func presentResourceSelectionSheet(_ kind: EngineSession.ResourceKind) {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              resourceSelectionSheet == nil else { return }
        if let reason = imageDocument.createResourceRefusal(kind: kind) {
            imageDocument.onError?(reason)
            NSSound.beep()
            return
        }
        let sheet = ResourceSelectionSheetController(document: imageDocument, kind: kind, hostWindow: window)
        resourceSelectionSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.resourceSelectionSheet === sheet else { return }
            sheet.invalidate()
            self.resourceSelectionSheet = nil
        }
    }

    /// Edit ▸ Create Resource ▸ Gradient….
    @objc func createGradient(_ sender: Any?) {
        presentGradientCreateSheet()
    }

    /// Opens this document's create-gradient sheet. The sheet captures
    /// this window's document at open; the open gate reads only the cached
    /// document state — never the selection, the target or the engine —
    /// and refuses with a reason, never a native call on the main thread.
    private func presentGradientCreateSheet() {
        guard let window, !imageDocument.isClosing, window.attachedSheet == nil,
              gradientCreateSheet == nil else { return }
        if let reason = imageDocument.createGradientRefusal() {
            imageDocument.onError?(reason)
            NSSound.beep()
            return
        }
        let sheet = GradientCreateSheetController(document: imageDocument, hostWindow: window)
        gradientCreateSheet = sheet
        window.beginSheet(sheet.panel) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.gradientCreateSheet === sheet else { return }
            sheet.invalidate()
            self.gradientCreateSheet = nil
        }
    }

    /// Edit ▸ Fill Path: fills the active path's area on the current paint
    /// target using the Path tool's foreground color and fill settings.
    @objc func fillPath(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.fillPath(path, settings: ToolState.shared.pathFill)
    }

    /// Edit ▸ To Vector Layer: makes a genuine vector layer from the
    /// active path. The new layer starts in the engine's default style
    /// (white fill, black stroke); the foreground color is not applied.
    @objc func toVectorLayer(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.toVectorLayer(path)
    }

    /// Layer ▸ Vector Style…: the native fill/stroke sheet of the selected
    /// genuine vector layer. The gate reads the cached layer kind and the
    /// engine version only; the sheet itself reads the style off the main
    /// thread through the global engine activity.
    @objc func vectorStyle(_ sender: Any?) {
        guard let window, let id = imageDocument.activeLayer,
              imageDocument.layers.first(where: { $0.id == id })?.kind == .vector else { return }
        if imageDocument.supportsVectorLayers == false {
            imageDocument.onError?("This engine cannot edit vector layer styles; they arrived in GIMP 3.2.")
            return
        }
        endPendingEdits()
        VectorStyleForm.present(in: imageDocument, layer: id, on: window)
    }

    /// Layer ▸ Rasterize Layer… / Rasterize Layers…: source-preserving
    /// confirmation for one layer or a captured ordered selection.
    @objc func rasterizeLayer(_ sender: Any?) {
        if imageDocument.hasMultipleSelectedLayers {
            presentBatchRasterizeConfirmation()
            return
        }
        presentLayerSourceConfirmation(.rasterize)
    }

    /// Layer ▸ Restore Layer Source…: the inverse sheet, regenerating a
    /// rasterized layer from its retained source and discarding its pixel
    /// edits.
    @objc func restoreLayerSource(_ sender: Any?) {
        if imageDocument.hasMultipleSelectedLayers {
            presentBatchRestoreConfirmation()
            return
        }
        presentLayerSourceConfirmation(.restore)
    }

    private func presentBatchRestoreConfirmation() {
        let document = imageDocument
        let ids = document.selectedLayerIDs
        let rows = Dictionary(document.layers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let names = ids.compactMap { rows[$0] }
        guard let window, window.attachedSheet == nil, batchRestoreAlert == nil,
              !closeStarted, !previewBusy else { return }
        if let reason = document.restoreLayerSourcesRefusal(ids) {
            document.onError?(reason)
            NSSound.beep()
            return
        }
        guard names.count == ids.count else { return }
        // Capture names and IDs before committing fields can retarget the
        // document. This window, never the front window, owns the consent.
        endPendingEdits()
        guard !closeStarted, !previewBusy, imageDocument === document,
              window.attachedSheet == nil, batchRestoreAlert == nil else { return }
        if let reason = document.restoreLayerSourcesRefusal(ids) {
            document.onError?(reason)
            NSSound.beep()
            return
        }
        let alert = LayerRestoreSheet.makeAlert(names: names)
        batchRestoreAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.batchRestoreAlert === alert else { return }
            self.batchRestoreAlert = nil
            guard response == .alertFirstButtonReturn, !self.closeStarted,
                  self.imageDocument === document, !document.isClosing else { return }
            guard !self.previewBusy else {
                document.onError?(ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            if let reason = document.restoreLayerSourcesRefusal(ids, request: .explicitCommand) {
                document.onError?(reason)
                NSSound.beep()
                return
            }
            document.restoreLayerSources(ids)
        }
    }

    /// This window owns the sheet and its complete source vector. Capture
    /// IDs and displayed names before committing fields can change selection.
    /// Apply uses that document/vector; Cancel never calls its edit service.
    private func presentBatchRasterizeConfirmation() {
        let document = imageDocument
        let ids = document.selectedLayerIDs
        let rows = Dictionary(document.layers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let names = ids.compactMap { rows[$0] }
        guard let window, window.attachedSheet == nil, batchRasterizeAlert == nil,
              !closeStarted, !previewBusy else { return }
        if let reason = document.rasterizeLayerSourcesRefusal(ids) {
            document.onError?(reason)
            NSSound.beep()
            return
        }
        guard names.count == ids.count else { return }
        endPendingEdits()
        guard !closeStarted, !previewBusy, imageDocument === document,
              window.attachedSheet == nil, batchRasterizeAlert == nil else { return }
        if let reason = document.rasterizeLayerSourcesRefusal(ids) {
            document.onError?(reason)
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rasterize \(ids.count) Layers?"
        // Keep large selections/names within the sheet's readable bounds.
        let shownNames = names.prefix(3).map { name -> String in
            let displayed = name.count > 80 ? String(name.prefix(80)) + "…" : name
            return "\u{201C}\(displayed)\u{201D}"
        }.joined(separator: ", ")
        let remaining = names.count > 3 ? " and \(names.count - 3) more layers" : ""
        alert.informativeText = shownNames + remaining + ".\n\n"
            + "Editable text, link or path content becomes pixels, as one undo step. "
            + "Sources are retained, so Restore Layer Source can bring them back individually. "
            + "Rasterized linked layers stop following changes to their files."
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.forEach { $0.setAccessibilityLabel($0.title) }
        batchRasterizeAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.batchRasterizeAlert === alert else { return }
            self.batchRasterizeAlert = nil
            guard response == .alertFirstButtonReturn, !self.closeStarted,
                  self.imageDocument === document, !document.isClosing else { return }
            guard !self.previewBusy else {
                document.onError?(ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            if let reason = document.rasterizeLayerSourcesRefusal(ids) {
                document.onError?(reason)
                NSSound.beep()
                return
            }
            document.rasterizeLayerSources(ids)
        }
    }

    /// A refused paint gesture has already ended. Consent only rasterizes
    /// its captured target; drawing again starts a new, fully captured stroke.
    private func presentPaintSourceConfirmation(layer: Int32, stateVersion: Int) {
        let document = imageDocument
        func isCurrent() -> Bool {
            document.acceptsEdits && !document.targetCommandIsPending
                && document.pendingWork == 0 && !document.strokeIsActive
                && document.stateVersion == stateVersion
                && document.selectedLayerIDs == [layer] && document.activeDrawable == layer
                && !document.isMaskTargetActive && !document.isChannelTargetActive
        }
        guard let window, window.attachedSheet == nil, !closeStarted, !previewBusy, isCurrent(),
              let info = document.layers.first(where: { $0.id == layer }),
              LayerSourceMenuPolicy.isEnabled(.rasterize, source: document.layerSources[layer],
                  locks: document.layerLocks[layer], targetIsLayer: true, stateBlocked: false) else { return }
        let alert = NSAlert()
        alert.messageText = "Rasterize \u{201C}\(info.name)\u{201D} before painting?"
        alert.informativeText = "Painting changes the layer's pixels. Rasterize, then draw or apply the command again. "
            + "The editable source is retained; Layer > Restore Layer Source can restore it and discard pixel edits."
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.forEach { $0.setAccessibilityLabel($0.title) }
        paintSourceAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.paintSourceAlert === alert else { return }
            self.paintSourceAlert = nil
            guard response == .alertFirstButtonReturn, !self.closeStarted,
                  self.imageDocument === document else { return }
            guard isCurrent() else {
                self.showStatusError("The image changed. Start the paint command again.")
                return
            }
            document.rasterizeLayerSource(layer, paintStateVersion: stateVersion)
        }
    }

    /// Restoring is its own explicit command. Opening an editor requires a
    /// new Text click, so an old gesture never resumes after native work.
    private func presentTextSourceConfirmation(layer: Int32, stateVersion: Int) {
        let document = imageDocument
        let selection = document.selectedLayerIDs
        let drawable = document.activeDrawable
        func isCurrent() -> Bool {
            document.acceptsEdits && !document.targetCommandIsPending
                && document.pendingWork == 0 && !document.strokeIsActive
                && document.stateVersion == stateVersion
                && document.selectedLayerIDs == selection && document.activeDrawable == drawable
                && !document.isMaskTargetActive && !document.isChannelTargetActive
        }
        guard let window, window.attachedSheet == nil, textSourceAlert == nil,
              !closeStarted, !previewBusy, isCurrent() else {
            showStatusError(ImageDocument.DocumentError.busy.localizedDescription)
            return
        }
        guard let source = document.layerSources[layer], source.kind == .text,
              source.hasSource, source.isRasterized,
              let info = document.layers.first(where: { $0.id == layer }) else {
            showStatusError(ImageDocument.DocumentError.targetChanged.localizedDescription)
            return
        }
        if let reason = document.restoreLayerSourcesRefusal([layer]) {
            showStatusError(reason)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Restore \u{201C}\(info.name)\u{201D} before editing text?"
        alert.informativeText = "Restoring discards this layer's pixel edits and regenerates its retained text as one undo step. "
            + "Undo brings the painted pixels back. Restore, then click the text again to edit."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.forEach { $0.setAccessibilityLabel($0.title) }
        textSourceAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.textSourceAlert === alert else { return }
            self.textSourceAlert = nil
            guard response == .alertFirstButtonReturn, !self.closeStarted,
                  self.imageDocument === document, !document.isClosing else { return }
            guard !self.previewBusy, isCurrent() else {
                self.showStatusError("The image changed. Click the text again.")
                return
            }
            if let reason = document.restoreLayerSourcesRefusal([layer]) {
                self.showStatusError(reason)
                return
            }
            document.restoreLayerSource(layer, expectedStateVersion: stateVersion) { [weak self] result in
                guard case .success = result, let self, !self.closeStarted,
                      self.imageDocument === document, !document.isClosing else { return }
                self.statusIsError = false
                self.statusBar.message = "Source restored. Click the text again to edit."
            }
        }
    }

    /// The confirmation sheet shared by both layer-source commands. The
    /// document and the explicit layer id are captured by value before the
    /// alert is shown, so Apply can never fall back to layer 0, the
    /// engine's selection or the front window, and a retarget while the
    /// sheet is up does not move the captured id. Each window owns its own
    /// sheet — `attachedSheet` guards stacking — so two documents keep
    /// independent forms; no singleton, no shared state, and no existing
    /// callback hook is replaced. Cancel queues nothing. A document that
    /// began closing after the sheet opened wins over a late Apply.
    private func presentLayerSourceConfirmation(_ command: LayerSourceMenuPolicy.Command) {
        guard let window, window.attachedSheet == nil, !previewBusy,
              !imageDocument.isClosing, !imageDocument.isSavingForClose,
              !imageDocument.isTransferringClipboard,
              !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.targetCommandIsPending,
              !imageDocument.isMaskTargetActive, !imageDocument.isChannelTargetActive,
              let layer = activeLayerInfo,
              LayerSourceMenuPolicy.isEnabled(command,
                                              source: imageDocument.layerSources[layer.id],
                                              locks: imageDocument.layerLocks[layer.id],
                                              targetIsLayer: true,
                                              stateBlocked: false) else { return }
        endPendingEdits()
        let document = imageDocument
        let layerID = layer.id
        let layerName = layer.name
        let alert = NSAlert()
        switch command {
        case .rasterize:
            alert.messageText = "Rasterize \u{201C}\(layerName)\u{201D}?"
            alert.informativeText = "The layer's text, link or path content becomes pixels, as one undo step. "
                + "The source is retained, so Restore Layer Source can bring it back; while rasterized, "
                + "a linked layer stops following changes to its file."
            alert.addButton(withTitle: "Rasterize")
        case .restore:
            alert.messageText = "Restore the source of \u{201C}\(layerName)\u{201D}?"
            alert.informativeText = "The layer's pixel edits are discarded and its text, path or linked source "
                + "is regenerated, as one undo step; Undo brings the painted pixels back. A linked layer "
                + "reloads its file when it can be read, otherwise it resumes from the retained source "
                + "and follows the file again."
            alert.addButton(withTitle: "Restore")
        }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.forEach { $0.setAccessibilityLabel($0.title) }
        alert.beginSheetModal(for: window) { [weak self] response in
            // Cancel queues nothing; only the captured document's Apply
            // runs, on the captured explicit id alone.
            guard let self, response == .alertFirstButtonReturn,
                  self.imageDocument === document, !document.isClosing else { return }
            switch command {
            case .rasterize: document.rasterizeLayerSource(layerID)
            case .restore: document.restoreLayerSource(layerID)
            }
        }
    }

    /// The cached multi-selection gate for a single-layer menu item:
    /// while more than one layer is selected the item is disabled and
    /// its tooltip carries the actionable "Choose one layer" reason.
    /// Reads only cached state; returns false when gated.
    private func singleLayerItemAllowed(_ menuItem: NSMenuItem, action: String) -> Bool {
        if let reason = LayerSelectionPolicy.refusal(count: imageDocument.selectedLayerIDs.count, action: action) {
            menuItem.toolTip = reason
            return false
        }
        return true
    }

    /// Component documents expose only commands with qualified native routes.
    /// The engine independently enforces the same boundary for direct callers.
    private func permitsMultichannelMenu(_ action: Selector?) -> Bool {
        switch action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(saveDocumentCopy(_:)),
             #selector(revertDocument(_:)), #selector(newSnapshot(_:)),
             #selector(channelAttributesMenu(_:)), #selector(imageInformation(_:)),
             #selector(selectAll(_:)), #selector(selectNone(_:)), #selector(selectInverse(_:)),
             #selector(sharpenSelection(_:)), #selector(featherSelection(_:)),
             #selector(growSelection(_:)), #selector(shrinkSelection(_:)), #selector(borderSelection(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualPixels(_:)), #selector(fitImage(_:)),
             #selector(rotateViewClockwise(_:)), #selector(rotateViewCounterclockwise(_:)),
             #selector(setViewAngle(_:)), #selector(resetViewRotation(_:)),
             #selector(chooseScreenMode(_:)), #selector(cycleScreenMode(_:)),
             #selector(toggleShowRulers(_:)), #selector(toggleSelectionEdges(_:)),
             #selector(toggleShowGuides(_:)), #selector(toggleShowGrid(_:)),
             #selector(toggleSnapToGuides(_:)), #selector(toggleSnapToGrid(_:)),
             #selector(toggleSnapToCanvas(_:)), #selector(toggleSnapToLayerBounds(_:)):
            return true
        default: return false
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if imageDocument.colorInfo.mode.usesInkChannels && !permitsMultichannelMenu(menuItem.action) {
            menuItem.toolTip = "This command is unavailable for ink-channel documents."
            return false
        }
        let editingBlocked = imageDocument.isClosing || imageDocument.isSavingForClose
            || imageDocument.isTransferringClipboard || PlugInCommands.isRunning || EngineActivity.shared.isBusy || window?.attachedSheet != nil
        switch menuItem.action {
        case #selector(toggleSoftProof(_:)):
            menuItem.state = canvas.softProof == nil ? .off : .on
            return !closeStarted && !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(showSoftProofSetup(_:)):
            return !closeStarted && !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(duplicateLayer(_:)):
            let ids = imageDocument.selectedLayerIDs
            menuItem.title = ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer"
            menuItem.toolTip = nil
            guard !editingBlocked, !previewBusy, !ids.isEmpty, !imageDocument.targetCommandIsPending,
                  !imageDocument.floatingState.isActive else { return false }
            if ids.count > 1 {
                guard ids.count <= 256, ids.allSatisfy({ imageDocument.layerSources[$0]?.kind == .pixel }) else {
                    menuItem.toolTip = "Select ordinary pixel layers for a batch. Duplicate groups or editable sources individually."
                    return false
                }
            }
            return true
        case #selector(deleteLayer(_:)):
            let ids = imageDocument.selectedLayerIDs
            menuItem.title = ids.count > 1 ? "Delete Layers" : "Delete Layer"
            menuItem.toolTip = nil
            guard !editingBlocked, !previewBusy, !ids.isEmpty, !imageDocument.targetCommandIsPending,
                  !imageDocument.floatingState.isActive else { return false }
            if ids.count > 1 && (ids.count > 256 || !ids.allSatisfy({ imageDocument.layerSources[$0]?.kind == .pixel })) {
                menuItem.toolTip = "Select ordinary pixel layers for a batch. Delete groups or editable sources individually."
                return false
            }
            return true
        case #selector(setTransformModeFromMenu(_:)):
            guard let mode = LayerTransformSession.Mode.from(menuTag: menuItem.tag) else { return false }
            menuItem.state = ToolState.shared.current == .transform && canvas.tools.transformPreview?.mode == mode ? .on : .off
            return canvas.tools.transformModeSelectionAllowed
        case #selector(mergeDown(_:)),
             #selector(flattenImage(_:)), #selector(bringLayerToFront(_:)), #selector(bringLayerForward(_:)),
             #selector(sendLayerBackward(_:)), #selector(sendLayerToBack(_:)),
             #selector(rotateLayer90(_:)), #selector(rotateLayer270(_:)), #selector(rotateLayer180(_:)),
             #selector(flipLayerHorizontally(_:)), #selector(flipLayerVertically(_:)),
             #selector(layerProperties(_:)):
            // Single-layer commands: batch operations are unsupported, so
            // they disable with the reason under a multi-selection.
            guard !editingBlocked, !previewBusy, imageDocument.activeLayer != nil else { return false }
            return singleLayerItemAllowed(menuItem, action: menuItem.title)
        case #selector(toggleQuickMask(_:)):
            menuItem.state = imageDocument.quickMaskState?.enabled == true ? .on : .off
            return !editingBlocked && !previewBusy
        case #selector(saveSelectionAsChannel(_:)):
            return !editingBlocked && !previewBusy
        case #selector(channelAttributesMenu(_:)), #selector(duplicateChannelMenu(_:)),
             #selector(deleteChannelMenu(_:)):
            return channelMenuBaseAllowed && selectedSavedChannelMenuTarget != nil
                && !imageDocument.floatingState.isActive
        case #selector(channelToSelectionMenu(_:)):
            guard let tag = UInt32(exactly: menuItem.tag),
                  EngineSession.SelectOperation(rawValue: tag) != nil else { return false }
            return channelMenuBaseAllowed && selectedSavedChannelMenuTarget != nil
        case #selector(returnToLayersMenu(_:)):
            return canReturnToLayersFromMenu
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualPixels(_:)), #selector(fitImage(_:)):
            return !imageDocument.isClosing
        case #selector(rotateViewClockwise(_:)), #selector(rotateViewCounterclockwise(_:)), #selector(setViewAngle(_:)):
            return !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(resetViewRotation(_:)):
            return !imageDocument.isClosing && window?.attachedSheet == nil && rotationView.rotationDegrees != 0
        case #selector(pasteInto(_:)):
            // The tooltip explains the cached refusal: an active floating
            // selection, a missing/locked/structured target, a pending
            // target change or a busy preview — never an engine read.
            let readiness = imageDocument.pasteIntoReadiness
            menuItem.toolTip = readiness.allowed ? nil : readiness.reason
            return canPerformClipboardCommand(menuItem.action)
        case #selector(cut(_:)), #selector(copy(_:)), #selector(copyMerged(_:)),
             #selector(paste(_:)), #selector(pasteInPlace(_:)), #selector(deleteBackward(_:)):
            return canPerformClipboardCommand(menuItem.action)
        case #selector(newPath(_:)):
            return pathActionsAvailable
        case #selector(deletePath(_:)):
            return imageDocument.activePath != nil && pathActionsAvailable
        case #selector(selectFromPath(_:)), #selector(strokePath(_:)), #selector(fillPath(_:)):
            return imageDocument.activePath != nil && !editingBlocked
        case #selector(fill(_:)):
            guard !editingBlocked, !previewBusy, imageDocument.activeDrawable != nil else { return false }
            return singleLayerItemAllowed(menuItem, action: "Fill")
        case #selector(strokeSelection(_:)):
            // The gate reads only cached state — no native call while a
            // menu validates; the reason becomes the item's tool tip.
            if let reason = imageDocument.strokeSelectionRefusal {
                menuItem.toolTip = reason
                return false
            }
            menuItem.toolTip = nil
            return !editingBlocked && !previewBusy
        case #selector(createBrushFromSelection(_:)), #selector(createPatternFromSelection(_:)):
            // Cached gate only — no native call while a menu validates; the
            // refusal reason becomes the item's tool tip.
            let kind: EngineSession.ResourceKind =
                menuItem.action == #selector(createBrushFromSelection(_:)) ? .brush : .pattern
            if let reason = imageDocument.createResourceRefusal(kind: kind) {
                menuItem.toolTip = reason
                return false
            }
            menuItem.toolTip = nil
            return !editingBlocked && !previewBusy
        case #selector(createGradient(_:)):
            // Cached gate only — no native call while a menu validates.
            // The gradient catalog is global: no selection, target or
            // file-state gate applies. The refusal reason becomes the
            // item's tool tip.
            if let reason = imageDocument.createGradientRefusal() {
                menuItem.toolTip = reason
                return false
            }
            menuItem.toolTip = nil
            return !editingBlocked && !previewBusy
        case #selector(floatSelectedPixels(_:)), #selector(floatACopy(_:)):
            // Cached readiness only — selection present, no active
            // floating selection, one selected layer, not busy/closing/
            // preview/save/clipboard, no pending target change, and the
            // mode's lock/source gates. The tooltip carries the refusal
            // reason, or the mode's cut-vs-copy and selection-clear copy.
            let mode: EngineSession.FloatMode =
                menuItem.action == #selector(floatSelectedPixels(_:)) ? .move : .copy
            let readiness = imageDocument.floatReadiness(mode)
            if !readiness.allowed {
                menuItem.toolTip = readiness.reason
                return false
            }
            menuItem.toolTip = mode == .move
                ? FloatingControlsLogic.floatMoveTooltip : FloatingControlsLogic.floatCopyTooltip
            return !editingBlocked && !previewBusy
        case #selector(toVectorLayer(_:)):
            // Vector layers arrived in GIMP 3.2; older engines report
            // UNSUPPORTED when the command runs, so the item stays listed.
            menuItem.toolTip = PathsPaletteController.Command.toVectorLayer.toolTip
            return imageDocument.activePath != nil && !editingBlocked
                && imageDocument.supportsVectorLayers != false
        case #selector(vectorStyle(_:)):
            // A genuine vector layer only, from the cached layer list, and
            // an engine known to have native vector styles (GIMP 3.2+); an
            // unknown version stays enabled and the facade's own
            // UNSUPPORTED reports the rest at read time. The getter never
            // runs while a menu validates. No raster fallback: a non-vector
            // layer never gets the item.
            return activeLayerInfo?.kind == .vector && !editingBlocked && !previewBusy
                && imageDocument.supportsVectorLayers != false
                && singleLayerItemAllowed(menuItem, action: "Vector Style")
        case #selector(rasterizeLayer(_:)), #selector(restoreLayerSource(_:)):
            if menuItem.action == #selector(rasterizeLayer(_:)) {
                menuItem.title = imageDocument.hasMultipleSelectedLayers ? "Rasterize Layers…" : "Rasterize Layer…"
                menuItem.toolTip = nil
                if imageDocument.hasMultipleSelectedLayers {
                    let reason = imageDocument.rasterizeLayerSourcesRefusal(imageDocument.selectedLayerIDs)
                    menuItem.toolTip = reason
                    return reason == nil && !closeStarted && !editingBlocked && !previewBusy
                }
            }
            if menuItem.action == #selector(restoreLayerSource(_:)) {
                menuItem.title = imageDocument.hasMultipleSelectedLayers ? "Restore Layer Sources…" : "Restore Layer Source…"
                menuItem.toolTip = nil
                if imageDocument.hasMultipleSelectedLayers {
                    let reason = imageDocument.restoreLayerSourcesRefusal(imageDocument.selectedLayerIDs)
                    menuItem.toolTip = reason
                    return reason == nil && !closeStarted && !editingBlocked && !previewBusy
                }
            }
            // Cached source state only — never a synchronous native call:
            // Rasterize on genuine unrasterized text/link/vector with its
            // source retained, Restore on a rasterized retained source.
            // Mask and channel targets, inherited pixel/position locks,
            // a pending target command and every busy/closing/preview/
            // attached-sheet state disable the item.
            let command: LayerSourceMenuPolicy.Command =
                menuItem.action == #selector(rasterizeLayer(_:)) ? .rasterize : .restore
            guard let layer = activeLayerInfo else { return false }
            guard singleLayerItemAllowed(menuItem, action: menuItem.title) else { return false }
            return LayerSourceMenuPolicy.isEnabled(command,
                source: imageDocument.layerSources[layer.id],
                locks: imageDocument.layerLocks[layer.id],
                targetIsLayer: !imageDocument.isMaskTargetActive && !imageDocument.isChannelTargetActive,
                stateBlocked: editingBlocked || previewBusy || imageDocument.targetCommandIsPending)
        case #selector(newLayerGroup(_:)):
            return !editingBlocked && !previewBusy
        case #selector(newAdjustmentLayer(_:)):
            // Cached mode gate only — no native call while a menu
            // validates: adjustment layers are RGB/grayscale only, and an
            // indexed (or unknown) image disables the item with the reason
            // in its tooltip.
            let admission = AdjustmentLayerLogic.modeAdmission(imageDocument.colorInfo.mode)
            menuItem.toolTip = admission.reason
            return admission.allowed && !editingBlocked && !previewBusy
                && !imageDocument.targetCommandIsPending && !imageDocument.floatingState.isActive
        case #selector(layerToImageSize(_:)):
            menuItem.title = imageDocument.hasMultipleSelectedLayers ? "Layers to Image Size" : "Layer to Image Size"
            if imageDocument.hasMultipleSelectedLayers {
                let reason = imageDocument.fitSelectedLayersRefusal()
                menuItem.toolTip = reason
                return reason == nil && !editingBlocked && !previewBusy
            }
            menuItem.toolTip = nil
            guard let layer = activeLayerInfo, layer.kind == .pixel,
                  !editingBlocked, !previewBusy else { return false }
            guard singleLayerItemAllowed(menuItem, action: menuItem.title) else { return false }
            return imageDocument.layerLocks[layer.id]?.effective
                .isDisjoint(with: [.pixels, .position]) != false
        case #selector(trimLayerToContent(_:)):
            // Pixel layers only, from the cached list: the engine
            // refuses groups and editable text, link and vector layers,
            // so those never offer the item. Cached effective pixel and
            // position locks hide the refusal the engine would report.
            guard let layer = activeLayerInfo, layer.kind == .pixel,
                  !editingBlocked, !previewBusy else { return false }
            guard singleLayerItemAllowed(menuItem, action: menuItem.title) else { return false }
            return imageDocument.layerLocks[layer.id]?.effective
                .isDisjoint(with: [.pixels, .position]) != false
        case #selector(toggleLayerLock(_:)):
            guard !editingBlocked, !previewBusy, let id = imageDocument.activeLayer else { return false }
            guard singleLayerItemAllowed(menuItem, action: "Lock") else { return false }
            let lock = EngineSession.LayerLocks(rawValue: UInt32(menuItem.tag))
            let tree = LayerTree(layers: imageDocument.layers)
            let sources = tree.nodesByID[id].map { tree.lockSources(for: $0, states: imageDocument.layerLocks) }
            menuItem.state = sources?.local.contains(lock) == true ? .on : .off
            menuItem.toolTip = Self.lockNote(lock, sources: sources)
            return true
        case #selector(addLayerMask(_:)), #selector(applyLayerMask(_:)),
             #selector(deleteLayerMask(_:)), #selector(maskToSelection(_:)),
             #selector(toggleMaskEnabled(_:)), #selector(toggleMaskEditing(_:)),
             #selector(toggleMaskShowing(_:)):
            // The active-layer mask commands are single-layer commands.
            guard !editingBlocked, !previewBusy, activeLayerInfo != nil,
                  singleLayerItemAllowed(menuItem, action: menuItem.title) else { return false }
            switch menuItem.action {
            case #selector(addLayerMask(_:)):
                return !activeLayerInfo!.hasMask
            case #selector(applyLayerMask(_:)):
                // Apply is raster-only: the engine refuses groups and text,
                // link and vector layers, so they never offer it.
                return activeMask != nil && activeLayerInfo!.kind == .pixel
            case #selector(deleteLayerMask(_:)), #selector(maskToSelection(_:)):
                return activeLayerInfo!.hasMask
            default:
                guard let mask = activeMask else { return false }
                switch menuItem.action {
                case #selector(toggleMaskEnabled(_:)): menuItem.state = mask.enabled ? .on : .off
                case #selector(toggleMaskEditing(_:)): menuItem.state = mask.editing ? .on : .off
                default: menuItem.state = mask.showing ? .on : .off
                }
                return true
            }
        case #selector(convertImageMode(_:)):
            // The checkmark reads the cached color state, never the
            // engine. Indexed and unknown modes check neither entry —
            // they are the image's state, not a menu gap.
            menuItem.state = imageDocument.colorInfo.mode.rawValue == UInt32(menuItem.tag) ? .on : .off
            return !editingBlocked && !previewBusy
        case #selector(convertImageToIndexed(_:)):
            // The checkmark and the gates read the cached color state and
            // layer list, never the engine: an already indexed image is
            // checked and disabled (the document no-ops too), and the
            // native eligibility — u8 non-linear precision and no layer
            // groups — is explained in the tooltip when it fails, since
            // precision is never auto-converted and groups never flattened.
            let info = imageDocument.colorInfo
            let eligibility = IndexedFormLogic.nativeEligibility(
                mode: info.mode, component: info.component, trc: info.trc,
                hasGroup: imageDocument.layers.contains { $0.kind == .group })
            menuItem.state = info.mode == .indexed ? .on : .off
            menuItem.toolTip = eligibility.reason
            return eligibility.allowed && !editingBlocked && !previewBusy
        case #selector(imagePrecision(_:)):
            // Indexed precision is fixed at u8 non-linear: the item
            // stays listed but disabled, and says why in the tool tip.
            let fixed = ColorForms.precisionIsFixed(mode: imageDocument.colorInfo.mode)
            menuItem.toolTip = fixed ? "Indexed images keep 8-bit non-linear precision." : nil
            return !fixed && !editingBlocked && !previewBusy
        case #selector(imageInformation(_:)):
            // Read-only and cheap: the sheet shows the cached state,
            // so it works wherever another sheet does not already.
            return !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(showGuides(_:)):
            // The sheet reads only cached state; it just must not stack
            // on another sheet of this window.
            return !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(toggleShowGuides(_:)):
            // The checkmark reads the window's cached flag, never the
            // engine; toggling is view-only, so it stays available
            // wherever navigation is.
            menuItem.state = guidesViewState.menuState
            return !imageDocument.isClosing
        case #selector(configureGrid(_:)):
            // The sheet seeds only from cached state; it must not stack
            // on another sheet of this window. Grid configuration is
            // image metadata: a selected channel does not restrict it.
            return !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(showMetadata(_:)):
            // The sheet's reads and writes are queued counted document
            // work; validation reads only cached state, never the engine.
            // Image metadata is image-level: no channel/mask/target or
            // lock restriction. It must not stack on another sheet.
            return !imageDocument.isClosing && window?.attachedSheet == nil
        case #selector(showSavedSets(_:)):
            // Cached state only, never the engine; one non-modal panel per
            // window.
            return !imageDocument.isClosing && savedSetPanel == nil
        case #selector(toggleShowGrid(_:)):
            // The checkmark reads the window's cached flag, never the
            // engine; toggling is view-only, so it stays available even
            // while the engine is busy.
            menuItem.state = gridViewState.menuState
            return !imageDocument.isClosing

        case #selector(chooseScreenMode(_:)):
            guard let mode = DocumentScreenMode(rawValue: menuItem.tag) else { return false }
            menuItem.state = mode == screenMode ? .on : .off
            return canChangeScreenMode
        case #selector(cycleScreenMode(_:)):
            return canChangeScreenMode
        case #selector(toggleShowRulers(_:)):
            // Same contract as Show Guides, spelled out in RulerMenuLogic:
            // the checkmark reads the window's cached flag and an engine-
            // busy gate never applies to this display-only toggle.
            let rulerCheck = RulerMenuLogic.validate(showsRulers: rulerViewState.showsRulers,
                                                     isClosing: imageDocument.isClosing,
                                                     engineIsBusy: EngineActivity.shared.isBusy)
            menuItem.state = rulerCheck.state
            return rulerCheck.enabled


        case #selector(toggleLayerBoundary(_:)):
            // The checkmark reads the window's cached flag, never the
            // engine; toggling is view-only, so it stays available even
            // while the engine is busy.
            menuItem.state = layerBoundaryViewState.menuState
            return !imageDocument.isClosing
        case #selector(toggleSelectionEdges(_:)):
            // Same contract as Show Layer Boundary: the cached per-window
            // flag drives the checkmark and the item never gates on the
            // engine being busy.
            menuItem.state = selectionEdgesViewState.menuState
            return !imageDocument.isClosing
        case #selector(toggleSnapToGuides(_:)), #selector(toggleSnapToGrid(_:)),
             #selector(toggleSnapToCanvas(_:)), #selector(toggleSnapToLayerBounds(_:)):
            // The checkmark reads the window's cached per-entry flag, never
            // the engine; toggling is view-only, so it stays available
            // wherever navigation is.
            let kind: SnapToKind
            switch menuItem.action {
            case #selector(toggleSnapToGuides(_:)): kind = .guides
            case #selector(toggleSnapToGrid(_:)): kind = .grid
            case #selector(toggleSnapToCanvas(_:)): kind = .canvas
            default: kind = .layerBounds
            }
            menuItem.state = canvas.snapTo.menuState(kind)
            return !imageDocument.isClosing
        case #selector(assignColorProfile(_:)):
            // Assignment is allowed on every mode, indexed included:
            // it embeds a compatible profile without converting pixels.
            return !editingBlocked && !previewBusy
        case #selector(convertColorProfile(_:)):
            // Indexed images cannot convert their palette profile —
            // the native conversion ignores intent and BPC — so the
            // item stays listed but disabled, and says why.
            let allowed = ProfileForm.convertAllowed(mode: imageDocument.colorInfo.mode)
            menuItem.toolTip = allowed ? nil
                : "Convert the image to RGB first: indexed palette conversion ignores the intent and black-point settings."
            return allowed && !editingBlocked && !previewBusy
        case #selector(newSnapshot(_:)):
            // Without an app to adopt the copy there is nothing to run.
            return imageDocument.snapshotHandler != nil && !editingBlocked && !previewBusy
        case #selector(gaussianBlur(_:)):
            guard !editingBlocked, !previewBusy else { return false }
            return singleLayerItemAllowed(menuItem, action: "Gaussian Blur")
        case #selector(runNativeFilter(_:)):
            // Operations without an admitted source contract or dedicated
            // config editor stay disabled with their reason in the title.
            guard let command = menuItem.representedObject as? NativeFilterCommand,
                  (NativeFilterMenuLayout.supportsParameterEditor(command.operation)
                    || NativeFilterMenuLayout.usesSourceChooser(command.operation)) else { return false }
            if command.operation.name == SourceFilterOperation.oilify.rawValue,
               !imageDocument.session.supportsOilifySources { return false }
            guard !editingBlocked, !previewBusy, imageDocument.activeLayer != nil else { return false }
            if NativeFilterMenuLayout.usesSourceChooser(command.operation), let target = imageDocument.activeLayer {
                return imageDocument.sourceFilterRefusal(target: target) == nil
            }
            return singleLayerItemAllowed(menuItem, action: command.operation.title)
        case #selector(repeatExport(_:)):
            menuItem.title = imageDocument.fileState.lastExportURL.map { "Export to \($0.lastPathComponent)" } ?? "Export Again…"
            return !editingBlocked && !previewBusy
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(exportDocument(_:)), #selector(saveDocumentCopy(_:)),
             #selector(openLayersFromFile(_:)):
            // A plug-in dialog is modal for the engine; file calls get BUSY.
            return !editingBlocked && !previewBusy
        case #selector(revertDocument(_:)):
            let source = imageDocument.fileState.revertSource
            menuItem.title = source?.menuTitle ?? "Revert…"
            // Untitled images and open previews have nothing to revert
            // or too much to discard silently; the sheet asks anyway,
            // so a pending load and every busy gate also refuse.
            return source != nil && revertHandler != nil && !revertIsPending
                && !editingBlocked && !previewBusy
        case #selector(placeLinkFromFile(_:)):
            // Link layers need GIMP 3.2; an unknown version stays enabled
            // and the facade's own UNSUPPORTED answer reports the rest.
            return !editingBlocked && !previewBusy && imageDocument.supportsLinkLayers != false
        case #selector(runPlugIn(_:)):
            // The engine runs no plug-in while a filter preview is open.
            guard let command = menuItem.representedObject as? PlugInCommand else { return false }
            guard !editingBlocked, !previewBusy, imageDocument.canRun(command.procedure) else { return false }
            // A plug-in would run on every selected layer: a batch operation.
            return singleLayerItemAllowed(menuItem, action: command.procedure.label)
        case #selector(repeatLastFilter(_:)), #selector(reshowLastFilter(_:)):
            let base = menuItem.action == #selector(repeatLastFilter(_:)) ? "Last Filter" : "Last Filter Settings…"
            guard let last = PlugInCommands.last else {
                menuItem.title = base
                return false
            }
            let title = last.label.replacingOccurrences(of: "…", with: "")
            menuItem.title = menuItem.action == #selector(repeatLastFilter(_:))
                ? "Last Filter: \(title)" : "Last Filter Settings: \(title)…"
            guard !editingBlocked && !previewBusy && imageDocument.canRun(last) else { return false }
            return singleLayerItemAllowed(menuItem, action: last.label)
        case #selector(runGlimsPageSetup(_:)):
            // Page setup edits only the document's print info; it just
            // must not compete with another sheet on the same window.
            return !imageDocument.isClosing && pageLayout == nil && window?.attachedSheet == nil
        case #selector(printGlimsImage(_:)):
            return !editingBlocked && !previewBusy && !printJobIsOpen
        default:
            return !editingBlocked
        }
    }

    // MARK: Printing

    /// File ▸ Page Setup…: edits only this document's page layout —
    /// paper, orientation and margins. The image, its history and its
    /// file identity are untouched.
    @objc func runGlimsPageSetup(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, pageLayout == nil,
              window.attachedSheet == nil else { return }
        // A copy: the sheet may edit the object it gets while it is up,
        // and only OK may change the document's settings.
        let printInfo = (imageDocument.printInfo.copy() as? NSPrintInfo) ?? imageDocument.printInfo
        if let runner = pageSetupRunner {
            runner(printInfo, window) { [weak self] newInfo in
                guard let self, let newInfo else { return }
                self.imageDocument.printInfo = newInfo
            }
            return
        }
        let layout = NSPageLayout()
        pageLayout = layout
        layout.beginSheet(with: printInfo, modalFor: window, delegate: self,
                          didEnd: #selector(pageLayoutDidEnd(_:returnCode:contextInfo:)),
                          contextInfo: nil)
    }

    @objc private func pageLayoutDidEnd(_ layout: NSPageLayout, returnCode: Int,
                                        contextInfo: UnsafeMutableRawPointer?) {
        pageLayout = nil
        guard returnCode == NSApplication.ModalResponse.OK.rawValue,
              let newInfo = layout.printInfo else { return }
        imageDocument.printInfo = newInfo
    }

    /// File ▸ Print…: renders the committed composite once behind every
    /// accepted edit, then opens the standard print panel as a sheet.
    /// The page shows the state Print was chosen at; later edits cannot
    /// smear across a page the way a live render could.
    @objc func printGlimsImage(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, !printJobIsOpen, !previewBusy,
              !PlugInCommands.isRunning, !imageDocument.isSavingForClose,
              !imageDocument.isTransferringClipboard else { return }
        // A copy so later Page Setup changes cannot rewrite a page
        // that is already rendering.
        let printInfo = (imageDocument.printInfo.copy() as? NSPrintInfo) ?? imageDocument.printInfo
        printJobIsOpen = true
        statusBar.message = "Preparing to print…"
        imageDocument.preparePrintSnapshot(imageablePoints: printInfo.imageablePageBounds.size) {
            [weak self] result in
            self?.printPreparationDidFinish(result, printInfo: printInfo)
        }
    }

    private func printPreparationDidFinish(_ result: Result<PrintSnapshot, Error>,
                                           printInfo: NSPrintInfo) {
        // A close requested while the engine rendered takes precedence
        // over showing the panel.
        guard let window, !imageDocument.isClosing, !printJobDropped, closeCompletion == nil else {
            printJobDidFinish(printed: false)
            return
        }
        switch result {
        case .failure(let error):
            printJobIsOpen = false
            showStatusError(error.localizedDescription)
        case .success(let snapshot):
            let view = ImagePrintView(snapshot: snapshot, printInfo: printInfo,
                                      title: imageDocument.name)
            if let runner = printJobRunner {
                runner(view, printInfo, window) { [weak self] printed in
                    self?.printJobDidFinish(printed: printed)
                }
            } else {
                let operation = NSPrintOperation(view: view, printInfo: printInfo)
                operation.jobTitle = imageDocument.name
                activePrintOperation = operation
                operation.runModal(for: window, delegate: self,
                                   didRun: #selector(printOperation(_:didRunToSuccess:contextInfo:)),
                                   contextInfo: nil)
            }
        }
    }

    @objc private func printOperation(_ operation: NSPrintOperation, didRunToSuccess success: Bool,
                                      contextInfo: UnsafeMutableRawPointer?) {
        printJobDidFinish(printed: success)
    }

    /// The run ended — printed, cancelled or failed — or the job was
    /// dropped: the operation and its snapshot are released on every
    /// path. Cancellation stays silent like everywhere on macOS; the
    /// preparation status goes back to the document's either way.
    func printJobDidFinish(printed: Bool) {
        activePrintOperation = nil
        printJobIsOpen = false
        printJobDropped = false
        stateDidChange()
    }

    // MARK: File imports

    /// File ▸ Open as Layers…: one file, imported as layers.
    @objc func openLayersFromFile(_ sender: Any?) {
        askForImportFile(prompt: "Open", message: "Choose a file to open as layers.") { [weak self] url in
            self?.importChosenFile(url, asLink: false)
        }
    }

    /// File ▸ Place…: one file, placed as a link layer.
    /// Engines before GIMP 3.2 have no link layers; the menu already
    /// refuses them, and this guard keeps a programmatic trigger honest.
    @objc func placeLinkFromFile(_ sender: Any?) {
        guard imageDocument.supportsLinkLayers != false else {
            statusBar.message = "Linked layers are unavailable in this build. Use Open as Layers to import a copy."
            NSSound.beep()
            return
        }
        askForImportFile(prompt: "Place", message: "Choose a file to place as a link layer.") { [weak self] url in
            self?.importChosenFile(url, asLink: true)
        }
    }

    /// The import's file panel: one local file, presented as a sheet like
    /// Save's. Choosing commits in-flight edits first so the load sees
    /// the finished state; cancelling changes nothing.
    private func askForImportFile(prompt: String, message: String,
                                  _ chosen: @escaping (URL) -> Void) {
        guard let window, !imageDocument.isClosing else { return }
        endPendingEdits()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.message = message
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url)
        }
    }

    /// Hands the chosen file to the document, which owns admission, the
    /// engine-wide busy gate and the facade call; the status line reports
    /// the outcome and any native error.
    private func importChosenFile(_ url: URL, asLink: Bool) {
        let name = url.lastPathComponent
        let completion: @MainActor (Result<ImageDocument.ImportOutcome, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.openedLayers):
                self.statusBar.message = "Opened layers from \(name)"
            case .success(.placedLink):
                self.statusBar.message = "Placed \(name) as a link layer"
            case .success(.cancelled):
                self.statusBar.message = asLink ? "Placing \(name) was cancelled."
                    : "Opening \(name) as layers was cancelled."
            case .failure(let error):
                self.showStatusError(String(describing: error))
            }
            self.stateDidChange()
        }
        if asLink {
            imageDocument.placeLink(from: url, completion: completion)
        } else {
            imageDocument.openLayers(from: url, completion: completion)
        }
    }

    // MARK: Saving, exporting and closing

    /// File ▸ Save: writes the image's native XCF; new and imported
    /// images have none yet, so Save falls through to Save As.
    @objc func saveDocument(_ sender: Any?) {
        performSave { _ in }
    }

    /// File ▸ Save As: always asks for the XCF file to write.
    @objc func saveDocumentAs(_ sender: Any?) {
        askSaveTarget { _ in }
    }

    /// The save flow Cmd-S and the close prompt share; `done` gets
    /// whether a file was actually written.
    private enum WritePurpose { case ordinary, closing }

    private func performSave(purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        switch imageDocument.fileState.saveRoute {
        case .write(let url): saveTo(url, purpose: purpose, done: done)
        case .askForFile: askSaveTarget(purpose: purpose, done: done)
        }
    }

    private func askSaveTarget(purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard let window else { return done(false) }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(importedAs: "org.gimp.xcf", conformingTo: .image)]
        savePanel.allowsOtherFileTypes = false
        savePanel.nameFieldStringValue = DocumentFileState.suggestedBaseName(imageDocument.name) + ".xcf"
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return done(false) }
            self.saveTo(url, purpose: purpose, done: done)
        }
    }

    /// Writes the XCF, then moves the name, the represented file and the
    /// dirty flag to it — a failed or cancelled save changes nothing.
    private func saveTo(_ url: URL, purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        let release: () -> Void
        do { release = try reserveWrite?(url) ?? {} } catch {
            statusBar.message = error.localizedDescription
            return done(false)
        }
        statusBar.message = "Saving \(url.lastPathComponent)…"
        imageDocument.save(to: url) { [weak self] error in
            defer { release() }
            guard let self else { return done(false) }
            if let error {
                self.imageDocument.onError?(String(describing: error))
                return done(false)
            }
            self.imageDocument.noteSaved(to: url)
            self.window?.representedURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.statusBar.message = "Saved \(url.lastPathComponent)"
            self.stateDidChange()
            return done(true)
        }
    }

    private func canStartFileWrite(purpose: WritePurpose = .ordinary) -> Bool {
        guard !previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy, !imageDocument.isClosing,
              !imageDocument.isTransferringClipboard,
              !imageDocument.isSavingForClose || purpose == .closing else {
            statusBar.message = "Apply or cancel the current operation before saving or exporting."
            return false
        }
        // Commit field editors in floating palettes before taking a file
        // snapshot, just as the canvas text editor is committed below.
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        return true
    }

    @objc func exportDocument(_ sender: Any?) {
        guard canStartFileWrite() else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard let window else { return }
        var settings = imageDocument.lastExportSettings ?? ExportSettings()
        if let url = imageDocument.fileState.lastExportURL,
           let format = ExportFormat.forFileExtension(url.pathExtension) { settings.format = format }
        let export = ExportSavePanel(baseName: DocumentFileState.suggestedBaseName(imageDocument.name),
                                     settings: settings)
        export.panel.directoryURL = imageDocument.fileState.lastExportURL?.deletingLastPathComponent() ?? exportDirectory
        export.panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = export.panel.url, let self,
                  export.form.commitEditing() else { return }
            self.exportTo(url, settings: export.form.settings)
        }
    }

    @objc func repeatExport(_ sender: Any?) {
        guard let url = imageDocument.fileState.lastExportURL else { return exportDocument(sender) }
        exportTo(url, settings: imageDocument.lastExportSettings)
    }

    private func exportTo(_ url: URL, settings: ExportSettings? = nil) {
        guard canStartFileWrite() else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let release: () -> Void
        do { release = try reserveWrite?(url) ?? {} } catch {
            statusBar.message = error.localizedDescription
            return
        }
        statusBar.message = "Exporting \(url.lastPathComponent)…"
        imageDocument.export(to: url, settings: settings) { [self] error in
            defer { release() }
            if let error { imageDocument.onError?(String(describing: error)) }
            else { statusBar.message = "Exported \(url.lastPathComponent)" }
        }
    }

    @objc func saveDocumentCopy(_ sender: Any?) {
        guard canStartFileWrite(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(importedAs: "org.gimp.xcf", conformingTo: .image)]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = DocumentFileState.suggestedBaseName(imageDocument.name) + " copy.xcf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.canStartFileWrite() else { return }
            self.canvas.tools.finishTextEditing()
            if self.imageDocument.strokeIsActive { self.imageDocument.endStroke() }
            let release: () -> Void
            do { release = try self.reserveWrite?(url) ?? {} } catch {
                self.statusBar.message = error.localizedDescription
                return
            }
            self.statusBar.message = "Saving a copy…"
            self.imageDocument.saveCopy(to: url) { error in
                defer { release() }
                if let error { self.imageDocument.onError?(String(describing: error)) }
                else { self.statusBar.message = "Saved a copy to \(url.lastPathComponent)" }
            }
        }
    }

    /// File ▸ Revert…: reloads the saved XCF — or the original file an
    /// imported image came from — from disk. The sheet is the only
    /// approval for discarding this document's edits; the confirmed
    /// load runs through the app's file admission, which replaces this
    /// window's document only once the new image is valid. A failed or
    /// refused load leaves this document fully usable.
    @objc func revertDocument(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, !revertIsPending, !previewBusy,
              let revertHandler, let source = imageDocument.fileState.revertSource,
              !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isClosing, !imageDocument.isSavingForClose,
              !imageDocument.isTransferringClipboard else { return }
        endPendingEdits()
        let fileName = source.url.lastPathComponent
        let alert = NSAlert()
        switch source {
        case .native:
            alert.messageText = "Revert to \u{201C}\(fileName)\u{201D}?"
            alert.informativeText = "All changes to \u{201C}\(imageDocument.name)\u{201D} since it was last saved will be lost, including the undo history."
        case .imported:
            alert.messageText = "Re-import \u{201C}\(fileName)\u{201D}?"
            alert.informativeText = "All changes to \u{201C}\(imageDocument.name)\u{201D} will be lost, including the undo history. The document is imported again from its original file."
        }
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.revertIsPending else { return }
            DispatchQueue.main.async {
                self.recorderFiles.confirmLoss(.revert) { [weak self] approved in
                    guard let self, let approved,
                          self.imageDocument.fileState.revertSource == source,
                          !self.imageDocument.isClosing, !self.revertIsPending else { return }
                    self.revertRecorderApproval = approved
                    self.revertIsPending = true
                    revertHandler(source.url) { [weak self] result in
                        guard let self else { return }
                        self.revertIsPending = false
                        self.revertRecorderApproval = nil
                        if case .failure(let error) = result {
                            self.showStatusError(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    var canDiscardRecordingForRevert: Bool {
        !imageDocument.hasUnsavedRecordingChanges ||
            revertRecorderApproval == imageDocument.recorderContentCheckpoint()
    }

    func closeAfterRevert() -> Bool {
        guard canDiscardRecordingForRevert else { return false }
        closeDiscardingChanges()
        return true
    }

    /// A confirmed Revert's discard approval: no close path may ask to
    /// save this document again.
    func approveDiscard() { closeApproved = true }

    /// Closes the window without an unsaved-changes prompt; a
    /// confirmed revert already holds the discard approval. The
    /// ordinary close drain — preview cancellation, render reads and
    /// queued engine work — still applies.
    func closeDiscardingChanges() {
        closeApproved = true
        window?.close()
    }

    /// A confirmed revert's load is in flight: edits stay consented to
    /// discard, so a close during the load must not prompt again.
    private(set) var revertIsPending = false

    /// Whether the user already agreed to close: Don't Save, or a save
    /// that succeeded. The next close request goes through.
    private var closeApproved = false
    private var closeRecorderApproval: ImageDocument.RecorderInstallCheckpoint?
    private var revertRecorderApproval: ImageDocument.RecorderInstallCheckpoint?
    private var waitingForRecorderConsent = false
    private var savePromptVisible = false
    private var closeCompletion: ((Bool) -> Void)?
    /// Set the moment the window begins closing, before the async
    /// teardown; a revert landing meanwhile must not adopt into it.
    private(set) var closeStarted = false
    /// A close asked for while the engine was busy waits for the idle
    /// gate; an adoption landing first must yield to it.
    private(set) var waitingForActivityToClose = false

    /// Quit and Close All share the same save/cancel flow as the close dot.
    /// Completion waits for both render reads and engine work to finish.
    func requestClose(completion: @escaping (Bool) -> Void) {
        guard closeCompletion == nil else { return completion(false) }
        closeCompletion = completion
        guard let window else { return finishCloseRequest(true) }
        if closeStarted { return }
        if windowShouldClose(window) { window.close() }
    }

    private func finishCloseRequest(_ closed: Bool) {
        if !closed {
            closeRecorderApproval = nil
            closeApproved = false
        }
        let completion = closeCompletion
        closeCompletion = nil
        completion?(closed)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if EngineActivity.shared.isBusy {
            // A close during the snapshot render drops the print job;
            // the deferred close then continues without a print sheet.
            if printJobIsOpen { printJobDropped = true }
            if !waitingForActivityToClose {
                waitingForActivityToClose = true
                EngineActivity.shared.whenIdle { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    self.waitingForActivityToClose = false
                    if self.windowShouldClose(sender) { sender.close() }
                }
            }
            return false
        }
        if imageDocument.isSavingForClose || savePromptVisible { return false }
        if sender.attachedSheet != nil {
            statusBar.message = "Finish or cancel the dialog before closing this image."
            finishCloseRequest(false)
            return false
        }
        guard !PlugInCommands.isRunning else {
            statusBar.message = "Finish or cancel the running filter before closing this image."
            NSSound.beep()
            finishCloseRequest(false)
            return false
        }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        previewPanel?.cancel()
        cancelPendingPreview()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard approveRecordingCloseIfNeeded(sender) else { return false }
        if closeApproved || revertIsPending || !imageDocument.hasUnsavedChanges { return true }
        askToSaveChanges()
        return false
    }

    private func approveRecordingCloseIfNeeded(_ window: NSWindow) -> Bool {
        guard imageDocument.hasUnsavedRecordingChanges else { return true }
        let revision = imageDocument.recorderContentCheckpoint()
        if closeRecorderApproval == revision || (revertIsPending && canDiscardRecordingForRevert) { return true }
        guard !waitingForRecorderConsent else { return false }
        waitingForRecorderConsent = true
        recorderFiles.confirmLoss(.close) { [weak self, weak window] approved in
            guard let self else { return }
            self.waitingForRecorderConsent = false
            guard let window, self.window === window, let approved else {
                return self.finishCloseRequest(false)
            }
            self.closeRecorderApproval = approved
            DispatchQueue.main.async {
                guard !self.closeStarted, self.window === window else { return }
                if self.windowShouldClose(window) { window.close() }
            }
        }
        return false
    }

    /// Save / Don't Save / Cancel for a document with unsaved changes.
    /// A cancelled or failed save keeps the window open.
    private func askToSaveChanges() {
        guard let window, !savePromptVisible else { return }
        savePromptVisible = true
        let alert = NSAlert()
        alert.messageText = "Do you want to keep the changes to \u{201C}\(imageDocument.name)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "\u{7f}"
        dontSave.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.savePromptVisible = false
            switch response {
            case .alertFirstButtonReturn: self?.saveThenClose()
            case .alertThirdButtonReturn: self?.approveClose()
            default: self?.finishCloseRequest(false)
            }
        }
    }

    private func saveThenClose() {
        guard canStartFileWrite() else { return finishCloseRequest(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard imageDocument.beginCloseSave() else { return finishCloseRequest(false) }
        performSave(purpose: .closing) { [weak self] saved in
            guard let self else { return }
            if saved {
                self.approveClose()
            } else {
                let message = self.statusBar.message
                self.imageDocument.cancelCloseSave()
                self.statusBar.message = message
                self.finishCloseRequest(false)
            }
        }
    }

    private func approveClose() {
        closeApproved = true
        guard let window else { return }
        let current = imageDocument.recorderContentCheckpoint()
        if imageDocument.hasUnsavedRecordingChanges && closeRecorderApproval != current {
            if imageDocument.isSavingForClose { imageDocument.cancelCloseSave() }
            if windowShouldClose(window) { window.close() }
        } else { window.close() }
    }

    /// Edit ▸ Undo and Redo reach the engine through this (see
    /// `EngineUndoManager`).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        engineUndoManager
    }

    func windowDidBecomeMain(_ notification: Notification) {
        PaletteCenter.shared.frontDocumentDidChange()
    }

    deinit {
        // deinit is nonisolated, so the removal is inlined here rather than
        // routed through the main-actor-isolated helper; safe even if the
        // window never went through windowWillClose.
        if rulerObserversActive {
            NotificationCenter.default.removeObserver(self)
        }
    }

    func windowWillClose(_ notification: Notification) {
        closeScreenMode()
        closeStarted = true
        imageDocument.beginClosing()
        softProofController?.invalidate()
        softProofController = nil
        if let alert = viewAngleAlert, window?.attachedSheet === alert.window {
            window?.endSheet(alert.window, returnCode: .abort)
        }
        viewAngleAlert = nil
        if let alert = paintSourceAlert, window?.attachedSheet === alert.window {
            window?.endSheet(alert.window, returnCode: .abort)
        }
        paintSourceAlert = nil
        if let alert = textSourceAlert, window?.attachedSheet === alert.window {
            window?.endSheet(alert.window, returnCode: .abort)
        }
        textSourceAlert = nil
        if let alert = batchRasterizeAlert, window?.attachedSheet === alert.window {
            window?.endSheet(alert.window, returnCode: .abort)
        }
        batchRasterizeAlert = nil
        if let alert = batchRestoreAlert, window?.attachedSheet === alert.window {
            window?.endSheet(alert.window, returnCode: .abort)
        }
        batchRestoreAlert = nil
        canvas.tools.cancelSpringTools()
        // A closing window cancels any in-progress guide drag: the ghost is
        // cleared and no guide action is committed; late events afterwards
        // are ignored by the gesture's captured window/document identity.
        canvas.guideDrag.cancel()
        // A closing window likewise cancels an in-progress Move snap or
        // floating move: the preview and indicators clear and the release
        // commits nothing.
        canvas.tools.cancelMoveSnap()
        canvas.tools.cancelFloatingMove()
        // A closing window leaves no ruler observation behind; the ruler
        // views themselves go away with the scroll view's view hierarchy.
        removeRulerObservers()
        guidesSheet?.invalidate()
        strokeSelectionSheet?.invalidate()
        resourceSelectionSheet?.invalidate()
        gradientCreateSheet?.invalidate()
        if let panel = gradientCreateSheet?.panel, window?.attachedSheet === panel {
            window?.endSheet(panel)
        }
        gradientCreateSheet = nil
        savedSetPanel?.invalidate()
        savedSetPanel?.window?.orderOut(nil)
        savedSetPanel = nil

        gridSheet?.invalidate()

        indexedSheet?.invalidate()
        ResourceDuplicateFormController.documentWindowClosing(imageDocument)
        ResourceMutationFormController.documentWindowClosing(imageDocument)
        filterSourceRequest += 1; filterSourceChooser?.invalidate(); filterSourceChooser = nil

        metadataSheet?.invalidate()
        if let panel = metadataSheet?.panel {
            if window?.attachedSheet === panel { window?.endSheet(panel) }
            panel.orderOut(nil)
        }
        metadataSheet = nil
        adjustmentSheet?.invalidate()

        previewPanel?.cancel()
        cancelPendingPreview()
        canvas.stopRendering { [self] in
            imageDocument.closeImageWhenDrained {
                self.onClose?(self)
                self.finishCloseRequest(true)
            }
        }
    }
}

/// Keeps a width and height field in proportion while `link` is checked.
@MainActor
private final class ProportionLinker: NSObject, NSTextFieldDelegate {
    private let width: NSTextField
    private let height: NSTextField
    private let ratio: Double
    private let link: NSButton

    init(width: NSTextField, height: NSTextField, ratio: Double, link: NSButton) {
        self.width = width
        self.height = height
        self.ratio = ratio
        self.link = link
        super.init()
        width.delegate = self
        height.delegate = self
    }

    func controlTextDidChange(_ notification: Notification) {
        guard link.state == .on, ratio > 0, let field = notification.object as? NSTextField else { return }
        if field === width, width.integerValue > 0 {
            height.integerValue = max(1, Int((Double(width.integerValue) / ratio).rounded()))
        } else if field === height, height.integerValue > 0 {
            width.integerValue = max(1, Int((Double(height.integerValue) * ratio).rounded()))
        }
    }
}

/// Owned borderless modes have no title-bar close button. Route the normal
/// nil-target Close action through the same document admission/save flow.
@MainActor
private final class DocumentContentView: NSView {
    @objc func performClose(_ sender: Any?) {
        guard let window else { return }
        guard let owner = window.windowController as? DocumentWindowController,
              owner.screenModeSnapshot != nil else {
            window.performClose(sender)
            return
        }
        if owner.windowShouldClose(window) { window.close() }
    }
}
