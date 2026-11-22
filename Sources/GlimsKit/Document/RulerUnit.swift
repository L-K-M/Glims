/// The unit the rulers label in. Tick positions stay in image pixels
/// whatever the unit, so guide dragging is unaffected by it.
enum RulerUnit: String, CaseIterable, Equatable {
    case pixels, inches, centimeters, millimeters, points, picas, percent

    var title: String {
        switch self {
        case .pixels: return "Pixels"
        case .percent: return "Percent"
        default: return length?.title ?? rawValue
        }
    }

    /// The print length behind a physical unit, nil for pixels and percent.
    var length: ImageSizeModel.LengthUnit? {
        switch self {
        case .pixels, .percent: return nil
        case .inches: return .inches
        case .centimeters: return .centimeters
        case .millimeters: return .millimeters
        case .points: return .points
        case .picas: return .picas
        }
    }

    /// The menu tag; menus list the units in this order.
    var tag: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    init?(tag: Int) {
        guard Self.allCases.indices.contains(tag) else { return nil }
        self = Self.allCases[tag]
    }
}
