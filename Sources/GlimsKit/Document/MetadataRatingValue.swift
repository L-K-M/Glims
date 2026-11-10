/// The canonical scalar values of Xmp.xmp.Rating. Unrecognized raw metadata
/// (including fractional ratings such as "2.5") stays with the caller and is
/// never parsed, normalized, or rounded.
enum MetadataRatingValue: CaseIterable, Equatable {
    case unspecified
    case unrated
    case rejected
    case one
    case two
    case three
    case four
    case five

    init?(values: [String]) {
        switch values {
        case []: self = .unspecified
        case ["0"]: self = .unrated
        case ["-1"]: self = .rejected
        case ["1"]: self = .one
        case ["2"]: self = .two
        case ["3"]: self = .three
        case ["4"]: self = .four
        case ["5"]: self = .five
        default: return nil
        }
    }

    var values: [String] {
        switch self {
        case .unspecified: return []
        case .unrated: return ["0"]
        case .rejected: return ["-1"]
        case .one: return ["1"]
        case .two: return ["2"]
        case .three: return ["3"]
        case .four: return ["4"]
        case .five: return ["5"]
        }
    }

    var title: String {
        switch self {
        case .unspecified: return "Not specified"
        case .unrated: return "Unrated (0)"
        case .rejected: return "Rejected (-1)"
        case .one: return "1 star"
        case .two: return "2 stars"
        case .three: return "3 stars"
        case .four: return "4 stars"
        case .five: return "5 stars"
        }
    }
}
