import AppKit

/// Layer > Matting > Defringe: a sheet asking for the halo width in
/// pixels. OK applies the matting to the document's active layer; the
/// command is layer-wide and ignores the selection.
@MainActor
enum DefringeForm {
    static func present(in document: ImageDocument, on window: NSWindow) {
        let slider = NSSlider(value: 1, minValue: 1, maxValue: 200, target: nil, action: nil)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Width")
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let field = NSTextField(string: "1")
        field.setAccessibilityLabel("Defringe width in pixels")
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let sync = DefringeFormSync(slider: slider, field: field)
        slider.target = sync
        slider.action = #selector(DefringeFormSync.sliderChanged(_:))
        field.target = sync
        field.action = #selector(DefringeFormSync.fieldChanged(_:))

        let row = NSStackView(views: [NSTextField(labelWithString: "Width:"), slider, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.setFrameSize(row.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Defringe"
        alert.informativeText = "Give partially transparent edge pixels the color of the nearest fully opaque pixel within this many pixels."
        alert.accessoryView = row
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [sync, weak sheetWindow = alert.window] response in
            sheetWindow?.endEditing(for: nil)
            _ = sync
            guard response == .alertFirstButtonReturn else { return }
            guard let width = DefringeForm.widthValue(field.stringValue) else {
                document.onError?("Enter a width from 1 to 200 pixels.")
                return
            }
            document.applyMatting(.defringe, width: width)
        }
    }

    /// A Defringe width typed into the sheet: a whole number 1 ... 200.
    nonisolated static func widthValue(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...200).contains(value) else { return nil }
        return value
    }
}

@MainActor
final class DefringeFormSync: NSObject {
    weak var slider: NSSlider?
    weak var field: NSTextField?

    init(slider: NSSlider, field: NSTextField) {
        self.slider = slider
        self.field = field
        super.init()
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        field?.stringValue = String(Int(sender.doubleValue.rounded()))
    }

    @objc func fieldChanged(_ sender: NSTextField) {
        guard let value = DefringeForm.widthValue(sender.stringValue) else { return }
        slider?.doubleValue = Double(value)
    }
}
