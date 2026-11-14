import Foundation

/// One ordinary pixel-layer gesture with its complete V2 tablet samples.
struct RecorderTabletStrokeCommand: Equatable {
    let settings: RecorderStrokeCommand.Settings
    let trace: RecorderTabletStrokeTrace
    let facts: EngineSession.StrokeCaptureFacts

    var title: String {
        switch settings.tool {
        case .pencil: return "Pencil Stroke"
        case .eraser: return "Eraser Stroke"
        case .paintbrush: return "Paintbrush Stroke"
        case .spongeDesaturate: return "Sponge Desaturate Stroke"
        case .spongeSaturate: return "Sponge Saturate Stroke"
        }
    }

    func validated() throws -> Self {
        guard settings.size.isFinite, settings.size > 0, settings.size <= 10_000,
              [settings.opacity, settings.red, settings.green, settings.blue].allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }), settings.hardness.map({ $0.isFinite && (0...1).contains($0) }) != false,
              settings.tool == .eraser || (!settings.antiErase && settings.eraserBackground == nil),
              settings.eraserBackground.map({ [$0.red, $0.green, $0.blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }) != false else {
            throw RecorderFileError.invalid("The recorded tablet brush settings are outside the supported range.")
        }
        let strings = [facts.brush.name] + (facts.brush.collection.map { [$0] } ?? [])
        guard !facts.brush.name.isEmpty,
              strings.allSatisfy({ $0.utf8.count <= RecorderFileLimits.stringBytes && !$0.utf8.contains(0) }),
              facts.fingerprint.utf8.count == 64,
              facts.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecorderFileError.invalid("The recorded tablet brush identity or fingerprint is invalid.")
        }
        _ = try RecorderFileLimits.tabletStrokePointCount(trace, remaining: RecorderTabletStrokeAccumulator.maximumPoints)
        return self
    }

    func apply(session: EngineSession, image: Int32, layer: Int32) throws {
        _ = try validated()
        let started = try session.beginTabletStrokeCapturing(image: image, drawable: layer, brush: settings.brush,
                                                              first: trace.first.nativeSample, expected: facts)
        do {
            for batch in trace.batches {
                try session.continueTabletStroke(started.stroke, points: batch.map(\.nativeSample))
            }
        } catch {
            try? session.endStroke(started.stroke)
            throw error
        }
        try session.endStroke(started.stroke)
    }
}
