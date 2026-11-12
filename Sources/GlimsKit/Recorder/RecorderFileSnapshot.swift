import Foundation
import CoreGraphics

extension RecorderFileCodec {
    /// A detached candidate only. This reads no document/native state, performs
    /// no file I/O and cannot replace the live log. Missing metadata never
    /// triggers a late lookup or a successfully encoded prefix.
    static func snapshot(_ log: RecorderLog<SemanticImageCommand>, recordingID: UUID, name: String,
                         origin: RecorderFileValue.Origin, descriptions: RecorderDescriptionCatalog,
                         bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
        guard !log.isRecording, !log.isReplaying, log.pendingCount == 0 else {
            throw RecorderFileError.invalid("Stop recording/replay and wait for every accepted command before saving.")
        }
        guard log.records.count <= RecorderFileLimits.records else { throw RecorderFileError.invalid("Too many recording rows.") }
        var required: Set<UUID> = []
        var pointCount = 0
        let records = try log.records.map { record -> RecorderFileValue.Record in
            let outcome: RecorderFileValue.Outcome
            switch record.resolution {
            case .success(let command):
                switch command {
                case .selectionShape(.polygon(let points), _):
                    guard points.count <= RecorderFileLimits.points - pointCount else { throw RecorderFileError.invalid("Invalid polygon point count.") }
                    pointCount += points.count
                case .completeStroke(let stroke):
                    let count = try RecorderFileLimits.strokePointCount(stroke.trace, remaining: RecorderFileLimits.points - pointCount)
                    pointCount += count
                default: break
                }
                let value = try RecorderFileCommand(command)
                let binding: RecorderBindingDescription
                if let captured = bindings[record.ordinal] { binding = captured }
                else if value.isTargetIndependent { binding = .none }
                else { throw RecorderFileError.invalid("This older command has no capture-time binding description; record it again.") }
                required.formUnion(try referencedSymbols(binding))
                guard required.count <= RecorderFileLimits.symbols else { throw RecorderFileError.invalid("Too many recording symbols.") }
                outcome = .success(value, binding)
            case .failure(let reason): outcome = .failure(reason)
            case .cancelled(let reason): outcome = .cancelled(reason)
            }
            return .init(ordinal: record.ordinal, outcome: outcome)
        }
        let symbols = try required.sorted { $0.uuidString < $1.uuidString }.map { id -> RecorderFileValue.Symbol in
            guard let observation = descriptions.values[id] else { throw RecorderFileError.invalid("An original target description is missing; record it again.") }
            guard case .available(let description) = observation else { throw RecorderFileError.invalid("An original target description was unavailable when recorded; record it again.") }
            return .init(id: id, description: description)
        }
        let result = RecorderFileValue(recordingID: recordingID, name: name, origin: origin, symbols: symbols, records: records)
        // Enforce the complete format contract even before a caller writes bytes.
        _ = try encode(result)
        return result
    }
}

