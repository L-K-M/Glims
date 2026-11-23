import AppKit

/// The committed settings of a native filter Apply, read back from its
/// session just before commit so Last Filter and Last Filter Settings can
/// replay them exactly. The seven closed-schema operations read and write
/// whole typed settings; every other operation snapshots its editable
/// properties by name.
enum CommittedFilterSettings: Equatable {
    case properties([String: EngineSession.FilterValue])
    case brightnessContrast(EngineSession.BrightnessContrastSettings)
    case colorBalance(EngineSession.ColorBalanceSettings)
    case curves(EngineSession.CurvesSettings)
    case hueSaturation(EngineSession.HueSaturationSettings)
    case levels(EngineSession.LevelsSettings)
    case gaussianBlur(EngineSession.GaussianBlurSettings)
    case unsharpMask(EngineSession.UnsharpMaskSettings)

    /// Writes the settings into an open filter session, on the session's
    /// queue. The stored values came from this engine's own reads, so a
    /// refused write is anomalous; it fails the begin rather than apply
    /// a filter different from the one that committed.
    nonisolated func apply(to session: EngineSession, filter: Int32) throws {
        switch self {
        case .properties(let values):
            for name in values.keys.sorted() {
                try session.setFilterProperty(filter, name, to: values[name]!)
            }
        case .brightnessContrast(let settings): try session.setBrightnessContrastSettings(filter, to: settings)
        case .colorBalance(let settings): try session.setColorBalanceSettings(filter, to: settings)
        case .curves(let settings): try session.setCurvesSettings(filter, to: settings)
        case .hueSaturation(let settings): try session.setHueSaturationSettings(filter, to: settings)
        case .levels(let settings): try session.setLevelsSettings(filter, to: settings)
        case .gaussianBlur(let settings): try session.setGaussianBlurSettings(filter, to: settings)
        case .unsharpMask(let settings): try session.setUnsharpMaskSettings(filter, to: settings)
        }
    }
}

/// How a filter session records its Apply for Last Filter. Installed on
/// the begin when the apply came from the Filter menu; Image > Adjust
/// items, adjustment layers, effect edits and Lab or ink paths carry no
/// spec and never become the last filter.
struct LastFilterSpec: Equatable {
    /// How the committed settings are captured at commit.
    enum Capture: Equatable {
        /// The operation's closed-schema whole-settings reader.
        case whole
        /// These editable properties, read back by name.
        case names([String])
    }

    /// The filter's display title at apply time, without an ellipsis.
    let title: String
    /// Which editor of one operation applied it, the rank filters share
    /// `gegl:median-blur`, so repeats dedupe and dispatch correctly.
    let variant: String?
    /// Filters that cannot rerun without their editor are still recorded,
    /// named and disabled rather than silently replaced by an older one.
    let isRepeatable: Bool
    let capture: Capture
}

/// A native filter that was actually applied from the Filter menu.
struct AppliedNativeFilter: Equatable {
    /// The operation's engine name, e.g. "gegl:gaussian-blur".
    let operation: String
    let variant: String?
    /// The filter's display title at apply time, without an ellipsis.
    let title: String
    let capture: LastFilterSpec.Capture
    let isRepeatable: Bool
    /// The committed settings; `nil` only when a repeatable capture failed,
    /// which also clears `isRepeatable`.
    let settings: CommittedFilterSettings?

    /// The spec that records a later Apply of this same filter: a repeat
    /// or a reopened editor captures its own fresh settings.
    var spec: LastFilterSpec {
        LastFilterSpec(title: title, variant: variant, isRepeatable: isRepeatable, capture: capture)
    }

    /// The Gaussian Blur panel's slider value for a reshow, whichever
    /// capture shape recorded it; `std-dev-x` is that value.
    var gaussianDeviation: Double? {
        switch settings {
        case .gaussianBlur(let stored): return stored.deviationX
        case .properties(let values): if case .number(let x)? = values["std-dev-x"] { return x }
        default: return nil
        }
        return nil
    }

