import AppKit

/// The lifecycle every modeless filter dialog shares.
///
/// The window controller begins an engine filter session behind pending
/// input and constructs the panel with it; the subclass's controls
/// update the live preview; Apply commits the filter as one
/// non-destructive undo step; Cancel or closing the window aborts it and
/// leaves no trace (design.md, principle 7). A refused commit keeps the
/// session — and the panel — available, so the user can still cancel.
@MainActor
class FilterPreviewPanel: NSWindowController {
    let imageDocument: ImageDocument
    /// The open filter session; `nil` once it committed or aborted.
    private(set) var filter: Int32?
    private var finished = false
    private var committing = false
    var onFinish: (() -> Void)?

    /// The session the panel previews and finishes. It is begun on the
    /// document's input queue by `ImageDocument.beginFilterPreview`, so
    /// the session never overtakes input still on its way to the engine;
    /// the window's pending-start gate decides who may construct one.
    init(document imageDocument: ImageDocument, panel: NSPanel, filter: Int32) {
        self.imageDocument = imageDocument
        self.filter = filter
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
