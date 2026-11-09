import AppKit

/// The native input distribution, including signed weights from HDR alpha.
@MainActor
final class InputHistogramView: NSView {
    var histogram: EngineSession.InputHistogram? {
        didSet { contentDidChange() }
    }
    var channel: EngineSession.HistogramChannel = .value {
        didSet { contentDidChange() }
    }
    var logarithmic = false {
        didSet { contentDidChange() }
    }
    var message: String? = nil {
        didSet { contentDidChange() }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 480, height: 130) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    private var availableBins: [Double]? {
        guard let histogram, (0...4096).contains(histogram.binCount),
              let bins = histogram[channel], bins.count == histogram.binCount,
              bins.allSatisfy(\.isFinite) else { return nil }
        return bins
    }
    private var channelColor: NSColor {
        switch channel {
        case .red: return .systemRed
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .value, .alpha: return .labelColor
        case .luminance: return .secondaryLabelColor
        }
    }
    private func notice(for bins: [Double]?) -> String? {
        if let message, !message.isEmpty { return message }
        guard histogram != nil else { return "Loading histogram…" }
        guard let bins else { return "This channel is unavailable" }
        return bins.allSatisfy({ $0 == 0 }) ? "No weighted pixels" : nil
    }
    private func contentDidChange() {
        needsDisplay = true
        updateAccessibility()
    }
    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Input histogram")
        updateAccessibility()
    }
    private func updateAccessibility() {
        let bins = availableBins
        let mode = logarithmic ? "Logarithmic scale" : "Linear scale"
        var description = "\(channel.title), \(mode)"
        if let bins {
            description = "\(channel.title), \(bins.count) bins, weighted total \(weightedTotal(bins)), \(mode)"
        }
        if let notice = notice(for: bins) { description += ". \(notice)" }
        setAccessibilityValue(description)
    }
    private func weightedTotal(_ bins: [Double]) -> String {
        guard let scale = bins.map({ abs($0) }).max(), scale > 0 else { return "0" }
        // Scale first so large positive and negative weights can cancel
        // without overflowing an intermediate sum.
        let total = bins.reduce(0.0) { $0 + $1 / scale } * scale
        guard total.isFinite else { return "outside the numeric range" }
        return String(format: "%.6g", total)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let rect = bounds.insetBy(dx: 12, dy: 12)
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawGrid(in: rect)
        let bins = availableBins
        if let notice = notice(for: bins) { drawMessage(notice, in: rect) }
        else if let bins { drawBins(bins, in: rect) }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
    }
    private func drawGrid(in rect: NSRect) {
        let grid = NSBezierPath()
        for index in 0...4 {
            let fraction = CGFloat(index) / 4
            let x = rect.minX + fraction * rect.width
            let y = rect.minY + fraction * rect.height
            grid.move(to: NSPoint(x: x, y: rect.minY))
            grid.line(to: NSPoint(x: x, y: rect.maxY))
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        NSColor.separatorColor.setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }
    private func drawBins(_ bins: [Double], in rect: NSRect) {
        guard !bins.isEmpty else { return }
        let values = logarithmic ? bins.map { $0 < 0 ? -log1p(-$0) : log1p($0) } : bins
        let minimum = min(0, values.min() ?? 0)
        let maximum = max(0, values.max() ?? 0)
        let scale = max(-minimum, maximum)
        guard scale.isFinite, scale > 0 else { return }
        // Normalizing before subtracting keeps the signed range finite even
        // when its endpoints are near opposite Double limits.
        let low = minimum / scale
        let range = maximum / scale - low
        let baseline = rect.minY + CGFloat(-low / range) * rect.height
        let denominator = Double(max(values.count - 1, 1))
        let line = NSBezierPath()
        let area = NSBezierPath()
        area.move(to: NSPoint(x: rect.minX, y: baseline))
        var lastX = rect.minX
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(Double(index) / denominator) * rect.width
            let y = rect.minY + CGFloat((value / scale - low) / range) * rect.height
            let point = NSPoint(x: x, y: y)
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
            area.line(to: point)
            lastX = x
        }
        area.line(to: NSPoint(x: lastX, y: baseline))
        area.close()
        channelColor.withAlphaComponent(0.22).setFill()
        area.fill()
        channelColor.setStroke()
        line.lineWidth = 1
        line.stroke()

        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: rect.minX, y: baseline))
        zero.line(to: NSPoint(x: rect.maxX, y: baseline))
        NSColor.secondaryLabelColor.setStroke()
        zero.lineWidth = 0.75
        zero.stroke()
    }
    private func drawMessage(_ message: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        let width = max(0, rect.width - 12)
        let measured = text.boundingRect(with: NSSize(width: width, height: rect.height),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = min(rect.height, ceil(measured.height))
        text.draw(in: NSRect(x: rect.minX + 6, y: rect.midY - height / 2, width: width, height: height))
    }
}
