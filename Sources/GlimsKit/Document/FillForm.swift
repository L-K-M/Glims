import AppKit

/// The native Edit ▸ Fill… sheet: a fill source (foreground, background,
/// white, black or a custom color) and an opacity from 0 to 100 %. The
/// document is captured when the sheet opens; a retarget cannot redirect
/// the fill.
@MainActor
enum FillForm {
    static func present(in document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil else {
            if !document.acceptsEdits {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
            }
            return
        }

        let choice = NSPopUpButton(frame: .zero, pullsDown: false)
        choice.addItems(withTitles: ["Foreground Color", "Background Color", "White", "Black", "Custom"])
        choice.setAccessibilityLabel("Fill with")

        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        colorWell.color = ToolState.shared.foreground
        colorWell.setAccessibilityLabel("Fill color")
        colorWell.isEnabled = false

        let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
        opacitySlider.isContinuous = true
        opacitySlider.setAccessibilityLabel("Opacity")
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let opacityField = NSTextField(string: "100")
        opacityField.setAccessibilityLabel("Fill opacity, percent")
        opacityField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let sync = FillFormSync(choice: choice, colorWell: colorWell,
                               slider: opacitySlider, field: opacityField)
        choice.target = sync
        choice.action = #selector(FillFormSync.choiceChanged(_:))
        opacitySlider.target = sync
        opacitySlider.action = #selector(FillFormSync.sliderChanged(_:))
        opacityField.target = sync
        opacityField.action = #selector(FillFormSync.fieldChanged(_:))

        let opacityStack = NSStackView(views: [opacitySlider, opacityField])
        opacityStack.orientation = .horizontal
        opacityStack.spacing = 8
        opacityStack.alignment = .centerY

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Fill with:"), choice],
            [NSTextField(labelWithString: "Color:"), colorWell],
            [NSTextField(labelWithString: "Opacity (%):"), opacityStack],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        choice.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Fill"
        alert.informativeText = "Fill the selected area. Without a selection, fill the active layer, mask or channel."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = choice

        let colorPanelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        alert.beginSheetModal(for: window) { [sync, weak sheetWindow = alert.window] response in
            sheetWindow?.endEditing(for: nil)
            if colorWell.isActive && !colorPanelWasVisible { NSColorPanel.shared.orderOut(nil) }
            sync.colorWell?.deactivate()
            guard response == .alertFirstButtonReturn else { return }
            guard document.acceptsEdits else {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            guard let opacity = ChannelForms.opacityValue(opacityField.stringValue) else {
                document.onError?("Enter an opacity from 0 to 100%.")
                return
            }
            let color: NSColor
            switch choice.indexOfSelectedItem {
            case 0: color = ToolState.shared.foreground
            case 1: color = ToolState.shared.background
            case 2: color = .white
            case 3: color = .black
            default: color = colorWell.color
            }
            document.fill(at: .zero, mode: .selection, color: color,
                          threshold: 0, sampleMerged: false, opacity: opacity)
        }
    }
}

@MainActor
private final class FillFormSync: NSObject {
    weak var choice: NSPopUpButton?
    weak var colorWell: NSColorWell?
    weak var slider: NSSlider?
    weak var field: NSTextField?

    init(choice: NSPopUpButton, colorWell: NSColorWell, slider: NSSlider, field: NSTextField) {
        self.choice = choice
        self.colorWell = colorWell
        self.slider = slider
        self.field = field
        super.init()
    }

    @objc func choiceChanged(_ sender: NSPopUpButton) {
        let custom = sender.indexOfSelectedItem == 4
        colorWell?.isEnabled = custom
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        field?.stringValue = String(Int(sender.doubleValue.rounded()))
    }

    @objc func fieldChanged(_ sender: NSTextField) {
        guard let value = ChannelForms.opacityValue(sender.stringValue) else { return }
        slider?.doubleValue = value * 100
    }
}
