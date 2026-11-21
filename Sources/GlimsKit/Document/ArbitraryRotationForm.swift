import AppKit

/// Image ▸ Rotate ▸ Arbitrary's sheet content: Photoshop's angle in
/// degrees and its clockwise or counter-clockwise choice.
@MainActor
struct ArbitraryRotationForm {
    let angle: NSTextField
    let clockwise: NSButton
    let counterclockwise: NSButton
    let view: NSGridView
    private let directionGroup: RadioGroup

    init() {
        angle = NSTextField(string: "0")
        angle.setAccessibilityLabel("Angle in degrees")
        clockwise = NSButton(radioButtonWithTitle: "Clockwise", target: nil, action: nil)
        counterclockwise = NSButton(radioButtonWithTitle: "Counter-Clockwise", target: nil, action: nil)
        clockwise.state = .on
        directionGroup = RadioGroup([clockwise, counterclockwise])
        let directions = NSStackView(views: [clockwise, counterclockwise])
        directions.orientation = .vertical
        directions.alignment = .leading
        view = NSGridView(views: [
            [NSTextField(labelWithString: "Angle (°):"), angle],
            [NSGridCell.emptyContentView, directions],
        ])
        view.column(at: 0).xPlacement = .trailing
        view.row(at: 1).yPlacement = .top
        angle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 74)
    }

    /// The clockwise angle the sheet asks for, or nil when the text is
    /// not a nonzero number within ±359.99.
    var clockwiseDegrees: Double? {
        Self.clockwiseDegrees(angle.stringValue, clockwise: clockwise.state == .on)
    }

    static func clockwiseDegrees(_ text: String, clockwise: Bool) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), EngineSession.isValidCanvasRotation(value) else { return nil }
        return clockwise ? value : -value
    }
}

/// Keeps exactly one of its radio buttons on.
@MainActor
private final class RadioGroup: NSObject {
    private let buttons: [NSButton]

    init(_ buttons: [NSButton]) {
        self.buttons = buttons
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(choose(_:))
        }
    }

    @objc func choose(_ sender: NSButton) {
        for button in buttons { button.state = button === sender ? .on : .off }
    }
}
