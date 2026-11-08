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

    /// How often open, changed images are copied into the private
    /// recovery store, in minutes.
    enum RecoveryInterval: Int, CaseIterable {
        case oneMinute = 1, twoMinutes = 2, fiveMinutes = 5, tenMinutes = 10
        var seconds: TimeInterval { TimeInterval(rawValue) * 60 }
        var title: String { rawValue == 1 ? "1 minute" : "\(rawValue) minutes" }
    }

    private enum Key {
        static let appearance = "editor.appearance"
        static let surround = "editor.canvasSurround"
        static let initialView = "editor.initialView"
        static let recoveryCopies = "editor.recoveryCopies"
        static let recoveryInterval = "editor.recoveryInterval"
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

    /// App-owned dialogs use the matching native appearance. Document
    /// windows keep their own appearance and Rigi recolors their chrome.
    var chromeAppearance: NSAppearance? {
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
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

    /// Periodic private recovery copies of open, changed images; on by
    /// default so a crash keeps the last copied state.
    var recoveryCopiesEnabled: Bool {
        get { (defaults.object(forKey: Key.recoveryCopies) as? Bool) ?? true }
        set {
            guard newValue != recoveryCopiesEnabled else { return }
            defaults.set(newValue, forKey: Key.recoveryCopies)
            notify()
        }
    }

    var recoveryInterval: RecoveryInterval {
        get { RecoveryInterval(rawValue: defaults.integer(forKey: Key.recoveryInterval)) ?? .twoMinutes }
        set {
            guard newValue != recoveryInterval else { return }
            defaults.set(newValue.rawValue, forKey: Key.recoveryInterval)
            notify()
        }
    }

    func reset() {
        for key in [Key.appearance, Key.surround, Key.initialView,
                    Key.recoveryCopies, Key.recoveryInterval] {
            defaults.removeObject(forKey: key)
        }
        notify()
    }

    private func notify() {
        notifications.post(name: Self.didChange, object: self)
    }
}