extension RecorderFileCommand {
    init(_ command: SemanticImageCommand) throws {
        func point(_ value: CGPoint) -> Point { .init(x: Double(value.x), y: Double(value.y)) }
        func rect(_ value: CGRect) -> Rect { .init(x: Double(value.origin.x), y: Double(value.origin.y), width: Double(value.size.width), height: Double(value.size.height)) }
        func options(_ value: EngineSession.SelectOptions) -> Options {
            let operation: Operation
            switch value.operation {
            case .replace: operation = .replace
            case .add: operation = .add
            case .subtract: operation = .subtract
            case .intersect: operation = .intersect
            }
            return .init(operation: operation, antialias: value.antialias, feather: value.feather, cornerRadius: value.cornerRadius,
                threshold: value.threshold, contiguous: value.contiguous, sampleMerged: value.sampleMerged)
        }
        switch command {
        case .selectionShape(let shape, let settings):
            let result: Shape
            switch shape {
            case .rectangle(let value): result = .rectangle(rect(value))
            case .ellipse(let value): result = .ellipse(rect(value))
            case .polygon(let values):
                guard values.count >= 3, values.count <= RecorderFileLimits.points else { throw RecorderFileError.invalid("Invalid polygon point count.") }
                result = .polygon(values.map(point))
            }
            self = .selectionShape(result, options(settings))
        case .selectColor(let value, let settings): self = .selectColor(point(value), options(settings))
        case .selectCommand(let value, let radius):
            let command: Selection
            switch value {
            case .all: command = .all
            case .none: command = .none
            case .invert: command = .invert
            case .feather: command = .feather
            case .grow: command = .grow
            case .shrink: command = .shrink
            case .border: command = .border
            case .sharpen: command = .sharpen
            case .fromAlpha: command = .fromAlpha
            }
            self = .selectCommand(command, radius: radius)
        case .channelToSelection(let operation):
            let value: Operation
            switch operation {
            case .replace: value = .replace
            case .add: value = .add
            case .subtract: value = .subtract
            case .intersect: value = .intersect
            }
            self = .channelToSelection(value)
        case .transformImage(let value):
            let transform: Transform
            switch value {
            case .rotate90: transform = .rotate90
            case .rotate180: transform = .rotate180
            case .rotate270: transform = .rotate270
            case .flipHorizontal: transform = .flipHorizontal
            case .flipVertical: transform = .flipVertical
            }
            self = .transformImage(transform)
        case .scale(let width, let height): self = .scale(width: width, height: height)
        case .resizeCanvas(let width, let height, let offset, let fill): self = .resizeCanvas(width: width, height: height, offset: point(offset), fill: fill)
        case .crop(let value): self = .crop(rect(value))
        case .layerProperties(let value): self = .layerProperties(.init(name: value.name, visible: value.isVisible, opacity: value.opacity,
            mode: try value.mode.map { try RecorderFileLayerMode($0) }))
        case .transformLayer(let matrix, let interpolation):
            let value: LayerInterpolation
            switch interpolation {
            case .none: value = .none
            case .linear: value = .linear
            case .cubic: value = .cubic
            case .noHalo: value = .noHalo
            case .loHalo: value = .loHalo
            }
            self = .transformLayer(.init(a: Double(matrix.a), b: Double(matrix.b), c: Double(matrix.c),
                d: Double(matrix.d), tx: Double(matrix.tx), ty: Double(matrix.ty)), interpolation: value)
        case .transformProjectiveLayer(let matrix, let interpolation):
            let value: LayerInterpolation
            switch interpolation {
            case .none: value = .none
            case .linear: value = .linear
            case .cubic: value = .cubic
            case .noHalo: value = .noHalo
            case .loHalo: value = .loHalo
            }
            self = .transformProjectiveLayer(try Projective(matrix).validated(), interpolation: value)
        case .applyLevels(let settings):
            let trc: Levels.TRC
            switch settings.trc {
            case .linear: trc = .linear
            case .nonlinear: trc = .nonlinear
            case .perceptual: trc = .perceptual
            case .unknown: throw RecorderFileError.invalid("A recorded Levels transfer curve is unknown.")
            }
            func channel(_ channel: EngineSession.LevelsSettings.Channel) -> Levels.Channel {
                .init(lowInput: channel.lowInput, highInput: channel.highInput, gamma: channel.gamma,
                      lowOutput: channel.lowOutput, highOutput: channel.highOutput)
            }
            self = .applyLevels(.init(trc: trc, clampInput: settings.clampInput, clampOutput: settings.clampOutput,
                value: channel(settings.value), red: channel(settings.red), green: channel(settings.green),
                blue: channel(settings.blue), alpha: channel(settings.alpha)))
        case .applyCurves(let settings): self = .applyCurves(try RecorderCurvesValue(settings))
        case .applyColorBalance(let settings): self = .applyColorBalance(try RecorderColorBalanceValue(settings))
        case .applyHueSaturation(let settings): self = .applyHueSaturation(try RecorderHueSaturationValue(settings))
        case .applyBrightnessContrast(let settings): self = .applyBrightnessContrast(try RecorderBrightnessContrastValue(settings))
        case .editInk(let settings):
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded ink edit has invalid settings.") }
            let operation: RecorderFileCommand.InkEdit.Operation
            switch settings.operation {
            case .fill: operation = .fill
            case .clear: operation = .clear
            case .invert: operation = .invert
            }
            self = .editInk(.init(operation: operation, intensity: settings.intensity, opacity: settings.opacity))
        case .applyInkLevels(let settings):
            guard settings.isValid else { throw RecorderFileError.invalid("A recorded ink Levels adjustment has invalid settings.") }
            self = .applyInkLevels(.init(lowInput: settings.value.lowInput, highInput: settings.value.highInput,
                                         gamma: settings.value.gamma, lowOutput: settings.value.lowOutput,
                                         highOutput: settings.value.highOutput,
                                         clampInput: settings.clampInput, clampOutput: settings.clampOutput))
        case .completeStroke(let value): self = .completeStroke(value)
        }
    }
}
