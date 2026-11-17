import AppKit

/// Image ▸ Duplicate's sheet content: Photoshop's "As" name and Merged
/// Layers Only. The option is shown only where the engine can make a
/// merged copy and, as in Photoshop, dimmed for a single-layer image.
@MainActor
struct DuplicateImageForm {
    let name: NSTextField
    let merged: NSButton
    let view: NSGridView

    init(name defaultName: String, offersMerged: Bool, layerCount: Int) {
        name = NSTextField(string: defaultName)
        name.setAccessibilityLabel("Duplicate name")
        merged = NSButton(checkboxWithTitle: "Merged Layers Only", target: nil, action: nil)
        merged.isEnabled = offersMerged && layerCount > 1
        view = NSGridView(views: [
            [NSTextField(labelWithString: "As:"), name],
            [NSGridCell.emptyContentView, merged],
        ])
        view.column(at: 0).xPlacement = .trailing
        view.row(at: 1).isHidden = !offersMerged
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        view.frame = NSRect(x: 0, y: 0, width: 280, height: offersMerged ? 56 : 26)
    }

    var offersMerged: Bool { !view.row(at: 1).isHidden }

    var mergedLayersOnly: Bool { offersMerged && merged.isEnabled && merged.state == .on }
}
