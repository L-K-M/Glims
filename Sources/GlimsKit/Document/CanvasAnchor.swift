import AppKit

/// Where Canvas Size keeps the existing image, as in Photoshop's 3 × 3
/// anchor grid. The new canvas grows or shrinks away from that point.
enum CanvasAnchor: Int, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// The existing image's top-left position in the new canvas. Center
    /// keeps the integer arithmetic Canvas Size has always used, so an odd
    /// difference puts the extra pixel on the right or bottom when growing.
    func offset(from old: (width: Int, height: Int), to new: (width: Int, height: Int)) -> CGPoint {
        func axis(_ position: Int, _ old: Int, _ new: Int) -> Int {
            switch position {
            case 0: return 0
            case 1: return (new - old) / 2
            default: return new - old
            }
        }
        return CGPoint(x: axis(rawValue % 3, old.width, new.width), y: axis(rawValue / 3, old.height, new.height))
    }
}

/// A 3 × 3 grid of radio buttons choosing a `CanvasAnchor`. Each button
/// carries its position as its accessibility label.
@MainActor
final class CanvasAnchorPicker: NSGridView {
    private(set) var anchor: CanvasAnchor = .center {
        didSet { refresh() }
    }
    private(set) var buttons: [NSButton] = []

    /// The buttons are built here, in the designated initializer, so every
    /// construction path (including the inherited `init()`) gets them.
    override init(frame: NSRect) {
        super.init(frame: frame)
        for anchor in CanvasAnchor.allCases {
            let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(choose(_:)))
            button.tag = anchor.rawValue
            button.setAccessibilityLabel("Anchor \(anchor.title)")
            buttons.append(button)
        }
        for row in 0..<3 { addRow(with: Array(buttons[(row * 3)..<(row * 3 + 3)])) }
        rowSpacing = 4
        columnSpacing = 4
        setAccessibilityLabel("Anchor")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Chooses `anchor` exactly as a click on its button would.
    func select(_ anchor: CanvasAnchor) { self.anchor = anchor }

    @objc private func choose(_ sender: NSButton) {
        guard let value = CanvasAnchor(rawValue: sender.tag) else { return }
        anchor = value
    }

    private func refresh() {
        for button in buttons { button.state = button.tag == anchor.rawValue ? .on : .off }
    }
}
