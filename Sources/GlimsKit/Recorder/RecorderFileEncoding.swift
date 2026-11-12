import Foundation

extension RecorderFileCodec {
    static func json(_ value: RecorderFileValue) throws -> RecorderJSON {
        guard value.records.count <= RecorderFileLimits.records, value.symbols.count <= RecorderFileLimits.symbols else {
            throw RecorderFileError.invalid("The recording exceeds the record/symbol limit.")
        }
        var pointCount = 0
        var fileVersion = version
        var inkIdentities: [UUID: RecorderInkIdentity] = [:]
        var hasInkCurves = false
        for record in value.records {
            switch record.outcome {
            case .success(.selectionShape(.polygon(let points), _), _):
                guard points.count >= 3, points.count <= RecorderFileLimits.points - pointCount else {
                    throw RecorderFileError.invalid("Invalid polygon point count.")
                }
                pointCount += points.count
            case .success(.completeStroke(let stroke), _):
                let count = try RecorderFileLimits.strokePointCount(stroke.trace, remaining: RecorderFileLimits.points - pointCount)
                pointCount += count
                fileVersion = max(fileVersion, strokeVersion)
            case .success(.channelToSelection, _):
                // Version 3 covers both extensions; keep the highest.
                fileVersion = max(fileVersion, channelVersion)
            case .success(.transformLayer, _):
                fileVersion = max(fileVersion, layerTransformVersion)
            case .success(.transformProjectiveLayer, _):
                fileVersion = max(fileVersion, projectiveLayerTransformVersion)
            case .success(.applyLevels, _):
                fileVersion = max(fileVersion, levelsVersion)
            case .success(.applyCurves(let curves), _):
                let count = curves.value.points.count + curves.red.points.count + curves.green.points.count
                    + curves.blue.points.count + curves.alpha.points.count
                guard count <= RecorderFileLimits.points - pointCount else {
                    throw RecorderFileError.invalid("Invalid Curves point count.")
                }
                pointCount += count
                fileVersion = max(fileVersion, curvesVersion)
            case .success(.applyColorBalance, _):
                fileVersion = max(fileVersion, colorBalanceVersion)
            case .success(.applyHueSaturation, _):
                fileVersion = max(fileVersion, hueSaturationVersion)
            case .success(.applyBrightnessContrast, _):
                fileVersion = max(fileVersion, brightnessContrastVersion)
            case .success(.editInk, let binding), .success(.applyInkLevels, let binding):
                fileVersion = max(fileVersion, inkVersion)
                if case .ink(let symbol, let identity) = binding {
                    if let seen = inkIdentities[symbol], seen != identity {
                        throw RecorderFileError.invalid("Ink identity is inconsistent across records.")
                    }
                    inkIdentities[symbol] = identity
                }
            case .success(.applyInkCurves, let binding):
                fileVersion = max(fileVersion, inkCurvesVersion)
                hasInkCurves = true
                if case .ink(let symbol, let identity) = binding {
                    if let seen = inkIdentities[symbol], seen != identity {
                        throw RecorderFileError.invalid("Ink identity is inconsistent across records.")
                    }
                    inkIdentities[symbol] = identity
                }
            default: break
            }
        }
        let records = try value.records.map { record -> RecorderJSON in
            var fields: [String: RecorderJSON] = ["ordinal": j(record.ordinal)]
            switch record.outcome {
            case .success(let command, let binding):
                fields["outcome"] = .string("success")
                fields["command"] = try commandJSON(command)
                fields["binding"] = try bindingJSON(binding)
            case .failure(let reason): fields["outcome"] = .string("failure"); fields["reason"] = .string(reason)
            case .cancelled(let reason): fields["outcome"] = .string("cancelled"); fields["reason"] = .string(reason)
            }
            return .object(fields)
        }
        if fileVersion == inkCurvesVersion, !hasInkCurves {
            throw RecorderFileError.invalid("Version 12 requires a successful ink Curves command.")
        }
        let symbols = try value.symbols.map { symbol in
            RecorderJSON.object(["id": id(symbol.id), "description": try descriptionJSON(symbol.description)])
        }
        return .object(["format": .string(format), "version": j(fileVersion), "recordingID": id(value.recordingID), "name": .string(value.name),
            "origin": .object(["imageLabel": .string(value.origin.imageLabel), "initialWidth": j(value.origin.initialWidth), "initialHeight": j(value.origin.initialHeight)]),
            "symbols": .array(symbols), "records": .array(records)])
    }

