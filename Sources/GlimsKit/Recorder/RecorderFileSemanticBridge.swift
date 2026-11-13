import CoreGraphics
import Foundation

/// Pure preparation only: complete owned file metadata and a fresh detached
/// semantic log. Native target bindings, live installation and user consent
/// belong to a later document transaction, never this bridge.
enum RecorderFileSemanticBridge {
    struct PreparedRecording {
        /// Retain the entire file, including unused descriptions and every
        /// unsuccessful inspection row, for a faithful unchanged Save As.
        let file: RecorderFileValue
        let log: RecorderLog<SemanticImageCommand>

        fileprivate init(file: RecorderFileValue, log: RecorderLog<SemanticImageCommand>) {
            self.file = file
            self.log = log
        }
    }

    static func prepare(_ file: RecorderFileValue) throws -> PreparedRecording {
        // Caller-created values need the same whole-file semantic/resource
        // validation as decoded bytes. Never convert a successful prefix.
        _ = try RecorderFileCodec.encode(file)
        let records = try file.records.map { row -> RecorderLog<SemanticImageCommand>.Record in
            let resolution: RecorderLog<SemanticImageCommand>.Resolution
            switch row.outcome {
            case .success(let value, _): resolution = .success(try command(value))
            case .failure(let reason): resolution = .failure(reason)
            case .cancelled(let reason): resolution = .cancelled(reason)
            }
            return .init(ordinal: row.ordinal, resolution: resolution)
        }
        let log = try RecorderLog<SemanticImageCommand>(settledRecords: records)
        return PreparedRecording(file: file, log: log)
    }

    private static func point(_ value: RecorderFileCommand.Point) -> CGPoint {
        .init(x: CGFloat(value.x), y: CGFloat(value.y))
    }
    private static func rect(_ value: RecorderFileCommand.Rect) -> CGRect {
        // Preserve signed raw size; CoreGraphics derives standardized extents.
        .init(x: CGFloat(value.x), y: CGFloat(value.y), width: CGFloat(value.width), height: CGFloat(value.height))
    }
    private static func options(_ value: RecorderFileCommand.Options) -> EngineSession.SelectOptions {
        let operation: EngineSession.SelectOperation
        switch value.operation {
        case .replace: operation = .replace
        case .add: operation = .add
        case .subtract: operation = .subtract
        case .intersect: operation = .intersect
        }
        return .init(operation: operation, antialias: value.antialias, feather: value.feather,
                     cornerRadius: value.cornerRadius, threshold: value.threshold,
                     contiguous: value.contiguous, sampleMerged: value.sampleMerged)
    }

