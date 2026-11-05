import AppKit

/// Progress of a running plug-in command, with a Stop button, shown in the
/// document's status strip left of the zoom control.
///
/// Rigi's `StatusBarView` has no accessory slot yet; docs/design.md plans
/// one ("Extend Rigi: … progress"). Until then this view sits on top of the
/// strip at a fixed distance from its trailing edge.
@MainActor
final class PlugInProgressView: NSView {
    /// Room the status strip's zoom control takes at its trailing edge.
    static let zoomControlAllowance: CGFloat = 100

    var onStop: (() -> Void)?

    private let indicator = NSProgressIndicator()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        indicator.style = .bar
        indicator.controlSize = .small
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop the running command"
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stopButton)

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 120),
            stopButton.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows determinate or indeterminate progress, or hides with nil.
    func show(_ progress: EngineSession.Progress?) {
        guard let progress else {
            indicator.stopAnimation(nil)
            isHidden = true
            return
        }
        isHidden = false
        if let fraction = progress.fraction {
            indicator.isIndeterminate = false
            indicator.doubleValue = fraction
        } else {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
    }

    @objc private func stopClicked() {
        onStop?()
    }
}
