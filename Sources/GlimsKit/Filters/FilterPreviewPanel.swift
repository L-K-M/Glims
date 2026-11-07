import AppKit

/// The lifecycle every modeless filter dialog shares.
///
/// Opening the panel starts an engine filter session on the active
/// layer; the subclass's controls update the live preview; Apply commits
/// the filter as one non-destructive undo step; Cancel or closing the
/// window aborts it and leaves no trace (design.md, principle 7). A
/// refused commit keeps the session — and the panel — available, so the
/// user can still cancel.
@MainActor
class FilterPreviewPanel: NSWindowController {
    let imageDocument: ImageDocument
    /// The open filter session; `nil` once it committed or aborted.
    private(set) var filter: Int32?
    private var finished = false
    private var committing = false
    var onFinish: (() -> Void)?

    init(document imageDocument: ImageDocument, panel: NSPanel) {
        self.imageDocument = imageDocument
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Starts the engine filter session for `operation` on the active
    /// layer. The subclass calls it during initialization and fails its
    /// own init when the engine cannot begin the session.
    @discardableResult
    func beginSession(_ operation: String) -> Bool {
        guard let layer = imageDocument.activeLayer,
              let filter = try? imageDocument.session.beginFilter(image: imageDocument.image,
                                                                  drawable: layer, operation: operation) else { return false }
        self.filter = filter
        return true
    }

    /// A refusal the document reported while the panel is open; the
    /// status bar shows it by default, the generic form also displays it.
    func showError(_ message: String) {}

    @objc func commit() {
        finish(commit: true)
    }

    @objc func cancel() {
        finish(commit: false)
    }

    private func finish(commit: Bool) {
        guard !finished, let filter else { return }
        if commit {
            guard !committing else { return }
            committing = true
            imageDocument.finishFilter(filter, commit: true) { [self] success in
                committing = false
                guard success, !finished else { return }
                finished = true
                self.filter = nil
                window?.orderOut(nil)
                onFinish?()
            }
        } else {
            // Cancel may arrive while an accepted commit is still queued.
            // The serial queue then either aborts it or finds it committed.
            finished = true
            self.filter = nil
            imageDocument.finishFilter(filter, commit: false) { _ in }
            window?.orderOut(nil)
            onFinish?()
        }
    }
}

extension FilterPreviewPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(commit: false)
    }
}
