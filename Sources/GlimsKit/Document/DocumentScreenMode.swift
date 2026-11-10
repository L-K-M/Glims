import AppKit
import RigiUI

enum DocumentScreenMode: Int, CaseIterable {
    case windowed, fullScreenWithMenu, fullScreenBare

    var title: String {
        switch self {
        case .windowed: return "Windowed"
        case .fullScreenWithMenu: return "Full Screen with Menu"
        case .fullScreenBare: return "Full Screen Bare"
        }
    }

    var next: Self { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }
}

/// Owned screen modes apply in place. Native green-button transitions remain
/// asynchronous and cannot overlap an owned transition or a document close.
struct DocumentScreenModeState {
    enum Phase: Equatable { case stable, entering, exiting }
    private(set) var mode = DocumentScreenMode.windowed
    private(set) var requested = DocumentScreenMode.windowed
    private(set) var phase = Phase.stable
    private(set) var isClosed = false

    mutating func request(_ value: DocumentScreenMode) -> Bool {
        guard !isClosed, phase == .stable, value != mode else { return false }
        requested = value
        phase = mode == .windowed ? .entering : .exiting
        return true
    }

    mutating func willEnter() {
        guard !isClosed else { return }
        if phase == .stable { requested = .fullScreenBare }
        phase = .entering
    }

    mutating func didEnter() {
        guard !isClosed else { return }
        mode = requested == .windowed ? .fullScreenWithMenu : requested
        requested = mode
        phase = .stable
    }

    mutating func willExit() {
        guard !isClosed else { return }
        if phase != .exiting { requested = .windowed }
        phase = .exiting
    }

    /// True means a specifically requested change of full-screen policy
    /// still needs a fresh native entry. External exits never bounce back.
    mutating func didExit() -> Bool {
        guard !isClosed else { return false }
        let reenter = phase == .exiting && requested != .windowed
        mode = .windowed
        phase = reenter ? .entering : .stable
        if !reenter { requested = .windowed }
        return reenter
    }

    mutating func failed(isFullScreen: Bool) {
        guard !isClosed else { return }
        if !isFullScreen { mode = .windowed }
        requested = mode
        phase = .stable
    }

    mutating func didApplyOwnedMode() {
        guard !isClosed else { return }
        mode = requested
        phase = .stable
    }

    mutating func close() { isClosed = true; phase = .stable; requested = .windowed }
}

@MainActor
extension DocumentWindowController {
    static let screenModeDidChange = Notification.Name("ch.lkmc.Glims.screenModeDidChange")

    var screenMode: DocumentScreenMode { screenModeState.mode }
    var canChangeScreenMode: Bool {
        !imageDocument.isClosing && !screenModeState.isClosed
            && screenModeState.phase == .stable && window?.isVisible == true
            && window?.attachedSheet == nil && !canvas.tools.hasPendingInteraction
            && !canvas.guideDrag.isActive && !imageDocument.strokeIsActive
    }

    @objc func chooseScreenMode(_ sender: NSMenuItem) {
        guard let mode = DocumentScreenMode(rawValue: sender.tag) else { return }
        setScreenMode(mode)
    }

    @objc func cycleScreenMode(_ sender: Any?) { setScreenMode(screenMode.next) }

    func setScreenMode(_ mode: DocumentScreenMode) {
        guard canChangeScreenMode, screenModeState.request(mode), let window else { return }
        if window.styleMask.contains(.fullScreen) {
            publishScreenMode()
            window.toggleFullScreen(nil)
        } else {
            applyOwnedScreenMode()
        }
    }

    private func applyOwnedScreenMode() {
        guard let window = window as? ClassicWindow, !screenModeState.isClosed else { return }
        let mode = screenModeState.requested
        let responder = window.firstResponder
        if mode == .windowed {
            restoreScreenModeWindow()
        } else {
            guard let screen = window.screen ?? NSScreen.main else {
                screenModeState.failed(isFullScreen: false)
                publishScreenMode()
                return
            }
            if screenModeSnapshot == nil {
                screenModeSnapshot = DocumentScreenModeSnapshot(window)
            }
            window.borderlessFocusPolicy = .document
            window.styleMask = [.borderless, .closable]
            window.collectionBehavior = [.fullScreenNone]
            window.isMovable = false
            window.isMovableByWindowBackground = false
            var frame = screen.frame
            if mode == .fullScreenWithMenu {
                let menuHeight = max(NSApp.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness,
                                     screen.safeAreaInsets.top)
                frame.size.height = max(1, frame.height - menuHeight)
            }
            window.setFrame(frame, display: true)
        }
        screenModeState.didApplyOwnedMode()
        window.makeKeyAndOrderFront(nil)
        if let responder { _ = window.makeFirstResponder(responder) }
        DocumentScreenPresentation.shared.refresh()
        publishScreenMode()
    }

