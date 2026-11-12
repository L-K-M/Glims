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
    /// A committed Transform-tool affine in absolute image pixels, y down.
    /// The explicit layer lives in the document's runtime binding, never in
    /// this command, and is never silently adapted to a rebound layer.
    case transformLayer(matrix: CGAffineTransform, interpolation: EngineSession.Interpolation)
    /// Nine absolute image-pixel coefficients, never adapted to a rebound
    /// layer. The explicit runtime layer binding stays outside the command.
    case transformProjectiveLayer(matrix: ProjectiveTransform, interpolation: EngineSession.Interpolation)
    /// A newly applied Levels adjustment with its whole accepted native
    /// settings. The explicit layer lives in the document's runtime binding,
    /// never in this command; there is no active-layer fallback.
    case applyLevels(EngineSession.LevelsSettings)
    /// A newly applied Curves adjustment, including hidden points, actual
    /// samples and HDR bypass flags. Its layer is explicitly bound outside.
    case applyCurves(EngineSession.CurvesSettings)
    /// A newly applied Color Balance adjustment with its whole accepted
    /// native settings: all three tonal ranges and Preserve Lightness. The
    /// explicit layer lives in the document's runtime binding, never in this
    /// command; there is no active-layer fallback.
    case applyColorBalance(EngineSession.ColorBalanceSettings)
    /// A newly applied Hue/Saturation adjustment with its whole accepted
    /// native settings: the global overlap and all seven named ranges. The
    /// explicit layer lives in the document's runtime binding, never in this
    /// command; there is no active-layer fallback.
    case applyHueSaturation(EngineSession.HueSaturationSettings)
    /// A newly applied Brightness/Contrast adjustment with its whole
    /// accepted native settings. The explicit layer lives in the document's
    /// runtime binding, never in this command; there is no active-layer fallback.
    case applyBrightnessContrast(EngineSession.BrightnessContrastSettings)
    /// A committed ink-channel edit with its whole accepted native settings.
    /// The explicit channel binding stays outside the command.
    case editInk(EngineSession.InkEdit)
    /// A committed ink-channel Levels adjustment with its whole accepted
    /// native settings. The explicit channel binding stays outside the command.
    case applyInkLevels(EngineSession.InkLevelsSettings)
    case completeStroke(RecorderStrokeCommand)

    var isLayerAdjustment: Bool {
        switch self {
        case .applyLevels, .applyCurves, .applyColorBalance, .applyHueSaturation, .applyBrightnessContrast: return true
        default: return false
        }
    }

    /// The same resolve-first policy used by these live image services.
    var requiresResolvedFloatingSelection: Bool {
        switch self {
        case .transformImage, .transformLayer, .transformProjectiveLayer, .applyLevels, .applyCurves, .applyColorBalance, .applyHueSaturation, .applyBrightnessContrast, .editInk, .applyInkLevels, .scale, .resizeCanvas, .crop, .completeStroke: return true
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
        case .transformLayer: return "Transform Layer"
        case .transformProjectiveLayer: return "Transform Layer Perspective"
        case .applyLevels: return "Levels"
        case .applyCurves: return "Curves"
        case .applyColorBalance: return "Color Balance"
        case .applyHueSaturation: return "Hue/Saturation"
        case .applyBrightnessContrast: return "Brightness/Contrast"
        case .editInk(let settings): return settings.operation.title
        case .applyInkLevels: return "Ink Levels"
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
        case .layerProperties, .transformLayer, .transformProjectiveLayer, .applyLevels, .applyCurves, .applyColorBalance, .applyHueSaturation, .applyBrightnessContrast, .completeStroke:
            throw MissingLayerBinding()
        case .channelToSelection, .editInk, .applyInkLevels:
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
        case .transformLayer(let matrix, let interpolation):
            try Self.applyLayerTransform(ProjectiveTransform(affine: matrix), interpolation: interpolation,
                                         session: session, image: image, layer: layer)
        case .transformProjectiveLayer(let matrix, let interpolation):
            try Self.applyLayerTransform(matrix, interpolation: interpolation,
                                         session: session, image: image, layer: layer)
        case .applyLevels(let settings):
            guard layer > 0 else { throw MissingLayerBinding() }
            // A fresh session on the bound layer: one commit, one Undo. A
            // failed set or commit aborts the new preview so replay never
            // leaks a live filter session.
            let filter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:levels")
            do {
                try session.setLevelsSettings(filter, to: settings)
                try session.commitFilter(filter)
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        case .applyCurves(let settings):
            guard layer > 0 else { throw MissingLayerBinding() }
            let filter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:curves")
            do {
                try session.setCurvesSettings(filter, to: settings)
                try session.commitFilter(filter)
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        case .applyColorBalance(let settings):
            guard layer > 0 else { throw MissingLayerBinding() }
            let filter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:color-balance")
            do {
                try session.setColorBalanceSettings(filter, to: settings)
                try session.commitFilter(filter)
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        case .applyHueSaturation(let settings):
            guard layer > 0 else { throw MissingLayerBinding() }
            let filter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:hue-saturation")
            do {
                try session.setHueSaturationSettings(filter, to: settings)
                try session.commitFilter(filter)
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        case .applyBrightnessContrast(let settings):
            guard layer > 0 else { throw MissingLayerBinding() }
            let filter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:brightness-contrast")
            do {
                try session.setBrightnessContrastSettings(filter, to: settings)
                try session.commitFilter(filter)
            } catch {
                try? session.abortFilter(filter)
                throw error
            }
        case .completeStroke(let stroke):
            guard layer > 0 else { throw MissingLayerBinding() }
            try stroke.apply(session: session, image: image, layer: layer)
        default:
            try apply(session: session, image: image)
        }
    }

    /// Both v4 affine and v6 projective replay use the captured native API:
    /// a rebound editable source must never be rasterized implicitly. Read
    /// fresh geometry, validate the absolute mapping, then require that exact
    /// rectangle at commit to close the read/dispatch geometry race.
    private static func applyLayerTransform(_ matrix: ProjectiveTransform,
                                            interpolation: EngineSession.Interpolation,
                                            session: EngineSession, image: Int32, layer: Int32) throws {
        guard layer > 0 else { throw MissingLayerBinding() }
        guard let row = try session.layers(image).first(where: { $0.id == layer }) else {
            throw RecorderFileError.invalid("The recorded layer no longer belongs to this native image.")
        }
        let value = try RecorderFileCommand.Projective(matrix).validated()
        let bounds = row.bounds
        guard value.outputBounds(for: .init(x: bounds.origin.x, y: bounds.origin.y,
                                           width: bounds.size.width, height: bounds.size.height)) != nil else {
            throw RecorderFileError.invalid("The recorded layer transform's output bounds are unsafe for replay.")
        }
        try session.transformLayer(layer, image: image, matrix: matrix,
                                   expectedBounds: bounds, interpolation: interpolation)
    }

    /// The caller freshly confirms this runtime channel against the owning
    /// image. It is never stored in the command and never falls back to the
    /// active paint target or selection.
    func apply(session: EngineSession, image: Int32, channel: Int32) throws {
        switch self {
        case .channelToSelection(let operation):
            guard channel > 0 else { throw MissingChannelBinding() }
            try session.channelToSelection(channel, image: image, operation: operation)
        case .editInk(let settings):
            guard channel > 0 else { throw MissingChannelBinding() }
            try session.editInk(image, channel: channel, settings: settings)
        case .applyInkLevels(let settings):
            guard channel > 0 else { throw MissingChannelBinding() }
            try session.applyInkLevels(image, channel: channel, settings: settings)
        default:
            try apply(session: session, image: image)
        }
    }
}
