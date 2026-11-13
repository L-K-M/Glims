import Foundation
import CoreGraphics

/// A Lab root-mask edit, independent of the selected physical axis. Its
/// explicit command type prevents replay through an ordinary selection API.
enum RecorderLabSelectionCommand: Equatable {
    enum Selection: String { case all, none, invert }
    struct Options: Equatable {
        let operation: RecorderFileCommand.Operation
        let antialias: Bool
        let feather: Double
        let cornerRadius: Double
    }

    case shape(RecorderFileCommand.Shape, Options)
    case command(Selection)

    var pointCount: Int {
        if case .shape(.polygon(let points), _) = self { return points.count }
        return 0
    }

    var title: String {
        switch self {
        case .shape(.rectangle, _): return "Lab Rectangle Selection"
        case .shape(.ellipse, _): return "Lab Ellipse Selection"
        case .shape(.polygon, _): return "Lab Polygon Selection"
        case .command(.all): return "Lab Select All"
        case .command(.none): return "Lab Select None"
        case .command(.invert): return "Lab Invert Selection"
        }
    }

    func validated() throws -> Self {
        guard case .shape(let shape, let options) = self else { return self }
        guard [options.feather, options.cornerRadius].allSatisfy({ $0.isFinite && (0...1000).contains($0) }) else {
            throw RecorderFileError.invalid("Lab selection feather and corner radius must be in 0...1000 pixels.")
        }
        func valid(_ value: Double) -> Bool { value.isFinite && (-1_048_576...1_048_576).contains(value) }
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            let endX = rect.x + rect.width, endY = rect.y + rect.height
            guard [rect.x, rect.y, endX, endY].allSatisfy(valid),
                  ceil(max(rect.x, endX)) - floor(min(rect.x, endX)) > 0,
                  ceil(max(rect.y, endY)) - floor(min(rect.y, endY)) > 0 else {
                throw RecorderFileError.invalid("The recorded Lab selection has invalid or empty bounds.")
            }
        case .polygon(let points):
            guard (3...65_536).contains(points.count), points.allSatisfy({ valid($0.x) && valid($0.y) }) else {
                throw RecorderFileError.invalid("A recorded Lab polygon needs 3...65536 finite points in the supported range.")
            }
        }
        return self
    }

    init(shape: EngineSession.SelectShape, options: EngineSession.SelectOptions) throws {
        func rect(_ value: CGRect) -> RecorderFileCommand.Rect {
            .init(x: value.origin.x, y: value.origin.y, width: value.size.width, height: value.size.height)
        }
        let owned: RecorderFileCommand.Shape
        switch shape {
        case .rectangle(let value): owned = .rectangle(rect(value))
        case .ellipse(let value): owned = .ellipse(rect(value))
        case .polygon(let points):
            guard (3...65_536).contains(points.count) else { throw RecorderFileError.invalid("Invalid Lab polygon point count.") }
            owned = .polygon(points.map { .init(x: $0.x, y: $0.y) })
        }
        let operation: RecorderFileCommand.Operation
        switch options.operation {
        case .replace: operation = .replace
        case .add: operation = .add
        case .subtract: operation = .subtract
        case .intersect: operation = .intersect
        }
        self = try Self.shape(owned, .init(operation: operation, antialias: options.antialias,
            feather: options.feather, cornerRadius: options.cornerRadius)).validated()
    }

    init(command: EngineSession.SelectCommand) throws {
        switch command {
        case .all: self = .command(.all)
        case .none: self = .command(.none)
        case .invert: self = .command(.invert)
        default: throw RecorderFileError.invalid("This selection command is unavailable for Lab recordings.")
        }
    }

    func apply(session: EngineSession, image: Int32) throws {
        _ = try validated()
        switch self {
        case .command(let selection):
            let command: EngineSession.SelectCommand
            switch selection { case .all: command = .all; case .none: command = .none; case .invert: command = .invert }
            try session.selectLab(command, image: image)
        case .shape(let shape, let options):
            func rect(_ value: RecorderFileCommand.Rect) -> CGRect {
                .init(x: value.x, y: value.y, width: value.width, height: value.height)
            }
            let native: EngineSession.SelectShape
            switch shape {
            case .rectangle(let value): native = .rectangle(rect(value))
            case .ellipse(let value): native = .ellipse(rect(value))
            case .polygon(let points): native = .polygon(points.map { .init(x: $0.x, y: $0.y) })
            }
            var settings = EngineSession.SelectOptions()
            switch options.operation {
            case .replace: settings.operation = .replace
            case .add: settings.operation = .add
            case .subtract: settings.operation = .subtract
            case .intersect: settings.operation = .intersect
            }
            settings.antialias = options.antialias; settings.feather = options.feather
            settings.cornerRadius = options.cornerRadius
            try session.selectLab(native, image: image, options: settings)
        }
    }
}
