import Foundation

/// Matching is an explicit batch policy. Interactive Load keeps its existing
/// binding sheet and never uses this matcher to infer the user's choices.
enum RecorderBatchBindings {
    enum Policy: CaseIterable {
        case requireNoTargets
        case matchingNamesAndKinds
        case matchingPathsAndKinds
    }

    struct Candidate {
        let choice: ImageDocument.RecorderInstallChoice
        let description: RecorderTargetDescription
        let hasMask: Bool
    }

    enum MatchError: LocalizedError, Equatable {
        case emptyRecording
        case unsuccessfulCommand(Int)
        case matchingRequired
        case missing(String)
        case ambiguous(String)
        case duplicateTarget(String)

        var errorDescription: String? {
            switch self {
            case .emptyRecording: return "Choose a recording with at least one successful command."
            case .unsuccessfulCommand(let index):
                return "Recording command \(index) did not succeed. Choose a complete recording for Batch."
            case .matchingRequired:
                return "This recording uses specific targets. Choose how Batch should match them in each image."
            case .missing(let name):
                return "No target matches “\(name)” with its recorded role and required mask."
            case .ambiguous(let name):
                return "More than one target matches “\(name)”. Use unique names or a more specific matching policy."
            case .duplicateTarget(let name):
                return "“\(name)” matches a target already used by another recording symbol. Each needs a distinct target."
            }
        }
    }

    /// A detached candidate snapshot is only a proposal. The document's
    /// installRecording service must still validate native membership, masks,
    /// roles and editability before any replay is admitted.
    static func resolve(file: RecorderFileValue, candidates: [Candidate],
                        policy: Policy) throws -> [UUID: ImageDocument.RecorderInstallChoice] {
        _ = try RecorderFileCodec.encode(file) // Validate caller-built files too.
        guard !file.records.isEmpty else { throw MatchError.emptyRecording }
        var required = Set<UUID>()
        var maskOwners = Set<UUID>()
        for record in file.records {
            guard case .success(_, let binding) = record.outcome else {
                throw MatchError.unsuccessfulCommand(record.ordinal + 1)
            }
            required.formUnion(try RecorderFileCodec.referencedSymbols(binding))
            if case .context(let context) = binding {
                maskOwners.formUnion(context.masks.filter(\.isPresent).map(\.owner))
            }
        }
        if case .requireNoTargets = policy {
            guard required.isEmpty else { throw MatchError.matchingRequired }
            return [:]
        }

        var choices: [UUID: ImageDocument.RecorderInstallChoice] = [:]
        var used = Set<ImageDocument.RecorderInstallChoice>()
        // Symbol order makes the first actionable refusal deterministic.
        for symbol in file.symbols where required.contains(symbol.id) {
            let matches = candidates.filter { candidate in
                guard hasValidRole(candidate), candidate.description.name == symbol.description.name,
                      candidate.description.kind == symbol.description.kind,
                      !maskOwners.contains(symbol.id) || candidate.hasMask else { return false }
                if case .matchingPathsAndKinds = policy {
                    let actual = candidate.description.ancestors
                    let recorded = symbol.description.ancestors
                    return actual.count == recorded.count && zip(actual, recorded).allSatisfy { pair in
                        pair.0.name == pair.1.name && pair.0.kind == pair.1.kind
                    }
                }
                return true
            }
            guard !matches.isEmpty else { throw MatchError.missing(symbol.description.name) }
            guard matches.count == 1 else { throw MatchError.ambiguous(symbol.description.name) }
            let choice = matches[0].choice
            guard used.insert(choice).inserted else { throw MatchError.duplicateTarget(symbol.description.name) }
            choices[symbol.id] = choice
        }
        return choices
    }

    private static func hasValidRole(_ candidate: Candidate) -> Bool {
        switch (candidate.choice, candidate.description.kind) {
        case (.layer(let id), .pixel), (.layer(let id), .group), (.layer(let id), .text),
             (.layer(let id), .link), (.layer(let id), .vector),
             (.channel(let id), .channel), (.quickMask(let id), .quickMask): return id > 0
        default: return false
        }
    }
}
