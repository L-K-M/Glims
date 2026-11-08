import AppKit

/// The Image menu's color sheets: Precision (component type and
/// transfer curve) and Image Information (mode, precision and the
/// effective color profile). Both open from the document's cached color
/// state — the sheet never asks the engine to open, and the conversion
/// revalidates on the engine queue.
@MainActor
enum ColorForms {

    // MARK: Precision

    /// Whether the image's mode fixes its precision: an indexed image
    /// keeps u8 non-linear, the only combination the facade accepts for
    /// it. The Precision item stays listed but disabled, like the
    /// catalog's unavailable filters.
    static func precisionIsFixed(mode: EngineSession.ColorMode) -> Bool {
        mode == .indexed
    }

    /// A popup's content seeded with `current`: the valid choices in
    /// display order, and when `current` is not one of them — the
    /// engine reported a value this build does not know — a disabled
    /// "Unknown" row on top that shows the state honestly instead of
    /// seeding a wrong value. `disabled` is that row's index, if any.
    static func popupContent<T>(choices: [(value: T, title: String)], current: T)
        -> (titles: [String], selected: Int, disabled: Int?) where T: Equatable {
        if let index = choices.firstIndex(where: { $0.value == current }) {
            return (choices.map(\.title), index, nil)
        }
        return (["Unknown"] + choices.map(\.title), 0, 0)
    }

    /// Image ▸ Precision…: component and transfer curve popups seeded
    /// from the cached color state. OK queues one conversion through
    /// the document; picking the seeded values is a no-op there, and a
    /// left "Unknown" is refused with a reason rather than sent to the
    /// engine as garbage.
    static func presentPrecision(for document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil else { return }
        let info = document.colorInfo
        guard !precisionIsFixed(mode: info.mode) else {
            document.onError?("Indexed images keep 8-bit non-linear precision.")
            return
        }
        let components = EngineSession.ColorComponent.conversionChoices.map { (value: $0, title: $0.title) }
        let trcs = EngineSession.ColorTRC.conversionChoices.map { (value: $0, title: $0.title) }
        let componentContent = popupContent(choices: components, current: info.component)
        let trcContent = popupContent(choices: trcs, current: info.trc)

        let component = NSPopUpButton(frame: .zero, pullsDown: false)
        component.addItems(withTitles: componentContent.titles)
        component.selectItem(at: componentContent.selected)
        component.setAccessibilityLabel("Component type")
        let trc = NSPopUpButton(frame: .zero, pullsDown: false)
        trc.addItems(withTitles: trcContent.titles)
        trc.selectItem(at: trcContent.selected)
        trc.setAccessibilityLabel("Transfer curve")
        if let disabled = componentContent.disabled { component.item(at: disabled)?.isEnabled = false }
        if let disabled = trcContent.disabled { trc.item(at: disabled)?.isEnabled = false }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Component type:"), component],
            [NSTextField(labelWithString: "Transfer curve:"), trc],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Image Precision"
        alert.informativeText = "The current precision is \(document.info.precision). The conversion rewrites every layer's storage as one undo step, with no dithering."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard document.acceptsEdits else {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            let componentIndex = component.indexOfSelectedItem - (componentContent.disabled != nil ? 1 : 0)
            let trcIndex = trc.indexOfSelectedItem - (trcContent.disabled != nil ? 1 : 0)
            guard EngineSession.ColorComponent.conversionChoices.indices.contains(componentIndex),
                  EngineSession.ColorTRC.conversionChoices.indices.contains(trcIndex) else {
                document.onError?("Choose a component type and a transfer curve the image can convert to.")
                return
            }
            document.convertPrecision(
                component: EngineSession.ColorComponent.conversionChoices[componentIndex],
                trc: EngineSession.ColorTRC.conversionChoices[trcIndex]) { result in
                    if case .failure(let error) = result { document.onError?(error.localizedDescription) }
                }
        }
    }

    // MARK: Image Information

    /// The sheet's rows for the cached state: mode, precision, the
    /// effective profile and whether it is embedded in the image or the
    /// engine's builtin fallback. Unknowns report as themselves rather
    /// than pretending a value.
    static func informationRows(colorInfo: EngineSession.ColorInfo,
                                precision: String) -> [(label: String, value: String)] {
        var rows = [
            (label: "Mode", value: colorInfo.mode.title),
            (label: "Precision", value: precision.isEmpty ? "Unknown" : precision),
            (label: "Color profile", value: colorInfo.profileLabel.isEmpty ? "None" : colorInfo.profileLabel),
        ]
        if !colorInfo.profileLabel.isEmpty {
            rows.append((label: "Profile source",
                         value: colorInfo.hasEmbeddedProfile ? "Embedded in the image" : "Built-in default"))
        }
        return rows
    }

    /// Image ▸ Image Information…: a read-only sheet of the mode,
    /// precision and effective profile the document last saw — the same
    /// cache the window title and Mode checkmarks show.
    static func presentInformation(for document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let rows = informationRows(colorInfo: document.colorInfo, precision: document.info.precision)
        let grid = NSGridView(views: rows.map {
            [NSTextField(labelWithString: "\($0.label):"), NSTextField(labelWithString: $0.value)]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Image Information"
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
