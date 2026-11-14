import AppKit

private let opacityValidationMessage = "Enter an opacity from 0 to 100%."

@MainActor
enum LayeredLabFillForm {
    static func present(in document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        document.prepareLabLayerColorFill { [weak window] result in
            guard let window, !document.isClosing else { return }
            switch result {
            case .failure(let error): document.onError?(error.localizedDescription)
            case .success(let target):
                guard window.attachedSheet == nil else { return }
                show(target: target, document: document, window: window)
            }
        }
    }

    private static func show(target: EngineSession.LabLayerFillTarget,
                             document: ImageDocument, window: NSWindow) {
        let choice = NSPopUpButton(frame: .zero, pullsDown: false)
        choice.addItems(withTitles: ["Foreground Color", "Background Color", "White", "Black", "Custom"])
        choice.setAccessibilityLabel("Fill with")
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        well.color = ToolState.shared.foreground
        well.setAccessibilityLabel("Fill color")
        well.isEnabled = false
        let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Opacity")
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let field = NSTextField(string: "100")
        field.setAccessibilityLabel("Fill opacity, percent")
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let sync = FillFormSync(choice: choice, colorWell: well, slider: slider, field: field)
        choice.target = sync; choice.action = #selector(FillFormSync.choiceChanged(_:))
        slider.target = sync; slider.action = #selector(FillFormSync.sliderChanged(_:))
        field.target = sync; field.action = #selector(FillFormSync.fieldChanged(_:))
        let opacity = NSStackView(views: [slider, field])
        opacity.orientation = .horizontal; opacity.spacing = 8; opacity.alignment = .centerY
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Fill with:"), choice],
                                     [NSTextField(labelWithString: "Color:"), well],
                                     [NSTextField(labelWithString: "Opacity (%):"), opacity]])
        grid.rowSpacing = 8; grid.columnSpacing = 12
        choice.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let validation = NSTextField(labelWithString: opacityValidationMessage)
        validation.textColor = .systemRed
        validation.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        let content = NSStackView(views: [grid, validation])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setFrameSize(content.fittingSize)
        validation.stringValue = ""
        let alert = NSAlert()
        alert.messageText = "Fill"
        alert.informativeText = "Fill the selection, or the entire active layer if there is no selection."
        alert.accessoryView = content
        let submit = alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        let submitHandler = LayeredLabFillSubmit(parent: window, sheet: alert.window,
                                                 field: field, validation: validation)
        submit.target = submitHandler
        submit.action = #selector(LayeredLabFillSubmit.submit(_:))
        alert.window.initialFirstResponder = choice
        let panelWasVisible = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        alert.beginSheetModal(for: window) { [sync, submitHandler, weak sheetWindow = alert.window] response in
            _ = submitHandler // NSControl's target is weak; retain it for the sheet's lifetime.
            sheetWindow?.endEditing(for: nil)
            if well.isActive && !panelWasVisible { NSColorPanel.shared.orderOut(nil) }
            sync.colorWell?.deactivate()
            guard response == .alertFirstButtonReturn else { return }
            guard let value = ChannelForms.opacityValue(field.stringValue) else {
                document.onError?("Enter an opacity from 0 to 100%.")
                return
            }
            let selectedColor: NSColor
            switch choice.indexOfSelectedItem {
            case 0: selectedColor = ToolState.shared.foreground
            case 1: selectedColor = ToolState.shared.background
            case 2: selectedColor = .white
            case 3: selectedColor = .black
            default: selectedColor = well.color
            }
            do {
                let color = try EngineSession.labLayerFillColor(selectedColor)
                document.fillLabLayer(target, color: color, opacity: value)
            } catch { document.onError?(error.localizedDescription) }
        }
    }
}

@MainActor
private final class LayeredLabFillSubmit: NSObject {
    private weak var parent: NSWindow?
    private weak var sheet: NSWindow?
    private weak var field: NSTextField?
    private weak var validation: NSTextField?

    init(parent: NSWindow, sheet: NSWindow, field: NSTextField, validation: NSTextField) {
        self.parent = parent
        self.sheet = sheet
        self.field = field
        self.validation = validation
    }

    @objc func submit(_ sender: Any?) {
        guard let parent, let sheet, let field, parent.attachedSheet === sheet else { return }
        sheet.endEditing(for: nil)
        guard ChannelForms.opacityValue(field.stringValue) != nil else {
            validation?.stringValue = opacityValidationMessage
            sheet.makeFirstResponder(field)
            NSSound.beep()
            NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                                 userInfo: [.announcement: opacityValidationMessage,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        parent.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
}