    private static func j(_ value: Int) -> RecorderJSON { .number(String(value), Double(value)) }
    private static func d(_ value: Double) throws -> RecorderJSON {
        guard value.isFinite else { throw RecorderFileError.invalid("A recorded number is not finite.") }
        return .number(String(value), value)
    }
    private static func id(_ value: UUID) -> RecorderJSON { .string(value.uuidString.lowercased()) }
    private static func pointJSON(_ value: RecorderFileCommand.Point) throws -> RecorderJSON {
        .object(["x": try d(value.x), "y": try d(value.y)])
    }
    private static func rectJSON(_ value: RecorderFileCommand.Rect) throws -> RecorderJSON {
        .object(["x": try d(value.x), "y": try d(value.y), "width": try d(value.width), "height": try d(value.height)])
    }
    private static func optionsJSON(_ value: RecorderFileCommand.Options) throws -> RecorderJSON {
        .object(["operation": .string(value.operation.rawValue), "antialias": .bool(value.antialias), "feather": try d(value.feather),
            "cornerRadius": try d(value.cornerRadius), "threshold": try d(value.threshold), "contiguous": .bool(value.contiguous), "sampleMerged": .bool(value.sampleMerged)])
    }
    private static func colorJSON(_ value: RecorderColor) throws -> RecorderJSON {
        .object(["space": .string("srgb"), "red": try d(value.red), "green": try d(value.green), "blue": try d(value.blue), "alpha": try d(value.alpha)])
    }
    private static func strokePointJSON(_ value: RecorderStrokeTrace.Point) throws -> RecorderJSON {
        .object(["x": try d(value.x), "y": try d(value.y), "pressure": try d(value.pressure),
            "xTilt": try d(value.xTilt), "yTilt": try d(value.yTilt), "timeMilliseconds": j(Int(value.timeMilliseconds))])
    }
    private static func strokeJSON(_ value: RecorderStrokeCommand) throws -> RecorderJSON {
        let brush = value.settings
        var settings: [String: RecorderJSON] = [
            "tool": .string(brush.tool.rawValue), "size": try d(brush.size), "opacity": try d(brush.opacity),
            "red": try d(brush.red), "green": try d(brush.green), "blue": try d(brush.blue),
            "pressureSize": .bool(brush.pressureSize), "antiErase": .bool(brush.antiErase),
        ]
        if let hardness = brush.hardness { settings["hardness"] = try d(hardness) }
        let identity = value.facts.brush
        var brushIdentity: [String: RecorderJSON] = ["name": .string(identity.name), "isInternal": .bool(identity.isInternal)]
        if let collection = identity.collection { brushIdentity["collection"] = .string(collection) }
        let facts = RecorderJSON.object(["brush": .object(brushIdentity), "fingerprint": .string(value.facts.fingerprint)])
        let batches = try value.trace.batches.map { RecorderJSON.array(try $0.map(strokePointJSON)) }
        return .object(["tag": .string("completeStroke"), "settings": .object(settings), "facts": facts,
                        "first": try strokePointJSON(value.trace.first), "batches": .array(batches)])
    }

