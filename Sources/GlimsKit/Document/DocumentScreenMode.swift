import AppKit

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

/// Native Spaces transitions finish asynchronously. Changing the menu policy
/// exits and re-enters through AppKit's delegate options, without changing
/// application-wide presentation flags or overwriting a saved window frame.
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
        if phase == .stable { requested = .fullScreenWithMenu }
        phase = .entering
    }

    mutating func didEnter() {
        guard !isClosed else { return }
        mode = requested == .windowed ? .fullScreenWithMenu : requested
        requested = mode
        phase = .stable
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
        publishScreenMode()
        window.toggleFullScreen(nil)
    }

    func publishScreenMode() {
        NotificationCenter.default.post(name: Self.screenModeDidChange, object: imageDocument)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        screenModeState.willEnter()
        publishScreenMode()
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.remove([.hideDock, .hideMenuBar, .autoHideMenuBar])
        options.insert([.fullScreen, .autoHideDock])
        if screenModeState.requested == .fullScreenBare { options.insert(.autoHideMenuBar) }
        return options
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        screenModeState.didEnter()
        publishScreenMode()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        let reenter = screenModeState.didExit()
        publishScreenMode()
        guard reenter else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.imageDocument.isClosing, !self.screenModeState.isClosed,
                  self.screenModeState.phase == .entering else { return }
            self.window?.toggleFullScreen(nil)
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { screenModeFailed(window) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { screenModeFailed(window) }

    private func screenModeFailed(_ window: NSWindow) {
        screenModeState.failed(isFullScreen: window.styleMask.contains(.fullScreen))
        publishScreenMode()
    }
}
