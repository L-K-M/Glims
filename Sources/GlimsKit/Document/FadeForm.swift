import AppKit

/// Filter ▸ Fade: Photoshop's blend of the last filter's result with the
/// layer as it was before, as a sheet with an opacity slider and field.
/// The filter stays a non-destructive effect, so the fade is its
/// opacity; the target is captured when the sheet opens, and a history
/// change before OK is refused rather than redirected.
@MainActor
enum FadeForm {
    static func present(in document: ImageDocument, target: ImageDocument.FadeTarget, on window: NSWindow) {
        let start = (document.fadeOpacity(target) ?? 1) * 100
        let slider = NSSlider(value: start, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Opacity")
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let field = NSTextField(string: String(Int(start.rounded())))
        field.setAccessibilityLabel("Fade opacity, percent")
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let sync = FadeFormSync(slider: slider, field: field)
        slider.target = sync
        slider.action = #selector(FadeFormSync.sliderChanged(_:))
        field.target = sync
        field.action = #selector(FadeFormSync.fieldChanged(_:))

        let row = NSStackView(views: [NSTextField(labelWithString: "Opacity (%):"), slider, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.setFrameSize(row.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Fade \(target.title)"
        alert.informativeText = "Blend the filter's result with the layer as it was before the filter."
        alert.accessoryView = row
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [sync, weak sheetWindow = alert.window] response in
            sheetWindow?.endEditing(for: nil)
            _ = sync
            guard response == .alertFirstButtonReturn else { return }
            guard let opacity = ChannelForms.opacityValue(field.stringValue) else {
                document.onError?("Enter an opacity from 0 to 100%.")
                return
            }
            document.fade(target, opacity: opacity)
        }
    }
}

@MainActor
final class FadeFormSync: NSObject {
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
        guard let value = ChannelForms.opacityValue(sender.stringValue) else { return }
        slider?.doubleValue = value * 100
    }
}
