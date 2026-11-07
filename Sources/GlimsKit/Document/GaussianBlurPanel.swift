import AppKit

/// A modeless Gaussian Blur dialog with live preview on the canvas.
///
/// Opening it starts an engine filter session on the active layer; moving
/// the slider updates the preview; OK commits the filter as one
/// non-destructive undo step; Cancel or closing the window aborts it and
/// leaves no trace (design.md, principle 7).
@MainActor
final class GaussianBlurPanel: FilterPreviewPanel {
    nonisolated static let operation = "gegl:gaussian-blur"
    static let maximumRadius = 100.0

    private let slider = NSSlider(value: 4, minValue: 0, maxValue: maximumRadius, target: nil, action: nil)
    private let field = NSTextField()
    private var appliedRadius = 4.0

    init(document imageDocument: ImageDocument, filter: Int32) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Gaussian Blur"
        panel.isFloatingPanel = true
        super.init(document: imageDocument, panel: panel, filter: filter)
        buildContent(in: panel)
        apply(radius: slider.doubleValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in panel: NSPanel) {
        let label = NSTextField(labelWithString: "Radius:")
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Blur radius")
        field.doubleValue = slider.doubleValue
        field.formatter = { let f = NumberFormatter(); f.minimum = 0; f.maximum = NSNumber(value: Self.maximumRadius); f.maximumFractionDigits = 1; return f }()
        field.target = self
        field.action = #selector(fieldChanged)
        field.setAccessibilityLabel("Blur radius in pixels")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(commit))
        ok.keyEquivalent = "\r"

        let row = NSStackView(views: [label, slider, field])
        row.spacing = 8
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let buttons = NSStackView(views: [cancel, ok])
        buttons.spacing = 8
        let stack = NSStackView(views: [row, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    @objc private func sliderChanged() {
        field.doubleValue = slider.doubleValue
        apply(radius: slider.doubleValue)
    }

    @objc private func fieldChanged() {
        slider.doubleValue = field.doubleValue
        apply(radius: field.doubleValue)
    }

    func apply(radius: Double) {
        guard let filter else { return }
        let accepted = imageDocument.run(effect: .changesPreview) { session, _ in
            try session.setFilter(filter, "std-dev-x", to: radius)
            try session.setFilter(filter, "std-dev-y", to: radius)
        }
        if accepted {
            appliedRadius = radius
        } else {
            slider.doubleValue = appliedRadius
            field.doubleValue = appliedRadius
        }
    }
}
