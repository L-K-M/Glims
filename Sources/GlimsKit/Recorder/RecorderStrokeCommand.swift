import Foundation

/// One whole gesture. The owning document keeps the native layer binding
/// separately. These values contain no session IDs or event objects.
struct RecorderStrokeCommand: Equatable {
    enum Tool: String {
        case pencil, eraser, paintbrush, spongeDesaturate, spongeSaturate

        var isSponge: Bool { self == .spongeDesaturate || self == .spongeSaturate }
    }

    struct Settings: Equatable {
        let tool: Tool
        let size, opacity, red, green, blue: Double
        let hardness: Double?
        let pressureSize, antiErase: Bool
        let eraserBackground: EngineSession.Brush.EraserBackground?

        init?(tool: Tool, size: Double, opacity: Double, red: Double, green: Double, blue: Double,
              hardness: Double?, pressureSize: Bool, antiErase: Bool,
              eraserBackground: EngineSession.Brush.EraserBackground? = nil) {
            guard size > 0, size <= 10_000,
                  [opacity, red, green, blue].allSatisfy({ (0...1).contains($0) }),
                  hardness.map({ (0...1).contains($0) }) != false,
                  tool == .eraser || (!antiErase && eraserBackground == nil),
                  eraserBackground.map({ [$0.red, $0.green, $0.blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }) != false
            else { return nil }
            self.tool = tool
            self.size = size
            self.opacity = opacity
            self.red = red
            self.green = green
            self.blue = blue
            self.hardness = hardness
            self.pressureSize = pressureSize
            self.antiErase = antiErase
            self.eraserBackground = eraserBackground
        }

        init?(_ brush: EngineSession.Brush) {
            let tool: Tool
            switch brush.tool {
            case .pencil: tool = .pencil
            case .eraser: tool = .eraser
            case .paintbrush: tool = .paintbrush
            case .spongeDesaturate: tool = .spongeDesaturate
            case .spongeSaturate: tool = .spongeSaturate
            default: return nil
            }
            self.init(tool: tool, size: brush.size, opacity: brush.opacity,
                      red: brush.red, green: brush.green, blue: brush.blue,
                      hardness: brush.hardness, pressureSize: brush.pressureSize,
                      antiErase: tool == .eraser && brush.antiErase,
                      eraserBackground: tool == .eraser ? brush.eraserBackground : nil)
        }

        var brush: EngineSession.Brush {
            var result = EngineSession.Brush()
            switch tool {
            case .pencil: result.tool = .pencil
            case .eraser: result.tool = .eraser
            case .paintbrush: result.tool = .paintbrush
            case .spongeDesaturate: result.tool = .spongeDesaturate
            case .spongeSaturate: result.tool = .spongeSaturate
            }
            result.size = size
            result.opacity = opacity
            result.red = red
            result.green = green
            result.blue = blue
            result.hardness = hardness
            result.pressureSize = pressureSize
            result.antiErase = antiErase
            result.eraserBackground = eraserBackground
            return result
        }
    }

    let settings: Settings
    let trace: RecorderStrokeTrace
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

    func apply(session: EngineSession, image: Int32, layer: Int32) throws {
        let start = try session.beginStrokeCapturing(image: image, drawable: layer, brush: settings.brush,
                                                     first: trace.first.native, expected: facts)
        do {
            for batch in trace.batches {
                try session.continueStroke(start.stroke, points: batch.map(\.native))
            }
        } catch {
            // Always retire an accepted stroke. Preserve the first failure
            // and the ordinary native history of any work already applied.
            try? session.endStroke(start.stroke)
            throw error
        }
        try session.endStroke(start.stroke)
    }
}

extension RecorderStrokeTrace.Point {
    init(_ point: EngineSession.StrokePoint) throws {
        try self.init(x: point.x, y: point.y, pressure: point.pressure, xTilt: point.xTilt, yTilt: point.yTilt,
                      timeMilliseconds: point.timeMilliseconds)
    }

    var native: EngineSession.StrokePoint {
        .init(x: x, y: y, pressure: pressure, xTilt: xTilt, yTilt: yTilt, timeMilliseconds: timeMilliseconds)
    }
}