    /// The rank filter panel's slider value for a reshow.
    var rankRadius: Int? {
        guard case .properties(let values) = settings,
              case .integer(let radius)? = values["radius"] else { return nil }
        return Int(radius)
    }
}

/// A native filter applied from the Filter menu, or a completed plug-in
/// command from any menu.
enum AppliedFilter: Equatable {
    case plugIn(EngineSession.Procedure)
    case native(AppliedNativeFilter)

    /// The display name Last Filter and Recently Used show; ellipses mark
    /// commands that open a window, not the filter itself.
    var title: String {
        switch self {
        case .plugIn(let procedure): return procedure.label.replacingOccurrences(of: "…", with: "")
        case .native(let applied): return applied.title
        }
    }

    /// Two applies of the same filter dedupe: a plug-in by procedure name,
    /// a native one by operation and editor variant.
    var identity: String {
        switch self {
        case .plugIn(let procedure): return "plugin:" + procedure.name
        case .native(let applied): return "native:" + applied.operation + ":" + (applied.variant ?? "")
        }
    }
}

/// The Last Filter selection rule, newest first. A new apply moves to the
/// front, replacing an earlier apply of the same filter, and the list
/// keeps at most `limit` entries.
struct FilterHistory: Equatable {
    private(set) var entries: [AppliedFilter] = []

    var last: AppliedFilter? { entries.first }

    mutating func record(_ filter: AppliedFilter, limit: Int) {
        entries.removeAll { $0.identity == filter.identity }
        entries.insert(filter, at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
    }
}

/// App-wide state of the native filters applied from the Filter menu and
/// the plug-in commands completed from any menu: the Last Filter that
/// Command-F repeats and the Recently Used list. Only
/// completed applies record; Cancel, a refused Apply and previews never
/// reach here.
@MainActor
enum FilterCommands {
    static let maximumRecent = 8

    private(set) static var history = FilterHistory()

    static var last: AppliedFilter? { history.last }
    static var entries: [AppliedFilter] { history.entries }

    static func record(_ filter: AppliedFilter) {
        history.record(filter, limit: maximumRecent)
        updateRecentMenu()
    }

    /// Rebuilds the Filter menu's Recently Used submenu: plug-in and
    /// native filters together, newest first, each item doing what that
    /// filter's own menu item does.
    static func updateRecentMenu() {
        guard let menu = NSApp.mainMenu?.item(withTitle: GlimsMenu.filter.rawValue)?.submenu?
            .item(withTitle: MainMenu.recentlyUsedTitle)?.submenu else { return }
        menu.removeAllItems()
        for entry in entries {
            menu.addItem(item(for: entry))
        }
    }

    private static func item(for entry: AppliedFilter) -> NSMenuItem {
        switch entry {
        case .plugIn(let procedure):
            return PlugInMenus.commandItem(procedure)
        case .native(let applied):
            let item = NSMenuItem(title: "\(applied.title)…", action: nil, keyEquivalent: "")
            if applied.operation == GaussianBlurPanel.operation && applied.variant == nil {
                item.action = #selector(DocumentWindowController.gaussianBlur(_:))
            } else if applied.operation == RankFilterPanel.operation, let variant = applied.variant,
                      let rank = RankFilterPanel.Rank(variantTitle: variant) {
                item.action = rank == .maximum
                    ? #selector(DocumentWindowController.maximumFilter(_:))
                    : #selector(DocumentWindowController.minimumFilter(_:))
            } else {
                item.action = #selector(DocumentWindowController.runNativeFilter(_:))
                if let operation = NativeFilterCatalog.shared.operation(named: applied.operation) {
                    item.representedObject = NativeFilterCommand(operation, countsAsFilter: true)
                    item.toolTip = operation.blurb.isEmpty ? nil : operation.blurb
                }
                // An operation the engine no longer lists stays named but
                // disabled: its item validates like its own menu item.
            }
            return item
        }
    }
}
