import AppKit
import RigiUI

/// Persistent editor choices. Changes apply to open windows immediately;
/// the initial zoom choice is used only when opening a document.
@MainActor
final class EditorPreferences {
    static let shared = EditorPreferences()
    static let didChange = Notification.Name("ch.lkmc.Glims.preferencesChanged")

    enum Surround: String, CaseIterable {
        case light, medium, dark

        var title: String {
            switch self {
            case .light: return "Light Gray"
            case .medium: return "Medium Gray"
            case .dark: return "Dark Gray"
            }
        }

        var color: NSColor {
            let white: CGFloat
            switch self {
            case .light: white = 0.72
            case .medium: white = 0.42
            case .dark: white = 0.18
            }
            return NSColor(calibratedWhite: white, alpha: 1)
        }
    }

    enum InitialView: String, CaseIterable {
        case fit, actualPixels
        var title: String { self == .fit ? "Fit Image" : "Actual Pixels" }
    }

    private enum Key {
        static let appearance = "editor.appearance"
        static let surround = "editor.canvasSurround"
        static let initialView = "editor.initialView"
    }

    private let defaults: UserDefaults
    private let notifications: NotificationCenter

    init(defaults: UserDefaults = .standard, notifications: NotificationCenter = .default) {
        self.defaults = defaults
        self.notifications = notifications
    }

    var appearance: ClassicChromeScheme {
        get { defaults.string(forKey: Key.appearance).flatMap(ClassicChromeScheme.init(rawValue:)) ?? .classicLight }
        set {
            guard newValue != appearance else { return }
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            notify()
        }
    }

    var surround: Surround {
        get { defaults.string(forKey: Key.surround).flatMap(Surround.init(rawValue:)) ?? .medium }
        set {
            guard newValue != surround else { return }
            defaults.set(newValue.rawValue, forKey: Key.surround)
            notify()
        }
    }

    var initialView: InitialView {
        get { defaults.string(forKey: Key.initialView).flatMap(InitialView.init(rawValue:)) ?? .fit }
        set {
            guard newValue != initialView else { return }
            defaults.set(newValue.rawValue, forKey: Key.initialView)
            notify()
        }
    }

    func reset() {
        for key in [Key.appearance, Key.surround, Key.initialView] { defaults.removeObject(forKey: key) }
        notify()
    }

    private func notify() {
        notifications.post(name: Self.didChange, object: self)
    }
}
