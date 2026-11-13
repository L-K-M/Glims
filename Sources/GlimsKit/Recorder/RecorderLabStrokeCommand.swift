import Foundation

/// A complete physical Lab gesture. The document owns its axis binding;
/// samples and resource facts contain no native object IDs.
struct RecorderLabStrokeCommand: Equatable {
    struct Settings: Equatable {
        let value: Double
        let size: Double
        let opacity: Double
        let hardness: Double
    }

    let settings: Settings
    let trace: RecorderTabletStrokeTrace
    let facts: EngineSession.StrokeCaptureFacts

    var title: String { "Lab Brush Stroke" }

    func validated() throws -> Self {
        guard settings.value.isFinite,
              abs(settings.value) <= Double(Float.greatestFiniteMagnitude),
              settings.size.isFinite, (1...10_000).contains(settings.size),
              [settings.opacity, settings.hardness].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw RecorderFileError.invalid("The recorded Lab brush settings are outside the supported range.")
        }
        let strings = [facts.brush.name] + (facts.brush.collection.map { [$0] } ?? [])
        guard !facts.brush.name.isEmpty,
              strings.allSatisfy({ $0.utf8.count <= RecorderFileLimits.stringBytes && !$0.utf8.contains(0) }),
              facts.fingerprint.utf8.count == 64,
              facts.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecorderFileError.invalid("The recorded Lab brush identity or fingerprint is invalid.")
        }
        _ = try RecorderFileLimits.tabletStrokePointCount(trace, remaining: RecorderTabletStrokeAccumulator.maximumPoints)
        return self
    }

    func apply(session: EngineSession, image: Int32, labAxis: EngineSession.LabAxis) throws {
        _ = try validated()
        var brush = EngineSession.Brush()
        brush.tool = .paintbrush
        brush.size = settings.size
        brush.opacity = settings.opacity
        brush.hardness = settings.hardness
        brush.resource = facts.brush
        let started = try session.beginLabStrokeCapturing(image: image, axis: labAxis,
            value: settings.value, brush: brush, first: trace.first.nativeSample, expected: facts)
        do {
            for batch in trace.batches {
                try session.continueTabletStroke(started.stroke, points: batch.map(\.nativeSample))
            }
            try session.endStroke(started.stroke)
        } catch {
            // Lab cancellation restores the pre-gesture pixels and history.
            // Keep the first error even if retirement itself also fails.
            try? session.cancelLabStroke(started.stroke)
            throw error
        }
    }
}
