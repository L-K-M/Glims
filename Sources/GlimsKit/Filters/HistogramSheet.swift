import AppKit

/// Image ▸ Histogram… statistics for one channel's bins. Mean, standard
/// deviation and median follow GIMP's `gimp_histogram_get_mean`,
/// `_get_std_dev` and `_get_median` (core/gimphistogram.c), rescaled from
/// GIMP's 0…1 bin fractions to Photoshop's 0…255 levels. Pixels is the
/// selection- and alpha-weighted total, as in GIMP's Histogram dockable.
struct HistogramStatistics: Equatable {
    let pixels: Double
    let mean: Double
    let standardDeviation: Double
    /// nil when the weighted total is not positive.
    let median: Double?

    init(bins: [Double]) {
        let step = Self.levelStep(binCount: bins.count)
        let pixels = bins.reduce(0, +)
        var weighted = 0.0
        for (index, value) in bins.enumerated() { weighted += Double(index) * step * value }
        let mean = pixels > 0 ? weighted / pixels : weighted
        var deviation = 0.0
        for (index, value) in bins.enumerated() {
            let distance = Double(index) * step - mean
            deviation += value * distance * distance
        }
        var median: Double?
        var running = 0.0
        for (index, value) in bins.enumerated() {
            running += value
            if running * 2 > pixels { median = Double(index) * step; break }
        }
        self.pixels = pixels
        self.mean = mean
        self.standardDeviation = (deviation / (pixels == 0 ? 1 : pixels)).squareRoot()
        self.median = pixels > 0 ? median : nil
    }

    /// The 0…255 level of `bin` when there are `binCount` bins.
    static func level(ofBin bin: Int, binCount: Int) -> Double {
        Double(bin) * levelStep(binCount: binCount)
    }

    private static func levelStep(binCount: Int) -> Double {
        binCount > 1 ? 255 / Double(binCount - 1) : 0
    }

    /// Photoshop's pointer readout: the bin's level, its weighted count and
    /// the percentage of the total at or below it.
    struct Probe: Equatable {
        let level: Double
        let count: Double
        let percentile: Double
    }

    static func probe(_ bins: [Double], bin: Int) -> Probe? {
        guard bins.indices.contains(bin) else { return nil }
        let total = bins.reduce(0, +)
        let below = bins[...bin].reduce(0, +)
        return Probe(level: level(ofBin: bin, binCount: bins.count), count: bins[bin],
                     percentile: total > 0 ? 100 * below / total : 0)
    }

    /// The bin under horizontal position `x` of a plot spanning
    /// `minX`…`minX + width`, matching InputHistogramView's drawing.
    static func bin(atX x: CGFloat, minX: CGFloat, width: CGFloat, binCount: Int) -> Int? {
        guard binCount > 0, width > 0, x.isFinite else { return nil }
        let fraction = (x - minX) / width
        guard fraction >= 0, fraction <= 1 else { return nil }
        return min(binCount - 1, Int((fraction * CGFloat(binCount - 1)).rounded()))
    }

    static func formatLevel(_ level: Double, binCount: Int) -> String {
        binCount == 256 ? String(Int(level.rounded())) : String(format: "%.1f", level)
    }

    static func formatCount(_ count: Double) -> String {
        guard count.isFinite else { return "—" }
        if count == count.rounded(), abs(count) < 1e15 {
            return NumberFormatter.localizedString(from: NSNumber(value: Int64(count)), number: .decimal)
        }
        return String(format: "%.1f", count)
    }
}

/// Image ▸ Histogram…: a read-only sheet like Photoshop's, over GIMP's
/// histogram of the active layer, mask or channel.
@MainActor
enum HistogramSheet {
    /// Channels in Photoshop's popup order, limited to those present.
    static func channels(of histogram: EngineSession.InputHistogram) -> [EngineSession.HistogramChannel] {
        [.luminance, .red, .green, .blue, .value, .alpha].filter { histogram[$0] != nil }
    }

    static func present(for document: ImageDocument, on window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let subject = document.histogramSubject
        document.readHistogram { [weak window] result in
            guard let window, window.attachedSheet == nil else { return }
            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "The histogram could not be read."
                alert.informativeText = (error as? EngineSession.EngineError)?.message ?? error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            case .success(let histogram):
                let controller = HistogramSheetController(histogram: histogram, subject: subject)
                let alert = NSAlert()
                alert.messageText = "Histogram"
                alert.accessoryView = controller.view
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { _ in withExtendedLifetime(controller) {} }
            }
        }
    }
}

