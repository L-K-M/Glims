import AppKit
import RigiUI

@MainActor
final class ChannelsPaletteController: NSViewController, PaletteContent, PaletteEditScope.Content,
                                       NSMenuItemValidation {
    typealias Target = ImageDocument
    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.channels"), title: "Channels",
        contentSize: ChannelsPaletteView.defaultContentSize,
        sizing: .resizable(minimumContentSize: ChannelsPaletteView.minimumContentSize),
        frameAutosaveName: "Glims.palette.channels")

    private weak var document: ImageDocument?
    private let body = ChannelsPaletteView()
    private var thumbnailOwner: ObjectIdentifier?
    private var thumbnailVersion: Int?
    private var thumbnailRequest: ThumbnailRequest?

    private final class ThumbnailRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    override func loadView() {
        body.onAction = { [weak self] in self?.perform($0) }
        view = body
    }

    var editTarget: ImageDocument? { document }

    func retarget(to target: ImageDocument?) {
        PaletteEditScope.track(self)
        document = target
        reload()
    }

    func reload() {
        _ = view
        guard let document else {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            thumbnailOwner = nil
            thumbnailVersion = nil
            body.update(.init())
            body.setThumbnails([:])
            return
        }
        body.update(.init(components: document.components, channels: document.channels,
                          activeChannel: document.activeChannel,
                          hasSelectedChannels: document.isChannelTargetActive,
                          quickMask: document.quickMaskState,
                          acceptsEdits: document.acceptsEdits))
        let owner = ObjectIdentifier(document), version = document.stateVersion
        guard thumbnailOwner != owner || thumbnailVersion != version else { return }
        thumbnailRequest?.cancel()
        thumbnailOwner = owner
        thumbnailVersion = version
        body.setThumbnails([:])
        guard !document.isClosing else { return }
        let request = ThumbnailRequest()
        thumbnailRequest = request
        let ids = document.channels.map(\.id)
        // Pixel reads count toward this document's close and Quit drain.
        // A superseded read exits on the worker without touching its image.
        let accepted = document.run(effect: .readsPixels) { [weak self] session, image in
            var thumbnails: [Int32: CGImage] = [:]
            for id in ids {
                guard !request.isCancelled else { return }
                thumbnails[id] = try? session.drawableThumbnail(id, image: image, maxSize: 32)
            }
            DispatchQueue.main.async {
                guard let self, self.thumbnailRequest === request, !request.isCancelled,
                      let current = self.document, ObjectIdentifier(current) == owner,
                      current.stateVersion == version else { return }
                self.thumbnailRequest = nil
                self.body.setThumbnails(thumbnails)
            }
        }
        if !accepted { request.cancel(); thumbnailRequest = nil }
    }

    func perform(_ action: ChannelsPaletteView.Action) {
        guard let document, document.acceptsEdits else { return }
        switch action {
        case .setComponentActive(let component, let enabled): document.setComponentActive(component, to: enabled)
        case .setComponentVisible(let component, let visible): document.setComponentVisible(component, to: visible)
        case .selectChannel(let id): document.selectChannel(id)
        case .setChannelVisible(let id, let visible): document.changeChannel(id, .init(isVisible: visible))
        case .editChannel(let id):
            windowController(for: document)?.editChannelAttributes(id)
        case .newChannel:
            windowController(for: document)?.saveSelectionAsChannel(nil)
        case .duplicateChannel(let id): document.duplicateChannel(id)
        case .deleteChannel(let id): document.deleteChannel(id)
        case .channelToSelection(let id, let operation): document.channelToSelection(id, operation: operation)
        case .setQuickMask(let enabled): document.setQuickMask(enabled)
        case .returnToLayers: document.returnToLayers()
        }
    }

    private func windowController(for document: ImageDocument) -> DocumentWindowController? {
        NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.imageDocument === document }
    }

    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Channels")
        func add(_ title: String, _ action: ChannelsPaletteView.Action) {
            let item = NSMenuItem(title: title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        add("Save Selection as Channel…", .newChannel)
        add("Return to Layers", .returnToLayers)
        add("Quick Mask", .setQuickMask(!(document?.quickMaskState?.enabled ?? false)))
        if let id = document?.activeChannel {
            menu.addItem(.separator())
            add("Channel Attributes…", .editChannel(id))
            add("Duplicate Channel", .duplicateChannel(id))
            add("Delete Channel", .deleteChannel(id))
            menu.addItem(.separator())
            for (title, operation) in [("Replace Selection", EngineSession.SelectOperation.replace),
                                       ("Add to Selection", .add), ("Subtract from Selection", .subtract),
                                       ("Intersect with Selection", .intersect)] {
                add(title, .channelToSelection(id, operation))
            }
        }
        return menu
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ChannelsPaletteView.Action else { return }
        perform(action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let document, document.acceptsEdits,
              let action = menuItem.representedObject as? ChannelsPaletteView.Action else { return false }
        switch action {
        case .setQuickMask:
            menuItem.state = document.quickMaskState?.enabled == true ? .on : .off
            return true
        case .deleteChannel(let id): return document.channels.contains { $0.id == id && !$0.isQuickMask }
        case .editChannel(let id), .duplicateChannel(let id), .channelToSelection(let id, _):
            return document.channels.contains { $0.id == id }
        default: return true
        }
    }
}