    private static func command(_ value: RecorderFileCommand) throws -> SemanticImageCommand {
        switch value {
        case .labSelection(let command): return .labSelection(try command.validated())
        case .selectionShape(let shape, let settings):
            let frontendShape: EngineSession.SelectShape
            switch shape {
            case .rectangle(let value): frontendShape = .rectangle(rect(value))
            case .ellipse(let value): frontendShape = .ellipse(rect(value))
            case .polygon(let values): frontendShape = .polygon(values.map(point))
            }
            return .selectionShape(frontendShape, options: options(settings))
        case .selectColor(let value, let settings): return .selectColor(point(value), options: options(settings))
        case .selectCommand(let value, let radius):
            let selection: EngineSession.SelectCommand
            switch value {
            case .all: selection = .all
            case .none: selection = .none
            case .invert: selection = .invert
            case .feather: selection = .feather
            case .grow: selection = .grow
            case .shrink: selection = .shrink
            case .border: selection = .border
            case .sharpen: selection = .sharpen
            case .fromAlpha: selection = .fromAlpha
            }
            return .selectCommand(selection, radius: radius)
        case .channelToSelection(let value):
            let operation: EngineSession.SelectOperation
            switch value {
            case .replace: operation = .replace
            case .add: operation = .add
            case .subtract: operation = .subtract
            case .intersect: operation = .intersect
            }
            return .channelToSelection(operation)
        case .transformImage(let value):
            let transform: EngineSession.Transform
            switch value {
            case .rotate90: transform = .rotate90
            case .rotate180: transform = .rotate180
            case .rotate270: transform = .rotate270
            case .flipHorizontal: transform = .flipHorizontal
            case .flipVertical: transform = .flipVertical
            }
            return .transformImage(transform)
        case .scale(let width, let height): return .scale(width: width, height: height)
        case .resizeCanvas(let width, let height, let offset, let fill):
            return .resizeCanvas(width: width, height: height, offset: point(offset), fill: fill)
        case .crop(let value): return .crop(rect(value))
        case .layerProperties(let value):
            let change = EngineSession.LayerChange(name: value.name, isVisible: value.visible,
                                                   opacity: value.opacity, mode: value.mode?.name)
            return .layerProperties(SemanticImageCommand.LayerProperties(change))
        case .transformLayer(let matrix, let interpolation):
            let value: EngineSession.Interpolation
            switch interpolation {
            case .none: value = .none
            case .linear: value = .linear
            case .cubic: value = .cubic
            case .noHalo: value = .noHalo
            case .loHalo: value = .loHalo
            }
            return .transformLayer(matrix: CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c,
                d: matrix.d, tx: matrix.tx, ty: matrix.ty), interpolation: value)
        case .transformProjectiveLayer(let matrix, let interpolation):
            let value: EngineSession.Interpolation
            switch interpolation {
            case .none: value = .none
            case .linear: value = .linear
            case .cubic: value = .cubic
            case .noHalo: value = .noHalo
            case .loHalo: value = .loHalo
            }
            return .transformProjectiveLayer(matrix: matrix.projectiveTransform, interpolation: value)
        case .applyLevels(let levels):
            let trc: EngineSession.ColorTRC
            switch levels.trc {
            case .linear: trc = .linear
            case .nonlinear: trc = .nonlinear
            case .perceptual: trc = .perceptual
            }
            func channel(_ channel: RecorderFileCommand.Levels.Channel) -> EngineSession.LevelsSettings.Channel {
                .init(lowInput: channel.lowInput, highInput: channel.highInput, gamma: channel.gamma,
                      lowOutput: channel.lowOutput, highOutput: channel.highOutput)
            }
            var settings = EngineSession.LevelsSettings()
            settings.trc = trc
            settings.clampInput = levels.clampInput
            settings.clampOutput = levels.clampOutput
            settings.value = channel(levels.value)
            settings.red = channel(levels.red)
            settings.green = channel(levels.green)
            settings.blue = channel(levels.blue)
            settings.alpha = channel(levels.alpha)
            return .applyLevels(settings)
        case .applyCurves(let value): return .applyCurves(try value.settings())
        case .applyColorBalance(let value): return .applyColorBalance(try value.settings())
        case .applyHueSaturation(let value): return .applyHueSaturation(try value.settings())
        case .applyBrightnessContrast(let value): return .applyBrightnessContrast(try value.settings())
        case .editInk(let value):
            let operation: EngineSession.InkEditOperation
            switch value.operation {
            case .fill: operation = .fill
            case .clear: operation = .clear
            case .invert: operation = .invert
            }
            let settings = EngineSession.InkEdit(operation: operation, intensity: value.intensity, opacity: value.opacity)
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded ink edit has invalid settings.") }
            return .editInk(settings)
        case .applyInkLevels(let value):
            let settings = EngineSession.InkLevelsSettings(
                value: .init(lowInput: value.lowInput, highInput: value.highInput, gamma: value.gamma,
                             lowOutput: value.lowOutput, highOutput: value.highOutput),
                clampInput: value.clampInput, clampOutput: value.clampOutput)
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded ink Levels adjustment has invalid settings.") }
            return .applyInkLevels(settings)
        case .completeLabStroke(let value): return .completeLabStroke(try value.validated())
        case .completeInkStroke(let value): return .completeInkStroke(try value.validated())
        case .fillLab(let value): return .fillLab(value: value.value, opacity: value.opacity)
        case .applyLabLevels(let value):
            let settings = EngineSession.LabLevelsSettings(
                value: .init(lowInput: value.lowInput, highInput: value.highInput, gamma: value.gamma,
                             lowOutput: value.lowOutput, highOutput: value.highOutput),
                clampInput: value.clampInput, clampOutput: value.clampOutput)
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded Lab Levels adjustment has invalid settings.") }
            return .applyLabLevels(settings)
        case .applyLabCurves(let value):
            let settings = EngineSession.LabCurvesSettings(samples: value.samples)
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded Lab Curves adjustment has invalid settings.") }
            return .applyLabCurves(settings)
        case .applyInkCurves(let value):
            let settings = EngineSession.InkCurvesSettings(samples: value.samples)
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded ink Curves adjustment has invalid settings.") }
            return .applyInkCurves(settings)
        case .completeStroke(let value): return .completeStroke(value)
        }
    }
}
