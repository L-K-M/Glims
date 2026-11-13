import Foundation

/// A complete color brush gesture. The document owns its logical layer
/// binding; the gesture never stores a native session or item identifier.
struct RecorderLabLayerStrokeCommand: Equatable {
    let settings: RecorderStrokeCommand.Settings
    let trace: RecorderTabletStrokeTrace
    let facts: EngineSession.StrokeCaptureFacts

    var title: String { "Lab Layer Brush Stroke" }

    func validated() throws -> Self {
        guard settings.tool == .paintbrush, !settings.antiErase,
              settings.size.isFinite, (1...10_000).contains(settings.size),
              [settings.opacity, settings.red, settings.green, settings.blue].allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }), settings.hardness.map({ $0.isFinite && (0...1).contains($0) }) != false else {
            throw RecorderFileError.invalid("The recorded Lab layer brush settings are outside the supported range.")
        }
        let strings = [facts.brush.name] + (facts.brush.collection.map { [$0] } ?? [])
        guard !facts.brush.name.isEmpty,
              strings.allSatisfy({ $0.utf8.count <= RecorderFileLimits.stringBytes && !$0.utf8.contains(0) }),
              facts.fingerprint.utf8.count == 64,
              facts.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecorderFileError.invalid("The recorded Lab layer brush identity or fingerprint is invalid.")
        }
        _ = try RecorderFileLimits.tabletStrokePointCount(trace, remaining: RecorderTabletStrokeAccumulator.maximumPoints)
        return self
    }

    /// The caller binds the explicit logical root and its UUID; the engine
    /// verifies both it and the brush fingerprint before the first dab.
    func apply(session: EngineSession, image: Int32, target: EngineSession.LabLayerFillTarget) throws {
        _ = try validated()
        var brush = settings.brush
        brush.resource = facts.brush
        let started = try session.beginLabLayerStrokeCapturing(image: image, target: target,
            brush: brush, first: trace.first.nativeSample, expected: facts, requireEmptySelection: true)
        do {
            for batch in trace.batches {
                try session.continueTabletStroke(started.stroke, points: batch.map(\.nativeSample))
            }
            try session.endStroke(started.stroke)
        } catch {
            try? session.cancelLabLayerStroke(started.stroke)
            throw error
        }
    }
}