    private func restoreScreenModeWindow() {
        guard let window = window as? ClassicWindow, let saved = screenModeSnapshot else { return }
        screenModeSnapshot = nil
        window.styleMask = saved.style
        window.collectionBehavior = saved.collection
        window.isMovable = saved.movable
        window.isMovableByWindowBackground = saved.movableByBackground
        window.borderlessFocusPolicy = saved.focus
        window.setFrame(saved.frame, display: true)
    }

    func closeScreenMode() {
        screenModeState.close()
        restoreScreenModeWindow()
        DocumentScreenPresentation.shared.refresh()
        publishScreenMode()
    }

    func publishScreenMode() {
        NotificationCenter.default.post(name: Self.screenModeDidChange, object: imageDocument)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        screenModeState.willEnter()
        publishScreenMode()
    }


    func windowDidEnterFullScreen(_ notification: Notification) {
        screenModeState.didEnter()
        publishScreenMode()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        screenModeState.willExit()
        publishScreenMode()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        let reenter = screenModeState.didExit()
        publishScreenMode()
        guard reenter else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.imageDocument.isClosing, !self.screenModeState.isClosed,
                  self.screenModeState.phase == .entering else { return }
            self.applyOwnedScreenMode()
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { screenModeFailed(window) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { screenModeFailed(window) }

    private func screenModeFailed(_ window: NSWindow) {
        screenModeState.failed(isFullScreen: window.styleMask.contains(.fullScreen))
        publishScreenMode()
    }
}


@MainActor
struct DocumentScreenModeSnapshot {
    let frame: NSRect
    let style: NSWindow.StyleMask
    let collection: NSWindow.CollectionBehavior
    let movable: Bool
    let movableByBackground: Bool
    let focus: ClassicWindow.BorderlessFocusPolicy

    init(_ window: ClassicWindow) {
        frame = window.frame; style = window.styleMask
        collection = window.collectionBehavior
        movable = window.isMovable
        movableByBackground = window.isMovableByWindowBackground
        focus = window.borderlessFocusPolicy
    }
}

/// Presentation flags are application-wide. Only the active main document may
/// own them; a key palette must not steal that ownership. Restore the snapshot
/// on resignation/close. A later external change becomes the new restoration
/// baseline; only this document's menu/Dock policy is applied over it.
@MainActor
private final class DocumentScreenPresentation: NSObject {
    static let shared = DocumentScreenPresentation()
    private var baseline: NSApplication.PresentationOptions?
    private var applied: NSApplication.PresentationOptions?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    @objc private func changed(_ notification: Notification) {
        if notification.name == NSApplication.didResignActiveNotification { restore(); return }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard NSApp.isActive, let window = NSApp.mainWindow,
              let owner = window.delegate as? DocumentWindowController,
              window.isVisible, owner.screenModeSnapshot != nil, !owner.imageDocument.isClosing,
              !owner.screenModeState.isClosed, owner.screenMode != .windowed,
              !window.styleMask.contains(.fullScreen) else { restore(); return }
        let current = NSApp.presentationOptions
        if baseline == nil || (applied != nil && current != applied) {
            baseline = current
        }
        var options = baseline!
        options.remove([.fullScreen, .hideDock, .hideMenuBar, .autoHideMenuBar, .autoHideToolbar])
        options.insert(.autoHideDock)
        if owner.screenMode == .fullScreenBare { options.insert(.autoHideMenuBar) }
        applied = options
        NSApp.presentationOptions = options
    }

    private func restore() {
        if let baseline, NSApp.presentationOptions == applied { NSApp.presentationOptions = baseline }
        baseline = nil
        applied = nil
    }
}
