import Foundation

/// Native component painting treats normalized display-sRGB Rec.709 luma
/// as paper intensity. Coverage reverses that scale; opacity is independent.
enum InkBrushCoverage {
    static func percent(red: Double, green: Double, blue: Double) -> Double? {
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return (1 - (0.2126 * red + 0.7152 * green + 0.0722 * blue)) * 100
    }

    static func intensity(forPercent percent: Double) -> Double? {
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return 1 - percent / 100
    }

    static func parsePercent(_ text: String, locale: Locale = .current) -> Double? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        let scanner = Scanner(string: text)
        scanner.locale = locale
        guard let value = scanner.scanDouble(), scanner.isAtEnd,
              intensity(forPercent: value) != nil else { return nil }
        return value
    }
}
