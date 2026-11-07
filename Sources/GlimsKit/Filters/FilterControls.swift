import AppKit

extension EngineSession.FilterValueKind {
    /// Kinds a form row can edit; anything else shows as disabled.
    var isEditable: Bool { self != .unsupported }
}

extension EngineSession.FilterProperty {
    /// The typed field's accepted span: the engine's absolute limits.
    var absoluteRange: ClosedRange<Double> {
        min(minimum, maximum)...max(minimum, maximum)
    }

    /// The slider's span: the engine's suggested form range.
    var suggestedRange: ClosedRange<Double> {
        min(uiMinimum, uiMaximum)...max(uiMinimum, uiMaximum)
    }

    /// The field's decimals: the engine's suggestion, else by kind and
    /// suggested range (GIMP's fallback for plain values).
    var displayDigits: Int {
        if uiDigits >= 0 { return uiDigits }
        if kind == .integer { return 0 }
        let range = suggestedRange.upperBound - suggestedRange.lowerBound
        return range <= 1 ? 4 : range <= 10 ? 3 : 2
    }

    /// The engine's unit hint key rendered for a compact label; keys
    /// without a familiar short form are left out rather than shown raw.
    var displayUnit: String {
        switch unit {
        case "percent": return "%"
        case "degree": return "°"
        case "kelvin": return "K"
        case "pixel-distance", "pixel-coordinate": return "px"
        default: return ""
        }
    }
}

/// A slider position's mapping onto a suggested range: positions 0...1
/// span `minimum`...`maximum`, warped by `gamma` — the engine's odd-power
/// mapping (GEGL's ui_gamma, GimpSpinScale).
struct GammaScale: Equatable {
    let minimum: Double
    let maximum: Double
    let gamma: Double

    init(minimum: Double, maximum: Double, gamma: Double) {
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
        self.gamma = gamma > 0 ? gamma : 1
    }

    private func oddPow(_ x: Double, _ y: Double) -> Double {
        x >= 0 ? pow(x, y) : -pow(-x, y)
    }

    /// The value's slider position, clamped to 0...1.
    func position(for value: Double) -> Double {
        let x0 = oddPow(minimum, 1 / gamma), x1 = oddPow(maximum, 1 / gamma)
        guard x1 != x0 else { return 0 }
        return min(max((oddPow(value, 1 / gamma) - x0) / (x1 - x0), 0), 1)
    }

    /// The value at `position` (0...1), unclamped input clamped first.
    func value(forPosition position: Double) -> Double {
        let x0 = oddPow(minimum, 1 / gamma), x1 = oddPow(maximum, 1 / gamma)
        return oddPow(x0 + min(max(position, 0), 1) * (x1 - x0), gamma)
    }
}

/// A number or integer property's row: slider over the suggested range,
/// text field over the absolute limits, unit label (design.md, form
/// rows). The field accepts any value inside the absolute bounds; the
/// slider knob stops at its ends when the value leaves the suggested
/// range.
final class FilterNumberRow: NSView {
    private let property: EngineSession.FilterProperty
    private let isInteger: Bool
    private let scale: GammaScale
    private let step: Double
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let field = NSTextField()
    /// Displays and parses the field's text; its locale is the user's,
    /// so a comma-decimal system both shows and accepts "0,5".
    let formatter = NumberFormatter()
    /// The largest Double an integer send can carry into Int64 exactly.
    private static let integerFieldLimit = 9_007_199_254_740_992.0
    private(set) var value: Double = 0
    var onChange: ((Double) -> Void)?

    init(property: EngineSession.FilterProperty) {
        self.property = property
        self.isInteger = property.kind == .integer
        self.scale = GammaScale(minimum: property.suggestedRange.lowerBound,
                                maximum: property.suggestedRange.upperBound,
                                gamma: property.uiGamma)
        self.step = property.uiStepSmall > 0 ? property.uiStepSmall : 0
        super.init(frame: .zero)
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = property.displayDigits
        formatter.usesGroupingSeparator = false

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel(property.label)
        slider.toolTip = property.blurb.isEmpty ? nil : property.blurb

        field.formatter = formatter
        field.target = self
        field.action = #selector(fieldChanged)
        field.delegate = self
        field.setAccessibilityLabel(property.blurb.isEmpty ? property.label : "\(property.label), \(property.blurb)")
        field.toolTip = property.blurb.isEmpty ? nil : property.blurb
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [slider, field])
        stack.spacing = 8
        if !property.displayUnit.isEmpty {
            let unit = NSTextField(labelWithString: property.displayUnit)
            unit.textColor = .secondaryLabelColor
            stack.addArrangedSubview(unit)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows an engine-side value without sending it back — the initial
    /// read and the revert of a refused write.
    func show(_ newValue: Double) {
        value = newValue
        field.stringValue = formatter.string(from: NSNumber(value: newValue)) ?? "\(newValue)"
        slider.doubleValue = scale.position(for: newValue)
    }

    /// Slider drags snap to the suggested small step when the engine
    /// gives one, and always quantize integers.
    private func quantized(_ raw: Double) -> Double {
        var result = raw
        if step > 0 { result = (result / step).rounded() * step }
        if isInteger { result = result.rounded() }
        return result.clamped(to: property.suggestedRange)
    }

    @objc private func sliderChanged() {
        let dragged = quantized(scale.value(forPosition: slider.doubleValue))
        guard dragged != value else { return }
        value = dragged
        field.stringValue = formatter.string(from: NSNumber(value: dragged)) ?? "\(dragged)"
        onChange?(dragged)
    }

    @objc private func fieldChanged() {
        commitField()
    }

    /// The text committed and applied; false when the formatter cannot
    /// read it or it is not finite — the field then reverts and beeps,
    /// so NaN and Inf never reach a value send.
    @discardableResult
    func commitField() -> Bool {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let typed = formatter.number(from: text)?.doubleValue, typed.isFinite else {
            show(value)
            NSSound.beep()
            return false
        }
        var accepted = isInteger ? typed.rounded() : typed
        accepted = accepted.clamped(to: property.absoluteRange)
        if isInteger {
            // The send converts to Int64; stay inside the span Double
            // can convert exactly even when the engine's bounds are not.
            accepted = accepted.clamped(to: -Self.integerFieldLimit...Self.integerFieldLimit)
        }
        field.stringValue = formatter.string(from: NSNumber(value: accepted)) ?? "\(accepted)"
        slider.doubleValue = scale.position(for: accepted)
        guard accepted != value else { return true }
        value = accepted
        onChange?(accepted)
        return true
    }
}

extension FilterNumberRow: NSTextFieldDelegate {
    /// Committing happens on Return or when the field loses focus, the
    /// same two moments a value field applies elsewhere in the app.
    func controlTextDidEndEditing(_ notification: Notification) {
        commitField()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
