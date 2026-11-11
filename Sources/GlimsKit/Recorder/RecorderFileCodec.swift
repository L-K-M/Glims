import Foundation

enum RecorderFileCodec {
    static let format = "ch.lkmc.Glims.recording"
    static let version = 1
    static let strokeVersion = 2
    static let channelVersion = 3
    static let layerTransformVersion = 4
    static let projectiveLayerTransformVersion = 6
    static let levelsVersion = 5

    static func decode(_ data: Data) throws -> RecorderFileValue {
        var parser = try RecorderJSONParser(data)
        return try file(parser.parse())
    }

    static func encode(_ value: RecorderFileValue) throws -> Data {
        let node = try json(value)
        // The same full semantic validation applies to caller-created values.
        _ = try file(node)
        var writer = RecorderJSONWriter()
        return try writer.encode(node)
    }

    private struct Object {
        let members: [String: RecorderJSON]
        init(_ node: RecorderJSON, required: Set<String>, optional: Set<String> = []) throws {
            guard case .object(let members) = node else { throw RecorderFileError.invalid("Expected a JSON object.") }
            guard required.isSubset(of: Set(members.keys)), Set(members.keys).isSubset(of: required.union(optional)) else {
                throw RecorderFileError.invalid("Missing or unknown object fields.")
            }
            self.members = members
        }
        func get(_ key: String) -> RecorderJSON { members[key]! }
        func optional(_ key: String) -> RecorderJSON? { members[key] }
    }
    private static func array(_ node: RecorderJSON, maximum: Int = RecorderFileLimits.values) throws -> [RecorderJSON] {
        guard case .array(let values) = node, values.count <= maximum else { throw RecorderFileError.invalid("Invalid or oversized array.") }
        return values
    }
    private static func string(_ node: RecorderJSON, native: Bool = false) throws -> String {
        guard case .string(let value) = node, value.utf8.count <= RecorderFileLimits.stringBytes,
              !native || !value.utf8.contains(0) else { throw RecorderFileError.invalid("Invalid string.") }
        return value
    }
    private static func number(_ node: RecorderJSON) throws -> Double {
        guard case .number(_, let value) = node, value.isFinite else { throw RecorderFileError.invalid("Expected a finite number.") }
        return value
    }
    private static func integer(_ node: RecorderJSON, range: ClosedRange<Int>) throws -> Int {
        guard case .number(let token, _) = node, !token.contains("."), !token.contains("e"), !token.contains("E"),
              let value = Int(token), range.contains(value) else { throw RecorderFileError.invalid("Invalid integer.") }
        return value
    }
    private static func bool(_ node: RecorderJSON) throws -> Bool {
        guard case .bool(let value) = node else { throw RecorderFileError.invalid("Expected a Boolean.") }
        return value
    }
    private static func uuid(_ node: RecorderJSON) throws -> UUID {
        let text = try string(node)
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { throw RecorderFileError.invalid("Invalid recording symbol UUID.") }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { throw RecorderFileError.invalid("Invalid recording symbol UUID.") }
            } else {
                guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else {
                    throw RecorderFileError.invalid("Invalid recording symbol UUID.")
                }
            }
        }
        guard let value = UUID(uuidString: text) else { throw RecorderFileError.invalid("Invalid recording symbol UUID.") }
        return value
    }
    private static func tag(_ node: RecorderJSON) throws -> String {
        guard case .object(let members) = node, let value = members["tag"] else { throw RecorderFileError.invalid("Missing command tag.") }
        return try string(value)
    }
    private static func kind(_ node: RecorderJSON) throws -> String {
        guard case .object(let members) = node, let value = members["kind"] else { throw RecorderFileError.invalid("Missing kind tag.") }
        return try string(value)
    }

    private static func file(_ node: RecorderJSON) throws -> RecorderFileValue {
        let root = try Object(node, required: ["format", "version", "recordingID", "name", "origin", "symbols", "records"])
        guard try string(root.get("format")) == format else { throw RecorderFileError.invalid("Unsupported recording format/version.") }
        let fileVersion = try integer(root.get("version"), range: version...projectiveLayerTransformVersion)
        let name = try string(root.get("name"))
        guard !name.isEmpty else { throw RecorderFileError.invalid("A recording needs a name.") }
        let origin = try Object(root.get("origin"), required: ["imageLabel", "initialWidth", "initialHeight"])
        let source = RecorderFileValue.Origin(imageLabel: try string(origin.get("imageLabel")),
            initialWidth: try integer(origin.get("initialWidth"), range: 1...524288),
            initialHeight: try integer(origin.get("initialHeight"), range: 1...524288))
        let symbols = try array(root.get("symbols"), maximum: RecorderFileLimits.symbols).map { node -> RecorderFileValue.Symbol in
            let value = try Object(node, required: ["id", "description"])
            return .init(id: try uuid(value.get("id")), description: try description(value.get("description")))
        }
        var descriptions: [UUID: RecorderTargetDescription] = [:]
        for symbol in symbols {
            guard descriptions[symbol.id] == nil else { throw RecorderFileError.invalid("Duplicate recording symbol.") }
            descriptions[symbol.id] = symbol.description
        }
        var points = 0
        var hasStroke = false
        var hasChannelSelection = false
        var hasLayerTransform = false
        var hasProjectiveLayerTransform = false
        var hasLevels = false
        let records = try array(root.get("records"), maximum: RecorderFileLimits.records).enumerated().map { index, node -> RecorderFileValue.Record in
            guard case .object(let members) = node, let outcome = members["outcome"] else { throw RecorderFileError.invalid("Missing record outcome.") }
            let outcomeName = try string(outcome)
            let row: Object
            let result: RecorderFileValue.Outcome
            switch outcomeName {
            case "success":
                row = try Object(node, required: ["ordinal", "outcome", "command", "binding"])
                let command = try command(row.get("command"), version: fileVersion, points: &points)
                if case .completeStroke = command { hasStroke = true }
                if case .channelToSelection = command { hasChannelSelection = true }
                if case .transformLayer = command { hasLayerTransform = true }
                if case .transformProjectiveLayer = command { hasProjectiveLayerTransform = true }
                if case .applyLevels = command { hasLevels = true }
                let binding = try binding(row.get("binding"))
                try validate(binding, for: command, descriptions: descriptions)
                result = .success(command, binding)
            case "failure", "cancelled":
                row = try Object(node, required: ["ordinal", "outcome", "reason"])
                let reason = try string(row.get("reason"))
                result = outcomeName == "failure" ? .failure(reason) : .cancelled(reason)
            default: throw RecorderFileError.invalid("Unknown record outcome.")
            }
            guard try integer(row.get("ordinal"), range: 0...RecorderFileLimits.records) == index else {
                throw RecorderFileError.invalid("Record ordinals must be contiguous from zero.")
            }
            return .init(ordinal: index, outcome: result)
        }
        // Each extended version requires its own successful command, exactly
        // as version 2 always required a complete stroke.
        if fileVersion == strokeVersion, !hasStroke {
            throw RecorderFileError.invalid("Version 2 requires a successful complete stroke.")
        }
        if fileVersion == channelVersion, !hasChannelSelection {
            throw RecorderFileError.invalid("Version 3 requires a successful channel selection.")
        }
        if fileVersion == layerTransformVersion, !hasLayerTransform {
            throw RecorderFileError.invalid("Version 4 requires a successful layer transform.")
        }
        if fileVersion == projectiveLayerTransformVersion, !hasProjectiveLayerTransform {
            throw RecorderFileError.invalid("Version 6 requires a successful projective layer transform.")
        }
        if fileVersion == levelsVersion, !hasLevels {
            throw RecorderFileError.invalid("Version 5 requires a successful Levels command.")
        }
        return RecorderFileValue(recordingID: try uuid(root.get("recordingID")), name: name, origin: source, symbols: symbols, records: records)
    }

    private static func point(_ node: RecorderJSON) throws -> RecorderFileCommand.Point {
        let value = try Object(node, required: ["x", "y"])
        return RecorderFileCommand.Point(x: try number(value.get("x")), y: try number(value.get("y")))
    }
    private static func rect(_ node: RecorderJSON) throws -> RecorderFileCommand.Rect {
        let value = try Object(node, required: ["x", "y", "width", "height"])
        return .init(x: try number(value.get("x")), y: try number(value.get("y")),
                     width: try number(value.get("width")), height: try number(value.get("height")))
    }
    private static func nativeInteger(_ value: Double) throws {
        guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
            throw RecorderFileError.invalid("Geometry cannot be represented by the native command.")
        }
    }
    private static func options(_ node: RecorderJSON) throws -> RecorderFileCommand.Options {
        let value = try Object(node, required: ["operation", "antialias", "feather", "cornerRadius", "threshold", "contiguous", "sampleMerged"])
        guard let operation = RecorderFileCommand.Operation(rawValue: try string(value.get("operation"))) else {
            throw RecorderFileError.invalid("Unknown selection operation.")
        }
        return .init(operation: operation, antialias: try bool(value.get("antialias")), feather: try number(value.get("feather")),
            cornerRadius: try number(value.get("cornerRadius")), threshold: try number(value.get("threshold")),
            contiguous: try bool(value.get("contiguous")), sampleMerged: try bool(value.get("sampleMerged")))
    }
    private static func color(_ node: RecorderJSON) throws -> RecorderColor {
        let value = try Object(node, required: ["space", "red", "green", "blue", "alpha"])
        guard try string(value.get("space")) == "srgb" else { throw RecorderFileError.invalid("Unknown color space.") }
        let red = try number(value.get("red")), green = try number(value.get("green"))
        let blue = try number(value.get("blue")), alpha = try number(value.get("alpha"))
        do { return try RecorderColor(red: red, green: green, blue: blue, alpha: alpha) }
        catch { throw RecorderFileError.invalid("sRGB components must be finite and inside 0...1.") }
    }
    private static func strokePoint(_ node: RecorderJSON) throws -> RecorderStrokeTrace.Point {
        let point = try Object(node, required: ["x", "y", "pressure", "xTilt", "yTilt", "timeMilliseconds"])
        do {
            return try .init(x: number(point.get("x")), y: number(point.get("y")),
                pressure: number(point.get("pressure")), xTilt: number(point.get("xTilt")), yTilt: number(point.get("yTilt")),
                timeMilliseconds: UInt32(integer(point.get("timeMilliseconds"), range: 0...Int(UInt32.max))))
        } catch {
            throw RecorderFileError.invalid("Invalid stroke sample.")
        }
    }

    private static func stroke(_ node: RecorderJSON, points: inout Int) throws -> RecorderStrokeCommand {
        let value = try Object(node, required: ["tag", "settings", "facts", "first", "batches"])
        let settings = try Object(value.get("settings"),
            required: ["tool", "size", "opacity", "red", "green", "blue", "pressureSize", "antiErase"], optional: ["hardness"])
        guard let tool = RecorderStrokeCommand.Tool(rawValue: try string(settings.get("tool"))),
              let brush = try RecorderStrokeCommand.Settings(tool: tool, size: number(settings.get("size")),
                  opacity: number(settings.get("opacity")), red: number(settings.get("red")),
                  green: number(settings.get("green")), blue: number(settings.get("blue")),
                  hardness: settings.optional("hardness").map { try number($0) },
                  pressureSize: bool(settings.get("pressureSize")), antiErase: bool(settings.get("antiErase"))) else {
            throw RecorderFileError.invalid("Invalid recorded brush settings.")
        }
        let facts = try Object(value.get("facts"), required: ["brush", "fingerprint"])
        let identity = try Object(facts.get("brush"), required: ["name", "isInternal"], optional: ["collection"])
        let name = try string(identity.get("name"), native: true)
        let collection = try identity.optional("collection").map { try string($0, native: true) }
        let fingerprint = try string(facts.get("fingerprint"))
        guard !name.isEmpty, fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecorderFileError.invalid("Invalid recorded brush identity or fingerprint.")
        }
        let maximum = min(RecorderStrokeAccumulator.maximumPoints, RecorderFileLimits.points - points)
        guard maximum >= 1 else { throw RecorderFileError.invalid("Invalid stroke point count.") }
        let first = try strokePoint(value.get("first"))
        var count = 1
        let batches = try array(value.get("batches"), maximum: maximum - 1).map { batch -> [RecorderStrokeTrace.Point] in
            let samples = try array(batch, maximum: maximum - count)
            guard !samples.isEmpty else { throw RecorderFileError.invalid("A recorded stroke batch cannot be empty.") }
            count += samples.count
            return try samples.map(strokePoint)
        }
        points += count
        return .init(settings: brush, trace: .init(first: first, batches: batches),
                     facts: .init(brush: .init(name: name, collection: collection,
                                              isInternal: try bool(identity.get("isInternal"))), fingerprint: fingerprint))
    }

    private static func command(_ node: RecorderJSON, version: Int, points: inout Int) throws -> RecorderFileCommand {
        switch try tag(node) {
        case "selectionShape":
            let value = try Object(node, required: ["tag", "shape", "options"])
            let shapeNode = value.get("shape")
            let shape: RecorderFileCommand.Shape
            switch try tag(shapeNode) {
            case "rectangle", "ellipse":
                let source = try Object(shapeNode, required: ["tag", "rect"])
                let rectangle = try rect(source.get("rect"))
                let x1 = min(rectangle.x, rectangle.x + rectangle.width), x2 = max(rectangle.x, rectangle.x + rectangle.width)
                let y1 = min(rectangle.y, rectangle.y + rectangle.height), y2 = max(rectangle.y, rectangle.y + rectangle.height)
                for coordinate in [floor(x1), floor(y1), ceil(x2), ceil(y2), ceil(x2) - floor(x1), ceil(y2) - floor(y1)] { try nativeInteger(coordinate) }
                guard ceil(x2) - floor(x1) >= 1, ceil(y2) - floor(y1) >= 1 else { throw RecorderFileError.invalid("The snapped selection rectangle is empty.") }
                shape = try tag(shapeNode) == "rectangle" ? .rectangle(rectangle) : .ellipse(rectangle)
            case "polygon":
                let source = try Object(shapeNode, required: ["tag", "points"])
                let vertices = try array(source.get("points"), maximum: RecorderFileLimits.points).map { try point($0) }
                guard vertices.count >= 3, vertices.count <= RecorderFileLimits.points - points else { throw RecorderFileError.invalid("Invalid polygon point count.") }
                points += vertices.count; shape = .polygon(vertices)
            default: throw RecorderFileError.invalid("Unknown selection shape.")
            }
            return .selectionShape(shape, try options(value.get("options")))
        case "selectColor":
            let value = try Object(node, required: ["tag", "point", "options"])
            let source = try point(value.get("point"))
            try nativeInteger(floor(source.x)); try nativeInteger(floor(source.y))
            return .selectColor(source, try options(value.get("options")))
        case "selectCommand":
            let value = try Object(node, required: ["tag", "command", "radius"])
            guard let selection = RecorderFileCommand.Selection(rawValue: try string(value.get("command"))) else { throw RecorderFileError.invalid("Unknown selection command.") }
            let radius = try number(value.get("radius"))
            try nativeInteger(floor(max(radius, 0) + 0.5))
            switch selection {
            case .feather, .grow, .shrink, .border:
                guard radius > 0 else { throw RecorderFileError.invalid("This selection command needs a positive radius.") }
            case .all, .none, .invert, .sharpen, .fromAlpha: break
            }
            return .selectCommand(selection, radius: radius)
        case "transformImage":
            let value = try Object(node, required: ["tag", "transform"])
            guard let transform = RecorderFileCommand.Transform(rawValue: try string(value.get("transform"))) else { throw RecorderFileError.invalid("Unknown image transform.") }
            return .transformImage(transform)
        case "scale":
            let value = try Object(node, required: ["tag", "width", "height"])
            return .scale(width: try integer(value.get("width"), range: 1...524288), height: try integer(value.get("height"), range: 1...524288))
        case "resizeCanvas":
            let value = try Object(node, required: ["tag", "width", "height", "offset", "fill"])
            let offset = try point(value.get("offset"))
            try nativeInteger(offset.x.rounded(.towardZero)); try nativeInteger(offset.y.rounded(.towardZero))
            return .resizeCanvas(width: try integer(value.get("width"), range: 1...524288), height: try integer(value.get("height"), range: 1...524288),
                                 offset: offset, fill: try color(value.get("fill")))
        case "crop":
            let value = try Object(node, required: ["tag", "rect"])
            let rectangle = try rect(value.get("rect"))
            let x = min(rectangle.x, rectangle.x + rectangle.width).rounded(), y = min(rectangle.y, rectangle.y + rectangle.height).rounded()
            // CGRect.width/height use positive extents even when the retained
            // size has a negative component. Keep the wire payload unchanged.
            let width = abs(rectangle.width).rounded(), height = abs(rectangle.height).rounded()
            for coordinate in [x, y, width, height, x + width, y + height] { try nativeInteger(coordinate) }
            guard width >= 1, height >= 1 else { throw RecorderFileError.invalid("The rounded crop rectangle is empty.") }
            return .crop(rectangle)
        case "layerProperties":
            let value = try Object(node, required: ["tag", "properties"])
            let properties = try Object(value.get("properties"), required: [], optional: ["name", "visible", "opacity", "mode"])
            return .layerProperties(.init(name: try properties.optional("name").map { try string($0, native: true) },
                visible: try properties.optional("visible").map { try bool($0) }, opacity: try properties.optional("opacity").map { try number($0) },
                mode: try properties.optional("mode").map { try RecorderFileLayerMode(string($0)) }))
        case "transformLayer":
            guard version >= layerTransformVersion else { throw RecorderFileError.invalid("A layer transform needs recording version 4.") }
            let value = try Object(node, required: ["tag", "matrix", "interpolation"])
            let matrix = try Object(value.get("matrix"), required: ["a", "b", "c", "d", "tx", "ty"])
            let a = try number(matrix.get("a")), b = try number(matrix.get("b"))
            let c = try number(matrix.get("c")), d = try number(matrix.get("d"))
            let tx = try number(matrix.get("tx")), ty = try number(matrix.get("ty"))
            guard let interpolation = RecorderFileCommand.LayerInterpolation(rawValue: try string(value.get("interpolation"))) else {
                throw RecorderFileError.invalid("Unknown layer interpolation.")
            }
            // Finite coefficients alone are not safe: the affine determinant
            // can overflow, and a degenerate matrix would flatten the layer.
            // Matches the native 1e-9 bound in Engine/edit.c.
            let determinant = a * d - b * c
            guard determinant.isFinite, abs(determinant) >= 1e-9 else {
                throw RecorderFileError.invalid("The layer transform matrix is degenerate.")
            }
            // Identity can never reach the file: live admission refuses it
            // before any record exists.
            guard a != 1 || b != 0 || c != 0 || d != 1 || tx != 0 || ty != 0 else {
                throw RecorderFileError.invalid("The identity layer transform was never admissible.")
            }
            return .transformLayer(.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty), interpolation: interpolation)
        case "transformProjectiveLayer":
            guard version >= projectiveLayerTransformVersion else {
                throw RecorderFileError.invalid("A projective layer transform needs recording version 6.")
            }
            let value = try Object(node, required: ["tag", "matrix", "interpolation"])
            let matrix = try Object(value.get("matrix"), required:
                ["h00", "h01", "h02", "h10", "h11", "h12", "h20", "h21", "h22"])
            let projective = try RecorderFileCommand.Projective(
                h00: number(matrix.get("h00")), h01: number(matrix.get("h01")), h02: number(matrix.get("h02")),
                h10: number(matrix.get("h10")), h11: number(matrix.get("h11")), h12: number(matrix.get("h12")),
                h20: number(matrix.get("h20")), h21: number(matrix.get("h21")), h22: number(matrix.get("h22"))).validated()
            guard let interpolation = RecorderFileCommand.LayerInterpolation(rawValue: try string(value.get("interpolation"))) else {
                throw RecorderFileError.invalid("Unknown layer interpolation.")
            }
            return .transformProjectiveLayer(projective, interpolation: interpolation)
        case "applyLevels":
            guard version >= levelsVersion else { throw RecorderFileError.invalid("A Levels command needs recording version 5.") }
            let value = try Object(node, required: ["tag", "settings"])
            return .applyLevels(try levels(value.get("settings")))
        case "channelToSelection":
            guard version >= channelVersion else { throw RecorderFileError.invalid("A channel selection needs recording version 3.") }
            let value = try Object(node, required: ["tag", "operation"])
            guard let operation = RecorderFileCommand.Operation(rawValue: try string(value.get("operation"))) else {
                throw RecorderFileError.invalid("Unknown selection operation.")
            }
            return .channelToSelection(operation)
        case "completeStroke":
            guard version >= strokeVersion else { throw RecorderFileError.invalid("A complete stroke needs recording version 2.") }
            return .completeStroke(try stroke(node, points: &points))
        default: throw RecorderFileError.invalid("Unknown semantic command; use a compatible Glims version.")
        }
    }

    /// Whole Levels values: the owned TRC tag, both clamps and every named
    /// channel. The same scalar and range rules as the native typed settings;
    /// equal or inverted endpoints remain valid native mappings.
    private static func levels(_ node: RecorderJSON) throws -> RecorderFileCommand.Levels {
        let value = try Object(node, required: ["trc", "clampInput", "clampOutput", "value", "red", "green", "blue", "alpha"])
        guard let trc = RecorderFileCommand.Levels.TRC(rawValue: try string(value.get("trc"))) else {
            throw RecorderFileError.invalid("Unknown Levels transfer curve.")
        }
        func channel(_ key: String) throws -> RecorderFileCommand.Levels.Channel {
            let source = try Object(value.get(key), required: ["lowInput", "highInput", "gamma", "lowOutput", "highOutput"])
            let result = RecorderFileCommand.Levels.Channel(lowInput: try number(source.get("lowInput")),
                highInput: try number(source.get("highInput")), gamma: try number(source.get("gamma")),
                lowOutput: try number(source.get("lowOutput")), highOutput: try number(source.get("highOutput")))
            guard [result.lowInput, result.highInput, result.lowOutput, result.highOutput]
                    .allSatisfy({ (0...1).contains($0) }), (0.1...10).contains(result.gamma) else {
                throw RecorderFileError.invalid("Levels endpoints must be inside 0...1 and gamma inside 0.1...10.")
            }
            return result
        }
        return .init(trc: trc, clampInput: try bool(value.get("clampInput")), clampOutput: try bool(value.get("clampOutput")),
            value: try channel("value"), red: try channel("red"), green: try channel("green"),
            blue: try channel("blue"), alpha: try channel("alpha"))
    }

    private static func descriptionKind(_ node: RecorderJSON) throws -> RecorderTargetDescription.Kind {
        switch try string(node) {
        case "pixel": return .pixel
        case "group": return .group
        case "text": return .text
        case "link": return .link
        case "vector": return .vector
        case "channel": return .channel
        case "quickMask": return .quickMask
        default: throw RecorderFileError.invalid("Unknown target description kind.")
        }
    }
    private static func description(_ node: RecorderJSON) throws -> RecorderTargetDescription {
        let value = try Object(node, required: ["name", "kind", "ancestors", "siblingIndex", "bounds"])
        let ancestors = try array(value.get("ancestors")).map { node -> RecorderTargetDescription.Ancestor in
            let ancestor = try Object(node, required: ["name", "kind", "siblingIndex"])
            let type = try descriptionKind(ancestor.get("kind"))
            guard type == .group else { throw RecorderFileError.invalid("A layer ancestor must describe a group.") }
            return .init(name: try string(ancestor.get("name"), native: true), kind: type,
                         siblingIndex: try integer(ancestor.get("siblingIndex"), range: 0...Int(Int32.max)))
        }
        let bounds = try rect(value.get("bounds"))
        guard bounds.width >= 0, bounds.height >= 0 else { throw RecorderFileError.invalid("Negative target description size.") }
        return .init(name: try string(value.get("name"), native: true), kind: try descriptionKind(value.get("kind")), ancestors: ancestors,
            siblingIndex: try integer(value.get("siblingIndex"), range: 0...Int(Int32.max)),
            bounds: .init(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height))
    }
    private static func binding(_ node: RecorderJSON) throws -> RecorderBindingDescription {
        switch try kind(node) {
        case "none": _ = try Object(node, required: ["kind"]); return .none
        case "layer":
            let value = try Object(node, required: ["kind", "symbol"])
            return .layer(try uuid(value.get("symbol")))
        case "channel":
            let value = try Object(node, required: ["kind", "symbol"])
            return .channel(try uuid(value.get("symbol")))
        case "context":
            let value = try Object(node, required: ["kind", "context"])
            let context = try Object(value.get("context"), required: ["layers", "channels", "target", "masks", "quickMask"])
            let layers = try array(context.get("layers"), maximum: RecorderFileLimits.symbols).map { try uuid($0) }
            let channels = try array(context.get("channels"), maximum: RecorderFileLimits.symbols).map { try uuid($0) }
            guard Set(layers).count == layers.count, Set(channels).count == channels.count else { throw RecorderFileError.invalid("Duplicate context symbol.") }
            let masks = try array(context.get("masks"), maximum: RecorderFileLimits.symbols).map { node -> RecorderBindingDescription.Mask in
                let mask = try Object(node, required: ["owner", "isPresent", "enabled", "editing", "showing"])
                let result = RecorderBindingDescription.Mask(owner: try uuid(mask.get("owner")), isPresent: try bool(mask.get("isPresent")),
                    enabled: try bool(mask.get("enabled")), editing: try bool(mask.get("editing")), showing: try bool(mask.get("showing")))
                guard result.isPresent || (!result.enabled && !result.editing && !result.showing) else { throw RecorderFileError.invalid("An absent mask cannot have active flags.") }
                return result
            }
            guard Set(masks.map(\.owner)).count == masks.count, Set(masks.map(\.owner)) == Set(layers) else { throw RecorderFileError.invalid("Mask roles do not match the ordered layer context.") }
            let quick = try Object(context.get("quickMask"), required: ["enabled", "inverted", "color"], optional: ["symbol"])
            let quickMask = RecorderBindingDescription.QuickMask(enabled: try bool(quick.get("enabled")),
                symbol: try quick.optional("symbol").map { try uuid($0) }, inverted: try bool(quick.get("inverted")), color: try color(quick.get("color")))
            guard quickMask.enabled == (quickMask.symbol != nil) else { throw RecorderFileError.invalid("Quick Mask role and enabled state disagree.") }
            let targetNode = context.get("target")
            let target: RecorderBindingDescription.Target
            switch try kind(targetNode) {
            case "layer", "channel", "quickMask":
                let source = try Object(targetNode, required: ["kind", "symbol"])
                let id = try uuid(source.get("symbol"))
                switch try kind(targetNode) {
                case "layer": target = .layer(id)
                case "channel": target = .channel(id)
                default: target = .quickMask(id)
                }
            case "mask":
                let source = try Object(targetNode, required: ["kind", "owner"])
                target = .mask(owner: try uuid(source.get("owner")))
            default: throw RecorderFileError.invalid("Unknown active target role.")
            }
            return .context(.init(layers: layers, channels: channels, target: target, masks: masks, quickMask: quickMask))
        default: throw RecorderFileError.invalid("Unavailable or unknown binding; record the command again.")
        }
    }

    static func referencedSymbols(_ binding: RecorderBindingDescription) throws -> Set<UUID> {
        switch binding {
        case .none: return []
        case .layer(let id), .channel(let id): return [id]
        case .unavailable(let reason): throw RecorderFileError.invalid("The recording has an unavailable original target: \(reason)")
        case .context(let context):
            var result = Set(context.layers + context.channels + context.masks.map(\.owner))
            switch context.target {
            case .layer(let id), .channel(let id), .quickMask(let id), .mask(let id): result.insert(id)
            }
            if let id = context.quickMask.symbol { result.insert(id) }
            return result
        }
    }

    private static func validate(_ binding: RecorderBindingDescription, for command: RecorderFileCommand,
                                 descriptions: [UUID: RecorderTargetDescription]) throws {
        for id in try referencedSymbols(binding) where descriptions[id] == nil { throw RecorderFileError.invalid("A binding references a missing symbol.") }
        func layer(_ id: UUID) -> Bool { descriptions[id].map { $0.kind != .channel && $0.kind != .quickMask } ?? false }
        switch (command, binding) {
        case (.layerProperties, .layer(let id)):
            guard layer(id) else { throw RecorderFileError.invalid("Layer properties need a layer description.") }
            return
        case (.transformLayer, .layer(let id)), (.transformProjectiveLayer, .layer(let id)):
            guard layer(id) else { throw RecorderFileError.invalid("A layer transform needs a layer description.") }
            return
        case (.applyLevels, .layer(let id)):
            guard layer(id) else { throw RecorderFileError.invalid("A Levels adjustment needs a layer description.") }
            return
        case (.channelToSelection, .channel(let id)):
            guard descriptions[id]?.kind == .channel else { throw RecorderFileError.invalid("Channel to Selection needs a channel description.") }
            return
        case (.completeStroke, .layer(let id)):
            guard descriptions[id]?.kind == .pixel else { throw RecorderFileError.invalid("A complete stroke needs a pixel layer description.") }
            return
        case (.selectColor(_, let options), .context) where !options.sampleMerged: break
        case (.selectCommand(.fromAlpha, _), .context): break
        case (.selectionShape, .none), (.selectColor, .none), (.selectCommand, .none), (.transformImage, .none), (.scale, .none), (.resizeCanvas, .none), (.crop, .none):
            if case .selectColor(_, let options) = command, !options.sampleMerged { throw RecorderFileError.invalid("Drawable color selection needs a context.") }
            if case .selectCommand(.fromAlpha, _) = command { throw RecorderFileError.invalid("Select Alpha needs a context.") }
            return
        default: throw RecorderFileError.invalid("Command and binding kinds disagree.")
        }
        guard case .context(let context) = binding,
              context.layers.allSatisfy(layer), context.channels.allSatisfy({ descriptions[$0]?.kind == .channel || descriptions[$0]?.kind == .quickMask }) else {
            throw RecorderFileError.invalid("Invalid drawable context descriptions.")
        }
        if let id = context.quickMask.symbol, descriptions[id]?.kind != .quickMask { throw RecorderFileError.invalid("Quick Mask needs its own role description.") }
        switch context.target {
        case .layer(let id):
            let editingMask = context.layers.count == 1 && context.masks.contains { $0.owner == id && $0.isPresent && $0.editing }
            guard context.channels.isEmpty, context.layers.first == id, !editingMask else { throw RecorderFileError.invalid("Layer target is not the captured primary drawable.") }
        case .mask(let id):
            guard context.channels.isEmpty, context.layers == [id], context.masks.contains(where: { $0.owner == id && $0.isPresent && $0.editing }) else { throw RecorderFileError.invalid("Mask target does not match its captured owner/role.") }
        case .channel(let id): guard context.channels.first == id, descriptions[id]?.kind == .channel else { throw RecorderFileError.invalid("Channel target does not match its captured role.") }
        case .quickMask(let id): guard context.channels.first == id, context.quickMask.enabled, context.quickMask.symbol == id else { throw RecorderFileError.invalid("Quick Mask target does not match its captured role.") }
        }
    }
}