@MainActor
final class HistogramSheetController: NSObject {
    let histogram: EngineSession.InputHistogram
    let view: NSView
    private let plot = InputHistogramView(frame: NSRect(x: 0, y: 0, width: 384, height: 150))
    private let popup = NSPopUpButton()
    private let channels: [EngineSession.HistogramChannel]
    private var values: [String: NSTextField] = [:]

    init(histogram: EngineSession.InputHistogram, subject: String) {
        self.histogram = histogram
        channels = HistogramSheet.channels(of: histogram)
        let stack = NSStackView()
        view = stack
        super.init()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let caption = NSTextField(labelWithString: subject)
        caption.textColor = .secondaryLabelColor
        popup.addItems(withTitles: channels.map(\.title))
        popup.target = self
        popup.action = #selector(channelChanged(_:))
        popup.setAccessibilityLabel("Channel")
        let channelRow = NSStackView(views: [NSTextField(labelWithString: "Channel:"), popup])
        plot.histogram = histogram
        plot.translatesAutoresizingMaskIntoConstraints = false
        plot.widthAnchor.constraint(equalToConstant: 384).isActive = true
        plot.heightAnchor.constraint(equalToConstant: 150).isActive = true
        plot.onHoverBin = { [weak self] bin in self?.showProbe(bin) }

        func label(_ key: String) -> NSTextField {
            let field = NSTextField(labelWithString: "—")
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values[key] = field
            return field
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Mean:"), label("mean"), NSTextField(labelWithString: "Level:"), label("level")],
            [NSTextField(labelWithString: "Std Dev:"), label("std"), NSTextField(labelWithString: "Count:"), label("count")],
            [NSTextField(labelWithString: "Median:"), label("median"), NSTextField(labelWithString: "Percentile:"), label("percentile")],
            [NSTextField(labelWithString: "Pixels:"), label("pixels"), NSView(), NSView()],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 1).width = 110
        grid.columnSpacing = 8
        grid.rowSpacing = 6
        let hint = NSTextField(labelWithString: "Point at the histogram for a level's count and percentile.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for subview in [caption, channelRow, plot, grid, hint] { stack.addArrangedSubview(subview) }
        stack.setFrameSize(stack.fittingSize)
        select(channels.first ?? .value)
    }

    var selectedChannel: EngineSession.HistogramChannel { plot.channel }

    func select(_ channel: EngineSession.HistogramChannel) {
        guard let index = channels.firstIndex(of: channel) else { return }
        popup.selectItem(at: index)
        plot.channel = channel
        let bins = histogram[channel] ?? []
        let statistics = HistogramStatistics(bins: bins)
        values["mean"]?.stringValue = bins.isEmpty ? "—" : String(format: "%.2f", statistics.mean)
        values["std"]?.stringValue = bins.isEmpty ? "—" : String(format: "%.2f", statistics.standardDeviation)
        values["median"]?.stringValue = statistics.median.map {
            HistogramStatistics.formatLevel($0, binCount: bins.count)
        } ?? "—"
        values["pixels"]?.stringValue = HistogramStatistics.formatCount(statistics.pixels)
        showProbe(nil)
    }

    func readout(_ key: String) -> String? { values[key]?.stringValue }

    func showProbe(_ bin: Int?) {
        let bins = histogram[plot.channel] ?? []
        guard let bin, let probe = HistogramStatistics.probe(bins, bin: bin) else {
            for key in ["level", "count", "percentile"] { values[key]?.stringValue = "—" }
            return
        }
        values["level"]?.stringValue = HistogramStatistics.formatLevel(probe.level, binCount: bins.count)
        values["count"]?.stringValue = HistogramStatistics.formatCount(probe.count)
        values["percentile"]?.stringValue = String(format: "%.1f", probe.percentile)
    }

    @objc private func channelChanged(_ sender: NSPopUpButton) {
        guard channels.indices.contains(sender.indexOfSelectedItem) else { return }
        select(channels[sender.indexOfSelectedItem])
    }
}
