import AppKit

/// Sheets capture the document and channel when they open. A palette
/// retarget cannot send an attribute edit to a different image.
@MainActor
enum ChannelForms {
    static func saveSelection(in document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil else { return }
        let name = NSTextField(string: "Selection")
        name.setAccessibilityLabel("Channel name")
        name.setFrameSize(NSSize(width: 300, height: 24))
        let alert = NSAlert()
        alert.messageText = "Save Selection as Channel"
        alert.informativeText = "The channel stores the current selection. Paint on it to edit the saved area."
        alert.accessoryView = name
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, document.acceptsEdits else { return }
            guard let value = validName(name.stringValue) else {
                document.onError?("Enter a channel name; shorten it if the name is too long.")
                return
            }
            document.saveSelectionToChannel(name: value)
        }
    }

    static func edit(_ id: Int32, in document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil,
              let row = document.channels.first(where: { $0.id == id }) else { return }
        let name = NSTextField(string: row.name)
        name.isEnabled = !row.isQuickMask
        name.setAccessibilityLabel("Channel name")
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        color.color = row.color.withAlphaComponent(1)
        color.setAccessibilityLabel("Overlay color")
        let opacity = NSTextField(string: NumberFormatter.localizedString(from: NSNumber(value: row.opacity * 100), number: .decimal))
        opacity.setAccessibilityLabel("Overlay opacity, percent")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "Overlay color:"), color],
            [NSTextField(labelWithString: "Opacity (%):"), opacity],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.setFrameSize(grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = row.isQuickMask ? "Quick Mask Attributes" : "Channel Attributes"
        alert.informativeText = "The overlay marks the masked-out area. Opacity changes its display, not the channel pixels."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = row.isQuickMask ? opacity : name
        alert.beginSheetModal(for: window) { response in
            color.deactivate()
            guard response == .alertFirstButtonReturn, document.acceptsEdits else { return }
            guard document.channels.contains(where: { $0.id == id }) else {
                document.onError?("The channel was removed. Choose another channel.")
                return
            }
            guard let value = validName(name.stringValue),
                  let alpha = opacityValue(opacity.stringValue) else {
                document.onError?("Enter a channel name and an opacity from 0 to 100%; shorten very long names.")
                return
            }
            document.changeChannel(id, .init(name: row.isQuickMask ? nil : value,
                                             opacity: alpha, color: color.color.withAlphaComponent(alpha)))
        }
    }

    static func validName(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255, !value.contains("\0") else { return nil }
        return value
    }

    static func opacityValue(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        // Require a complete, locale-aware number; NumberFormatter's
        // number(from:) alone accepts a numeric prefix before junk.
        var value: AnyObject?
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard !trimmed.isEmpty,
              (try? formatter.getObjectValue(&value, for: trimmed, range: &range)) != nil,
              range.location == 0, range.length == (trimmed as NSString).length,
              let number = value as? NSNumber else { return nil }
        let percentage = number.doubleValue
        guard percentage.isFinite, (0...100).contains(percentage) else { return nil }
        return percentage / 100
    }
}
