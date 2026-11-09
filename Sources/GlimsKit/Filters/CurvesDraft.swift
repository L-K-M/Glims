import Foundation

/// Patches are explicit per-channel values. Replies replace the accepted native
/// state, then replay outstanding user patches so another channel's reply
/// cannot erase a newer draft. Native sample tables stay authoritative.
struct CurvesDraft {
    enum Patch: Equatable {
        case curve(EngineSession.CurveEdit)
        case trc(EngineSession.ColorTRC)
        func applying(to settings: EngineSession.CurvesSettings) -> EngineSession.CurvesSettings {
            var result = settings
            switch self {
            case .trc(let trc): result.trc = trc
            case .curve(let edit):
                var state = result[edit.channel]
                switch edit {
                case .smooth(_, let points): state.kind = .smooth; state.points = points; state.identity = false
                case .free(_, let samples): state.kind = .free; state.samples = samples; state.identity = false
                case .reset: state = .init(); state.identity = false
                }
                result[edit.channel] = state
            }
            return result
        }
    }
    private(set) var accepted: EngineSession.CurvesSettings
    private(set) var pending: [Int: Patch] = [:]
    private var nextRequest = 0
    private var acceptedRequest = 0
    init(_ settings: EngineSession.CurvesSettings) { accepted = settings }
    var settings: EngineSession.CurvesSettings {
        pending.keys.filter { $0 > acceptedRequest }.sorted().reduce(accepted) { value, key in
            pending[key]?.applying(to: value) ?? value
        }
    }
    mutating func submit(_ patch: Patch) -> Int {
        nextRequest += 1
        pending[nextRequest] = patch
        return nextRequest
    }
    mutating func receive(_ request: Int, result: Result<EngineSession.CurvesSettings, Error>) {
        guard pending.removeValue(forKey: request) != nil else { return }
        if case .success(let snapshot) = result, request > acceptedRequest {
            accepted = snapshot
            acceptedRequest = request
        }
    }
}
