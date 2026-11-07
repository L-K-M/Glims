import AppKit

/// The native Add Layer Mask sheet: the six mask sources the engine
/// supports and the "Edit Mask Immediately" checkbox. The layer is
/// captured when the sheet opens, so a selection change while it is up
/// cannot redirect the mask onto another layer.
@MainActor
enum AddMaskForm {
    static func present(for document: ImageDocument, on window: NSWindow) {
        guard let layerID = document.activeLayer,
              let layer = document.layers.first(where: { $0.id == layerID }),
              !layer.hasMask else { return }

        let source = NSPopUpButton(frame: .zero, pullsDown: false)
        source.addItems(withTitles: EngineSession.MaskSource.allCases.map(\.title))
        source.setAccessibilityLabel("Initialize mask to")
        let edit = NSButton(checkboxWithTitle: "Edit Mask Immediately", target: nil, action: nil)
        // GIMP's layer-add-mask-edit-mask preference defaults to on.
        edit.state = .on
        edit.setAccessibilityLabel("Edit Mask Immediately")

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Add a mask to \u{201C}\(layer.name)\u{201D}?"),
            NSTextField(labelWithString: "Initialize mask to:"),
            source,
            edit,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let alert = NSAlert()
        alert.messageText = "Add Layer Mask"
        alert.accessoryView = content
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = source
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let picked = EngineSession.MaskSource.allCases.indices.contains(source.indexOfSelectedItem)
                ? EngineSession.MaskSource.allCases[source.indexOfSelectedItem] : .white
            document.addMask(layerID, source: picked, edit: edit.state == .on)
        }
    }
}
