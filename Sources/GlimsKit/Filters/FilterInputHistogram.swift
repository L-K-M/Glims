import AppKit

/// Shares a captured preview's input read between the adjustment forms.
/// A transfer-curve change invalidates outstanding replies; only a histogram
/// computed with the wanted transfer curve may become visible.
@MainActor
final class FilterInputHistogram {
    let view: InputHistogramView
    private weak var document: ImageDocument?
    private let filter: Int32
    private let isActive: () -> Bool
    private var trc: EngineSession.ColorTRC?
    private var generation = 0
    private var loading = false

    init(document: ImageDocument, filter: Int32, view: InputHistogramView,
         isActive: @escaping () -> Bool) {
        self.document = document
        self.filter = filter
        self.view = view
        self.isActive = isActive
    }
    func show(channel: EngineSession.HistogramChannel, trc: EngineSession.ColorTRC) {
        view.channel = channel
        guard self.trc != trc else { return }
        self.trc = trc
        generation += 1
        loading = false
        view.histogram = nil
        view.message = "Waiting for transfer curve…"
    }
    func refreshIfNeeded() {
        guard view.histogram == nil, !loading else { return }
        refresh()
    }
    func refresh() {
        guard isActive(), let document, let trc else { return }
        generation += 1
        let request = generation
        loading = true
        view.histogram = nil
        view.message = nil
        document.loadInputHistogram(filter) { [weak self] result in
            guard let self, self.isActive(), self.generation == request else { return }
            self.loading = false
            switch result {
            case .success(let histogram):
                guard histogram.trc == trc, self.trc == trc else {
                    self.view.message = "Waiting for transfer curve…"
                    return
                }
                self.view.histogram = histogram
                self.view.message = nil
            case .failure(let error):
                self.view.message = error.localizedDescription
            }
        }
    }
}
