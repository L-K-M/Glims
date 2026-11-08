import AppKit
import Foundation

/// The persistent Gradient tool preferences: the chosen gradient's
/// `ResourceIdentity` (nil = the Foreground-to-Background Default) plus the
/// tool's own settings as plain enums/primitives. Only these cross into
/// UserDefaults — never a session `ResourceID` handle (local to the running
/// engine, reusable after a restart), never a rendered CGImage, and never
/// the foreground/background colors (those stay in the global `ToolState`,
/// whose existing behavior is unchanged).
struct GradientToolPreferences: Codable, Equatable {
    /// The chosen gradient; nil is the Foreground-to-Background Default,
    /// resolved to the built-in persistent identity at each gesture.
    var identity: EngineSession.ResourceIdentity?
    var shape: EngineSession.GradientShape = .linear
    var reverse = false
    var blendSpace: EngineSession.GradientBlendSpace = .rgbPerceptual
    /// 0 ... 1.
    var opacity = 1.0

    /// The defaults: linear, perceptual, non-reversed, full opacity and the
    /// Foreground-to-Background Default. These preserve the appearance the
    /// low-level FG/BG gradient draw always had.
    static let `default` = GradientToolPreferences()
}

/// The persistent Gradient tool choice, stored through UserDefaults as
/// Codable JSON. Pure value storage (no AppKit, no engine): tests inject a
/// suite's UserDefaults, the app uses `shared`.
final class GradientToolStore {
    static let shared = GradientToolStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect the raw encoded form.
    static let preferencesKey = "editor.gradientTool"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored preferences; unreadable or absent data reads as the
    /// defaults (nil identity = Foreground-to-Background Default).
    var preferences: GradientToolPreferences {
        guard let data = defaults.data(forKey: Self.preferencesKey),
              let decoded = try? JSONDecoder().decode(GradientToolPreferences.self, from: data) else {
            return .default
        }
        return decoded
    }

    func set(_ preferences: GradientToolPreferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    /// Stores only the resource identity, keeping the other settings.
    func setIdentity(_ identity: EngineSession.ResourceIdentity?) {
        var preferences = preferences
        preferences.identity = identity
        set(preferences)
    }

    /// Back to the defaults: nil identity (the Foreground-to-Background
    /// Default) and the default settings.
    func reset() {
        defaults.removeObject(forKey: Self.preferencesKey)
    }
}

extension EngineSession.ResourceIdentity {
    /// The built-in Foreground-to-Background gradient the Default choice
    /// resolves to: collection "gimp-gradient-fg-bg-rgb", internal. Native
    /// resolution ignores an internal resource's name, but it must be
    /// nonempty, so it carries the engine's own display name. Routing the
    /// Default through this resource path too lets reverse, blend space
    /// and opacity apply to it like to any chosen gradient.
    static let defaultForegroundBackground = EngineSession.ResourceIdentity(
        name: "FG to BG", collection: "gimp-gradient-fg-bg-rgb", isInternal: true)
}

extension EngineSession.GradientBlendSpace {
    /// The blend spaces the interface offers. RGB Linear is explicitly
    /// UNSUPPORTED by the native engines and is never offered — no linear
    /// blending is promised.
    static let selectable: [EngineSession.GradientBlendSpace] = [.rgbPerceptual, .cieLab]

    var name: String {
        switch self {
        case .rgbPerceptual: return "Perceptual RGB"
        case .rgbLinear: return "RGB Linear"
        case .cieLab: return "Lab"
        }
    }
}

/// One canvas gradient gesture captured as pure values: the persistent
/// identity to resolve (on the engine worker, inside the queued job —
/// never on main), the settings (shape, reverse, blend space, opacity,
/// opaque foreground/background colors) and the endpoints. Capturing once
/// per gesture means later UI, tool, preference or color changes cannot
/// redirect the queued work, and no mutable `ToolState` is read from the
/// worker closure.
struct GradientGestureSnapshot: Equatable {
    let identity: EngineSession.ResourceIdentity
    let from: CGPoint
    let to: CGPoint
    let settings: EngineSession.ResourceGradientSettings

    /// Captures a gesture's values. A nil `identity` captures the built-in
    /// Foreground-to-Background identity, so the Default works with no
    /// explicit selected resource. The colors are forced opaque: the
    /// engine's FG/BG context has no alpha and refuses translucent colors,
    /// while transparency belongs to the resource's own stop types.
    static func capture(identity: EngineSession.ResourceIdentity?,
                        shape: EngineSession.GradientShape,
                        reverse: Bool,
                        blendSpace: EngineSession.GradientBlendSpace,
                        opacity: Double,
                        foreground: NSColor, background: NSColor,
                        from: CGPoint, to: CGPoint) -> GradientGestureSnapshot {
        var settings = EngineSession.ResourceGradientSettings()
        settings.shape = shape
        settings.reverse = reverse
        settings.blendSpace = blendSpace
        settings.opacity = opacity
        settings.foreground = Self.opaque(foreground)
        settings.background = Self.opaque(background)
        return GradientGestureSnapshot(identity: identity ?? .defaultForegroundBackground,
                                       from: from, to: to, settings: settings)
    }

    /// The same captured gesture with new endpoints (the release point);
    /// identity and settings are untouched.
    func withEndpoints(from: CGPoint, to: CGPoint) -> GradientGestureSnapshot {
        GradientGestureSnapshot(identity: identity, from: from, to: to, settings: settings)
    }

    private static func opaque(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                       blue: rgb.blueComponent, alpha: 1)
    }
}