    private static func commandJSON(_ command: RecorderFileCommand) throws -> RecorderJSON {
        switch command {
        case .selectionShape(let shape, let options):
            let source: RecorderJSON
            switch shape {
            case .rectangle(let rect): source = .object(["tag": .string("rectangle"), "rect": try rectJSON(rect)])
            case .ellipse(let rect): source = .object(["tag": .string("ellipse"), "rect": try rectJSON(rect)])
            case .polygon(let points): source = .object(["tag": .string("polygon"), "points": .array(try points.map { try pointJSON($0) })])
            }
            return .object(["tag": .string("selectionShape"), "shape": source, "options": try optionsJSON(options)])
        case .selectColor(let point, let options):
            return .object(["tag": .string("selectColor"), "point": try pointJSON(point), "options": try optionsJSON(options)])
        case .selectCommand(let command, let radius):
            return .object(["tag": .string("selectCommand"), "command": .string(command.rawValue), "radius": try d(radius)])
        case .channelToSelection(let operation):
            return .object(["tag": .string("channelToSelection"), "operation": .string(operation.rawValue)])
        case .transformImage(let transform): return .object(["tag": .string("transformImage"), "transform": .string(transform.rawValue)])
        case .scale(let width, let height): return .object(["tag": .string("scale"), "width": j(width), "height": j(height)])
        case .resizeCanvas(let width, let height, let offset, let color):
            return .object(["tag": .string("resizeCanvas"), "width": j(width), "height": j(height), "offset": try pointJSON(offset), "fill": try colorJSON(color)])
        case .crop(let rect): return .object(["tag": .string("crop"), "rect": try rectJSON(rect)])
        case .layerProperties(let properties):
            var fields: [String: RecorderJSON] = [:]
            if let name = properties.name { fields["name"] = .string(name) }
            if let visible = properties.visible { fields["visible"] = .bool(visible) }
            if let opacity = properties.opacity { fields["opacity"] = try d(opacity) }
            if let mode = properties.mode { fields["mode"] = .string(mode.name) }
            return .object(["tag": .string("layerProperties"), "properties": .object(fields)])
        case .transformLayer(let matrix, let interpolation):
            return .object(["tag": .string("transformLayer"), "interpolation": .string(interpolation.rawValue),
                "matrix": .object(["a": try d(matrix.a), "b": try d(matrix.b), "c": try d(matrix.c),
                                   "d": try d(matrix.d), "tx": try d(matrix.tx), "ty": try d(matrix.ty)])])
        case .transformProjectiveLayer(let matrix, let interpolation):
            return .object(["tag": .string("transformProjectiveLayer"), "interpolation": .string(interpolation.rawValue),
                "matrix": .object(["h00": try d(matrix.h00), "h01": try d(matrix.h01), "h02": try d(matrix.h02),
                                   "h10": try d(matrix.h10), "h11": try d(matrix.h11), "h12": try d(matrix.h12),
                                   "h20": try d(matrix.h20), "h21": try d(matrix.h21), "h22": try d(matrix.h22)])])
        case .applyLevels(let levels):
            func channelJSON(_ channel: RecorderFileCommand.Levels.Channel) throws -> RecorderJSON {
                .object(["lowInput": try d(channel.lowInput), "highInput": try d(channel.highInput),
                    "gamma": try d(channel.gamma), "lowOutput": try d(channel.lowOutput), "highOutput": try d(channel.highOutput)])
            }
            return .object(["tag": .string("applyLevels"), "settings": .object([
                "trc": .string(levels.trc.rawValue), "clampInput": .bool(levels.clampInput),
                "clampOutput": .bool(levels.clampOutput), "value": try channelJSON(levels.value),
                "red": try channelJSON(levels.red), "green": try channelJSON(levels.green),
                "blue": try channelJSON(levels.blue), "alpha": try channelJSON(levels.alpha)])])
        case .applyCurves(let curves):
            func channelJSON(_ channel: RecorderCurvesValue.Channel) throws -> RecorderJSON {
                let channel = try channel.validated()
                return .object(["kind": .string(channel.kind.rawValue), "identity": .bool(channel.identity),
                    "points": .array(try channel.points.map {
                        .object(["x": try d($0.x), "y": try d($0.y), "kind": .string($0.kind.rawValue)]) }),
                    "samples": .array(try channel.samples.map { try d($0) })])
            }
            return .object(["tag": .string("applyCurves"), "settings": .object([
                "trc": .string(curves.trc.rawValue), "value": try channelJSON(curves.value),
                "red": try channelJSON(curves.red), "green": try channelJSON(curves.green),
                "blue": try channelJSON(curves.blue), "alpha": try channelJSON(curves.alpha)])])
        case .applyColorBalance(let balance):
            let balance = try balance.validated()
            func rangeJSON(_ range: RecorderColorBalanceValue.Range) throws -> RecorderJSON {
                .object(["cyanRed": try d(range.cyanRed), "magentaGreen": try d(range.magentaGreen),
                    "yellowBlue": try d(range.yellowBlue)])
            }
            return .object(["tag": .string("applyColorBalance"), "settings": .object([
                "shadows": try rangeJSON(balance.shadows), "midtones": try rangeJSON(balance.midtones),
                "highlights": try rangeJSON(balance.highlights),
                "preserveLuminosity": .bool(balance.preserveLuminosity)])])
        case .applyHueSaturation(let hueSaturation):
            let hueSaturation = try hueSaturation.validated()
            func rangeJSON(_ range: RecorderHueSaturationValue.Range) throws -> RecorderJSON {
                .object(["hue": try d(range.hue), "saturation": try d(range.saturation),
                    "lightness": try d(range.lightness)])
            }
            return .object(["tag": .string("applyHueSaturation"), "settings": .object([
                "overlap": try d(hueSaturation.overlap), "master": try rangeJSON(hueSaturation.master),
                "red": try rangeJSON(hueSaturation.red), "yellow": try rangeJSON(hueSaturation.yellow),
                "green": try rangeJSON(hueSaturation.green), "cyan": try rangeJSON(hueSaturation.cyan),
                "blue": try rangeJSON(hueSaturation.blue), "magenta": try rangeJSON(hueSaturation.magenta)])])
        case .applyBrightnessContrast(let value):
            let value = try value.validated()
            return .object(["tag": .string("applyBrightnessContrast"), "settings": .object([
                "brightness": try d(value.brightness), "contrast": try d(value.contrast)])])
        case .editInk(let edit):
            guard edit.isValid else { throw RecorderFileError.invalid("Invalid ink edit values.") }
            return .object(["tag": .string("editInk"), "operation": .string(edit.operation.rawValue),
                "intensity": try d(edit.intensity), "opacity": try d(edit.opacity)])
        case .applyInkLevels(let levels):
            guard levels.isValid else { throw RecorderFileError.invalid("Invalid ink Levels values.") }
            return .object(["tag": .string("applyInkLevels"), "lowInput": try d(levels.lowInput),
                "highInput": try d(levels.highInput), "gamma": try d(levels.gamma),
                "lowOutput": try d(levels.lowOutput), "highOutput": try d(levels.highOutput),
                "clampInput": .bool(levels.clampInput), "clampOutput": .bool(levels.clampOutput)])
        case .applyInkCurves(let curves):
            guard curves.isValid else { throw RecorderFileError.invalid("Invalid ink Curves values.") }
            return .object(["tag": .string("applyInkCurves"), "samples": .array(try curves.samples.map { try d($0) })])
        case .completeStroke(let stroke): return try strokeJSON(stroke)
        }
    }
    private static func descriptionKindJSON(_ value: RecorderTargetDescription.Kind) -> RecorderJSON {
        switch value {
        case .pixel: return .string("pixel")
        case .group: return .string("group")
        case .text: return .string("text")
        case .link: return .string("link")
        case .vector: return .string("vector")
        case .channel: return .string("channel")
        case .quickMask: return .string("quickMask")
        }
    }
    private static func descriptionJSON(_ value: RecorderTargetDescription) throws -> RecorderJSON {
        .object(["name": .string(value.name), "kind": descriptionKindJSON(value.kind),
            "ancestors": .array(value.ancestors.map { .object(["name": .string($0.name), "kind": descriptionKindJSON($0.kind), "siblingIndex": j($0.siblingIndex)]) }),
            "siblingIndex": j(value.siblingIndex), "bounds": try rectJSON(.init(x: value.bounds.x, y: value.bounds.y, width: value.bounds.width, height: value.bounds.height))])
    }
    private static func bindingJSON(_ value: RecorderBindingDescription) throws -> RecorderJSON {
        switch value {
        case .none: return .object(["kind": .string("none")])
        case .layer(let symbol): return .object(["kind": .string("layer"), "symbol": id(symbol)])
        case .channel(let symbol): return .object(["kind": .string("channel"), "symbol": id(symbol)])
        case .ink(let symbol, let identity):
            guard identity.isValid else { throw RecorderFileError.invalid("Invalid ink identity.") }
            return .object(["kind": .string("ink"), "symbol": id(symbol), "mode": .string(identity.mode.rawValue),
                "role": .string(identity.role.rawValue), "uuid": id(identity.uuid)])
        case .unavailable(let reason): throw RecorderFileError.invalid("The original target description is unavailable: \(reason)")
        case .context(let context):
            let target: RecorderJSON
            switch context.target {
            case .layer(let symbol): target = .object(["kind": .string("layer"), "symbol": id(symbol)])
            case .mask(let owner): target = .object(["kind": .string("mask"), "owner": id(owner)])
            case .channel(let symbol): target = .object(["kind": .string("channel"), "symbol": id(symbol)])
            case .quickMask(let symbol): target = .object(["kind": .string("quickMask"), "symbol": id(symbol)])
            }
            let masks = context.masks.map { mask in
                RecorderJSON.object(["owner": id(mask.owner), "isPresent": .bool(mask.isPresent), "enabled": .bool(mask.enabled), "editing": .bool(mask.editing), "showing": .bool(mask.showing)])
            }
            var quick: [String: RecorderJSON] = ["enabled": .bool(context.quickMask.enabled), "inverted": .bool(context.quickMask.inverted), "color": try colorJSON(context.quickMask.color)]
            if let symbol = context.quickMask.symbol { quick["symbol"] = id(symbol) }
            return .object(["kind": .string("context"), "context": .object(["layers": .array(context.layers.map(id)), "channels": .array(context.channels.map(id)),
                "target": target, "masks": .array(masks), "quickMask": .object(quick)])])
        }
    }
}
