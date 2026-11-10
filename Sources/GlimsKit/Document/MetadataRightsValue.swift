/// The canonical scalar values of Xmp.xmpRights.Marked. Unrecognized raw
/// metadata stays with the caller and is never converted to absence/false.
enum MetadataRightsValue: CaseIterable, Equatable {
    case unspecified
    case marked
    case unmarked

    init?(values: [String]) {
        switch values {
        case []: self = .unspecified
        case ["True"]: self = .marked
        case ["False"]: self = .unmarked
        default: return nil
        }
    }

    var values: [String] {
        switch self {
        case .unspecified: return []
        case .marked: return ["True"]
        case .unmarked: return ["False"]
        }
    }

    var title: String {
        switch self {
        case .unspecified: return "Not specified"
        case .marked: return "Marked"
        case .unmarked: return "Not marked"
        }
    }
}
