import AppKit

/// One swatch: an opaque sRGB color with components in 0 ... 1, the
/// space the tool colors use.
struct Swatch: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// The color's sRGB components, opaque; nil when it has none.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// "#RRGGBB", for tooltips and accessibility.
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// The Swatches palette's colors and the edits Photoshop's Swatches
/// palette offers: add, replace, delete and reset. Pure, so the rules
/// are unit-tested without a palette.
struct SwatchList: Equatable {
    /// More than any palette shows at once; keeps a corrupt or hostile
    /// preference from building an unbounded grid.
    static let maximumCount = 1000

    private(set) var swatches: [Swatch]

    init(_ swatches: [Swatch] = SwatchList.defaults) {
        self.swatches = Array(swatches.prefix(Self.maximumCount))
    }

    /// Adds `swatch` at the end; false when the list is full.
    @discardableResult
    mutating func add(_ swatch: Swatch) -> Bool {
        guard swatches.count < Self.maximumCount else { return false }
        swatches.append(swatch)
        return true
    }

    /// Replaces the swatch at `index`; false for an index out of range.
    @discardableResult
    mutating func replace(at index: Int, with swatch: Swatch) -> Bool {
        guard swatches.indices.contains(index) else { return false }
        swatches[index] = swatch
        return true
    }

    /// Deletes the swatch at `index`; false for an index out of range.
    @discardableResult
    mutating func remove(at index: Int) -> Bool {
        guard swatches.indices.contains(index) else { return false }
        swatches.remove(at: index)
        return true
    }

    mutating func reset() { swatches = Self.defaults }

    /// The default set: twelve hues at full strength, then lighter and
    /// darker, then eleven grays from white to black.
    static let defaults: [Swatch] = {
        let hues = (0..<12).map { Double($0) / 12 }
        func swatch(hue: Double, saturation: Double, brightness: Double) -> Swatch {
            let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            return Swatch(color) ?? Swatch(red: 0, green: 0, blue: 0)
        }
        var swatches = hues.map { swatch(hue: $0, saturation: 1, brightness: 1) }
        swatches += hues.map { swatch(hue: $0, saturation: 0.45, brightness: 1) }
        swatches += hues.map { swatch(hue: $0, saturation: 1, brightness: 0.55) }
        swatches += (0...10).map { step in
            let value = 1 - Double(step) / 10
            return Swatch(red: value, green: value, blue: value)
        }
        return swatches
    }()
}

/// Where the swatches persist: the user defaults as a JSON array.
/// Tests inject a suite.
@MainActor
final class SwatchStore {
    static let shared = SwatchStore()

    private static let key = "Glims.swatches"
    private let defaults: UserDefaults
    private var observers: [UUID: () -> Void] = [:]

    private(set) var list: SwatchList

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let swatches = try? JSONDecoder().decode([Swatch].self, from: data) {
            list = SwatchList(swatches)
        } else {
            list = SwatchList()
        }
    }

    /// Applies `change` and saves the result when it changed anything.
    @discardableResult
    func update(_ change: (inout SwatchList) -> Bool) -> Bool {
        var next = list
        guard change(&next), next != list else { return false }
        list = next
        if let data = try? JSONEncoder().encode(list.swatches) {
            defaults.set(data, forKey: Self.key)
        }
        observers.values.forEach { $0() }
        return true
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }
}
