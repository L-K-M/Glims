import Foundation

extension RecorderFileCodec {
    static func json(_ value: RecorderFileValue) throws -> RecorderJSON {
        guard value.records.count <= RecorderFileLimits.records, value.symbols.count <= RecorderFileLimits.symbols else {
            throw RecorderFileError.invalid("The recording exceeds the record/symbol limit.")
        }
        var pointCount = 0
        for record in value.records {
            if case .success(.selectionShape(.polygon(let points), _), _) = record.outcome {
                guard points.count >= 3, points.count <= RecorderFileLimits.polygonPoints - pointCount else {
                    throw RecorderFileError.invalid("Invalid polygon point count.")
                }
                pointCount += points.count
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
        let symbols = try value.symbols.map { symbol in
            RecorderJSON.object(["id": id(symbol.id), "description": try descriptionJSON(symbol.description)])
        }
        return .object(["format": .string(format), "version": j(version), "recordingID": id(value.recordingID), "name": .string(value.name),
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
