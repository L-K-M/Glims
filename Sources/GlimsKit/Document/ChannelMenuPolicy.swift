import Foundation

/// Pure cached-state gating for the main-menu Channel commands. Reads only
/// the document's cached selection, channel list and edit gates; never the
/// engine. The controller rechecks the same rules before acting.
enum ChannelMenuPolicy {
    static func permits(_ action: ChannelsPaletteView.Action, multichannel: Bool, lab: Bool = false) -> Bool {
        if lab { if case .selectLabAxis = action { return true }; return false }
        if case .selectLabAxis = action { return false }
        guard multichannel else { return true }
        switch action {
        case .selectChannel, .setChannelVisible, .editChannel: return true
        default: return false
        }
    }
    /// The single saved channel targeted by main-menu channel commands, or
    /// nil when there is not exactly one selected channel or that channel
    /// is Quick Mask. Never falls back to a remembered or first row.
    static func savedTarget(in channels: [EngineSession.Channel],
                            selectedIDs: [Int32]) -> EngineSession.Channel? {
        guard selectedIDs.count == 1, let id = selectedIDs.first,
              let row = channels.first(where: { $0.id == id }), !row.isQuickMask else { return nil }
        return row
    }

    static func baseEditingAllowed(acceptsEdits: Bool, isBusy: Bool, previewBusy: Bool,
                                   sheetAttached: Bool, isClosing: Bool,
                                   targetCommandIsPending: Bool) -> Bool {
        acceptsEdits && !isBusy && !previewBusy && !sheetAttached && !isClosing
            && !targetCommandIsPending
    }

}
