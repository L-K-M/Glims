import AppKit

/// Shared copy for batch layer-source confirmations. The caller owns sheet
/// lifetime, capture, revalidation and the actual document action.
enum LayerRestoreSheet {
    static func makeAlert(names: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Restore \(names.count) Layer Sources?"
        let shownNames = names.prefix(3).map { name -> String in
            let displayed = name.count > 80 ? String(name.prefix(80)) + "…" : name
            return "\u{201C}\(displayed)\u{201D}"
        }.joined(separator: ", ")
        let remaining = names.count > 3 ? " and \(names.count - 3) more layers" : ""
        alert.informativeText = shownNames + remaining + ".\n\n"
            + "The selected layers' pixel edits are discarded and their retained text, link or vector sources are regenerated, as one Undo step. "
            + "Linked layers use the current readable file content, or the retained fallback when the file cannot be read. "
            + "Regeneration may resize or reposition layers and their masks. "
            + "Undo brings the previous pixels back."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.forEach { $0.setAccessibilityLabel($0.title) }
        return alert
    }
}
