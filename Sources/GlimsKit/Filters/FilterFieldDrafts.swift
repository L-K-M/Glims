import AppKit

/// Keep text entered since a form last displayed/submitted its settings while
/// an asynchronous reply refreshes the accepted values behind that text.
@MainActor
enum FilterFieldDrafts {
    static func preserve(_ fields: [(NSTextField, String)], during update: () -> Void) {
        let drafts = fields.compactMap { field, displayed -> (NSTextField, String, NSRange?)? in
            let editor = field.currentEditor()
            let text = editor?.string ?? field.stringValue
            guard text != displayed else { return nil }
            return (field, text, editor?.selectedRange)
        }
        update()
        for (field, text, selection) in drafts {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                if let selection, selection.location != NSNotFound {
                    let count = text.utf16.count
                    let location = min(selection.location, count)
                    editor.selectedRange = NSRange(location: location,
                        length: min(selection.length, count - location))
                }
            }
        }
    }
}
