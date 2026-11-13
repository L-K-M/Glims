import Foundation

/// A complete scalar ink gesture; its document owns the channel binding.
struct RecorderInkStrokeCommand: Equatable {
    let settings: RecorderStrokeCommand.Settings
    let trace: RecorderTabletStrokeTrace
    let facts: EngineSession.StrokeCaptureFacts

    var title: String { settings.tool == .pencil ? "Ink Pencil Stroke" : "Ink Brush Stroke" }

    func validated() throws -> Self {
        guard settings.tool == .paintbrush || settings.tool == .pencil,
              !settings.antiErase, settings.size.isFinite, (1...10_000).contains(settings.size),
              [settings.opacity, settings.red, settings.green, settings.blue].allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }), settings.hardness.map({ $0.isFinite && (0...1).contains($0) }) != false else {
            throw RecorderFileError.invalid("The recorded ink brush settings are outside the supported range.")
        }
        let strings = [facts.brush.name] + (facts.brush.collection.map { [$0] } ?? [])
        guard !facts.brush.name.isEmpty,
              strings.allSatisfy({ $0.utf8.count <= RecorderFileLimits.stringBytes && !$0.utf8.contains(0) }),
              facts.fingerprint.utf8.count == 64,
              facts.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecorderFileError.invalid("The recorded ink brush identity or fingerprint is invalid.")
        }
        _ = try RecorderFileLimits.tabletStrokePointCount(trace, remaining: RecorderTabletStrokeAccumulator.maximumPoints)
        return self
    }

    func apply(session: EngineSession, image: Int32, channel: Int32,
               identity: RecorderInkIdentity) throws {
        _ = try validated()
        let current = try session.inkChannelIdentity(image, channel: channel)
        guard try identity.matchesInOwningDocument(RecorderInkIdentity(current)) else {
            throw RecorderFileError.invalid("The bound ink channel changed before the recorded stroke.")
        }
        var brush = settings.brush
        brush.resource = facts.brush
        let started = try session.beginInkStrokeCapturing(image: image, channel: channel,
            identity: current, brush: brush, first: trace.first.nativeSample, expected: facts)
        do {
            for batch in trace.batches {
                try session.continueTabletStroke(started.stroke, points: batch.map(\.nativeSample))
            }
            try session.endStroke(started.stroke)
        } catch {
            try? session.cancelInkStroke(started.stroke)
            throw error
        }
    }
}
