import Foundation

enum ResourceMutationAction: Equatable {
    case rename(String)
    case delete
    var verb: String { if case .rename = self { return "Rename" }; return "Delete" }
    var progress: String { if case .rename = self { return "Renaming" }; return "Deleting" }
}

struct ResourceMutationOutcome {
    /// Native write succeeded; a refresh warning never turns it into a false failure.
    let renamedIdentity: EngineSession.ResourceIdentity?
    let warning: String?
}
