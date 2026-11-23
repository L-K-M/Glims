import AppKit

/// Filter ▸ Other ▸ Maximum… and Minimum…: Photoshop's rank filters over
/// GEGL's `gegl:median-blur`. Each channel takes the largest (Maximum) or
/// smallest (Minimum) value in the square of `radius` pixels around the
/// pixel, the square neighborhood Photoshop 4 used. Alpha follows the
/// same rank, so transparency spreads or shrinks like the color. High
/// precision keeps high-bit values exact instead of 256 bins.
@MainActor
final class RankFilterPanel: FilterPreviewPanel {
    enum Rank: CaseIterable {
        case maximum, minimum

        var title: String { self == .maximum ? "Maximum" : "Minimum" }
        /// GEGL's percentile for the rank: 100 is the largest value.
        var percentile: Double { self == .maximum ? 100 : 0 }
        /// The Last Filter history's discriminator between the two
        /// dedicated panels sharing `gegl:median-blur`.
        var variantTitle: String { title }

        init?(variantTitle: String) {
            switch variantTitle {
            case Rank.maximum.title: self = .maximum
            case Rank.minimum.title: self = .minimum
            default: return nil
            }
        }
    }

    nonisolated static let operation = "gegl:median-blur"
    nonisolated static let radiusRange = 1...100
    nonisolated static let defaultRadius = 1
    /// Every property the panel writes, so Last Filter snapshots the
    /// whole committed state of a rank filter by name.
    nonisolated static let captureNames = ["neighborhood", "percentile", "alpha-percentile",
                                           "abyss-policy", "high-precision", "radius"]

    let rank: Rank
    private let slider: NSSlider
    private let field = NSTextField()
    private(set) var appliedRadius = RankFilterPanel.defaultRadius

    /// The fixed settings every Maximum or Minimum preview starts with.
    static func fixedSettings(_ rank: Rank) -> [(String, EngineSession.FilterValue)] {
        [("neighborhood", .enumeration("square")),
         ("percentile", .number(rank.percentile)),
         ("alpha-percentile", .number(rank.percentile)),
         ("abyss-policy", .enumeration("clamp")),
         ("high-precision", .boolean(true))]
    }

    /// A radius typed into the field: a whole number of pixels in range.
    nonisolated static func radius(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              radiusRange.contains(value) else { return nil }
        return value
    }

    init(document imageDocument: ImageDocument, filter: Int32, rank: Rank, initialRadius: Int? = nil) {
        self.rank = rank
        let startRadius = initialRadius ?? Self.defaultRadius
        slider = NSSlider(value: Double(startRadius), minValue: Double(Self.radiusRange.lowerBound),
                          maxValue: Double(Self.radiusRange.upperBound), target: nil, action: nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = rank.title
        panel.isFloatingPanel = true
        super.init(document: imageDocument, panel: panel, filter: filter)
        buildContent(in: panel)
        let settings = Self.fixedSettings(rank)
        _ = imageDocument.run(effect: .changesPreview) { session, _ in
            for (name, value) in settings { try session.setFilterProperty(filter, name, to: value) }
        }
        apply(radius: startRadius)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in panel: NSPanel) {
        let label = NSTextField(labelWithString: "Radius:")
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.setAccessibilityLabel("\(rank.title) radius")
        field.integerValue = slider.integerValue
        field.target = self
        field.action = #selector(fieldChanged)
        field.setAccessibilityLabel("\(rank.title) radius in pixels")
        let unit = NSTextField(labelWithString: "pixels")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(commit))
        ok.keyEquivalent = "\r"

        let row = NSStackView(views: [label, slider, field, unit])
        row.spacing = 8
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
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
        let radius = Int(slider.doubleValue.rounded())
        field.integerValue = radius
        apply(radius: radius)
    }

    @objc private func fieldChanged() {
        guard let radius = Self.radius(field.stringValue) else {
            field.integerValue = appliedRadius
            NSSound.beep()
            return
        }
        slider.doubleValue = Double(radius)
        apply(radius: radius)
    }

    func apply(radius: Int) {
        guard let filter, Self.radiusRange.contains(radius) else { return }
        let accepted = imageDocument.run(effect: .changesPreview) { session, _ in
            try session.setFilterProperty(filter, "radius", to: .integer(Int64(radius)))
        }
        if accepted {
            appliedRadius = radius
        } else {
            slider.doubleValue = Double(appliedRadius)
            field.integerValue = appliedRadius
        }
    }
}
