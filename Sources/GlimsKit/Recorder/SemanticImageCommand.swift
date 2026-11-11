import AppKit

/// Frontend values captured when a document admits an image/selection edit.
/// Select Alpha and color selection can read the active drawable. Replay needs
/// explicit context bindings before these values can reproduce another edit.
enum SemanticImageCommand {
    /// Immutable property values only. The explicit layer binding stays with
    /// the owning document, outside the semantic log.
    struct LayerProperties: Equatable {
        let name: String?
        let isVisible: Bool?
        let opacity: Double?
        let mode: String?

        init(_ change: EngineSession.LayerChange) {
            name = change.name
            isVisible = change.isVisible
            opacity = change.opacity
            mode = change.mode
        }

        var change: EngineSession.LayerChange {
            .init(name: name, isVisible: isVisible, opacity: opacity, mode: mode)
        }
    }

    private struct MissingLayerBinding: LocalizedError {
        var errorDescription: String? { "This recorded edit has no explicit layer binding." }
    }

    private struct MissingChannelBinding: LocalizedError {
        var errorDescription: String? { "This recorded edit has no explicit channel binding." }
    }

    case selectionShape(EngineSession.SelectShape, options: EngineSession.SelectOptions)
    case selectColor(CGPoint, options: EngineSession.SelectOptions)
    case selectCommand(EngineSession.SelectCommand, radius: Double)
    /// Channel ▸ To Selection: the explicit source channel lives in the
    /// document's runtime binding, never in this command, and may differ
    /// from the active paint target.
    case channelToSelection(EngineSession.SelectOperation)
    case transformImage(EngineSession.Transform)
    case scale(width: Int, height: Int)
    case resizeCanvas(width: Int, height: Int, offset: CGPoint, fill: RecorderColor)
    case crop(CGRect)
    case layerProperties(LayerProperties)
    case completeStroke(RecorderStrokeCommand)

    /// The same resolve-first policy used by these live image services.
    var requiresResolvedFloatingSelection: Bool {
        switch self {
        case .transformImage, .scale, .resizeCanvas, .crop, .completeStroke: return true
        case .selectionShape, .selectColor, .selectCommand, .channelToSelection, .layerProperties: return false
        }
    }

    var title: String {
        switch self {
        case .selectionShape(let shape, _):
            switch shape {
            case .rectangle: return "Rectangle Selection"
            case .ellipse: return "Ellipse Selection"
            case .polygon: return "Polygon Selection"
            }
        case .selectColor: return "Select Color"
        case .selectCommand(let command, _):
            switch command {
            case .all: return "Select All"
            case .none: return "Select None"
            case .invert: return "Invert Selection"
            case .feather: return "Feather Selection"
            case .grow: return "Grow Selection"
            case .shrink: return "Shrink Selection"
            case .border: return "Border Selection"
            case .sharpen: return "Sharpen Selection"
            case .fromAlpha: return "Select Alpha"
            }
        case .channelToSelection: return "Channel to Selection"
        case .transformImage(let transform):
            switch transform {
            case .rotate90: return "Rotate Image 90°"
            case .rotate180: return "Rotate Image 180°"
            case .rotate270: return "Rotate Image 270°"
            case .flipHorizontal: return "Flip Image Horizontally"
            case .flipVertical: return "Flip Image Vertically"
            }
        case .scale: return "Scale Image"
        case .resizeCanvas: return "Resize Canvas"
        case .crop: return "Crop Image"
        case .layerProperties: return "Layer Properties"
        case .completeStroke(let stroke): return stroke.title
        }
    }

    /// Execute only on the document's engine queue. The image handle is supplied
    /// for this execution and is never retained in the semantic command.
    func apply(session: EngineSession, image: Int32) throws {
        switch self {
        case .selectionShape(let shape, let options):
            try session.select(shape, image: image, options: options)
        case .selectColor(let point, let options):
            try session.selectColor(at: point, image: image, options: options)
        case .selectCommand(let command, let radius):
            try session.select(command, image: image, radius: radius)
        case .transformImage(let transform):
            try session.transformImage(image, transform)
        case .scale(let width, let height):
            try session.scaleImage(image, width: width, height: height)
        case .resizeCanvas(let width, let height, let offset, let fill):
            try session.resizeCanvas(image, width: width, height: height, offset: offset, fill: fill)
        case .crop(let rect):
            try session.crop(image: image, to: rect)
        case .layerProperties, .completeStroke:
            throw MissingLayerBinding()
        case .channelToSelection:
            throw MissingChannelBinding()
        }
    }

    /// The caller freshly confirms this runtime layer against the owning image.
    /// It is never stored in the command and never falls back to selection.
    func apply(session: EngineSession, image: Int32, layer: Int32) throws {
        switch self {
        case .layerProperties(let properties):
            guard layer > 0 else { throw MissingLayerBinding() }
            try session.changeLayer(layer, image: image, properties.change)
        case .completeStroke(let stroke):
            guard layer > 0 else { throw MissingLayerBinding() }
            try stroke.apply(session: session, image: image, layer: layer)
        default:
            try apply(session: session, image: image)
        }
    }

    /// The caller freshly confirms this runtime channel against the owning
    /// image. It is never stored in the command and never falls back to the
    /// active paint target or selection.
    func apply(session: EngineSession, image: Int32, channel: Int32) throws {
        switch self {
        case .channelToSelection(let operation):
            guard channel > 0 else { throw MissingChannelBinding() }
            try session.channelToSelection(channel, image: image, operation: operation)
        default:
            try apply(session: session, image: image)
        }
    }
}
