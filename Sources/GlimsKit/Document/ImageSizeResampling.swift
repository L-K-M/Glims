import AppKit

/// The Image Size resampling choice: Photoshop's three methods first, then
/// the engine's two edge-preserving ones. Bicubic is the default, matching
/// the engine's own preference.
@MainActor
enum ImageSizeResampling {
    static let choices: [(title: String, interpolation: EngineSession.Interpolation)] = [
        ("Nearest Neighbor", .none), ("Bilinear", .linear), ("Bicubic", .cubic),
        ("NoHalo", .noHalo), ("LoHalo", .loHalo),
    ]
    static let defaultInterpolation = EngineSession.Interpolation.cubic

    static func popUpButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in choices {
            button.addItem(withTitle: choice.title)
            button.lastItem?.tag = Int(choice.interpolation.rawValue)
        }
        button.selectItem(withTag: Int(defaultInterpolation.rawValue))
        button.setAccessibilityLabel("Resample method")
        return button
    }

    static func interpolation(of button: NSPopUpButton) -> EngineSession.Interpolation? {
        guard let tag = button.selectedItem?.tag, tag > 0 else { return nil }
        return EngineSession.Interpolation(rawValue: UInt32(tag))
    }
}
