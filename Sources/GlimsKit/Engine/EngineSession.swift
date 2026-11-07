import AppKit
import CGlimsEngine
import CoreGraphics
import Foundation

/// A running engine, wrapped for Swift.
///
/// Every method is synchronous and thread-safe: the adapter runs each call
/// on its engine thread and waits. Calls that can run plug-ins (open,
/// export) or take long must not be made on the main thread. Events arrive
/// on the main queue.
///
/// `@unchecked Sendable`: the stored properties are immutable after `start`,
/// and the adapter serializes every call onto its engine thread, so sharing a
/// session across queues is safe.
final class EngineSession: @unchecked Sendable {

    struct EngineError: LocalizedError, CustomStringConvertible, Equatable {
        let status: Int32
        let message: String

        var description: String { message }
        var errorDescription: String? { message }
    }

    enum Event: Equatable {
        case projectionChanged(image: Int32, rect: CGRect)
        case layersChanged(image: Int32)
        case undoChanged(image: Int32)
        case message(String)
        /// Progress of the running plug-in procedure; `nil` once it ended.
        case progress(Progress?)
        case selectionChanged(image: Int32)
        case sizeChanged(image: Int32)
    }

    // MARK: Editing types

    enum FillMode: UInt32 {
        case similarColors = 1, selection
    }

    enum GradientShape: UInt32 {
        case linear = 0, bilinear, radial
    }

    enum Transform: UInt32 {
        case rotate90 = 1, rotate180, rotate270, flipHorizontal, flipVertical
    }

    /// A text layer's look; sizes and spacings in image pixels.
    struct TextSettings: Equatable {
        enum Justify: UInt32, CaseIterable {
            case left = 1, right, center, fill

            var name: String {
                switch self {
                case .left: return "Left"
                case .right: return "Right"
                case .center: return "Center"
                case .fill: return "Justified"
                }
            }
        }

        var font = "Sans-serif"
        var size: Double = 36
        var color = NSColor.black
        var justify = Justify.left
        var lineSpacing: Double = 0
        var letterSpacing: Double = 0
        var antialias = true
    }

    /// How transformed pixels are resampled (GlimsInterpolation).
    enum Interpolation: UInt32, CaseIterable {
        case none = 1, linear, cubic, noHalo, loHalo

        var name: String {
            switch self {
            case .none: return "None"
            case .linear: return "Linear"
            case .cubic: return "Cubic"
            case .noHalo: return "NoHalo"
            case .loHalo: return "LoHalo"
            }
        }
    }

    enum LayerCommand: UInt32 {
        case new = 1, duplicate, delete, raise, lower, toTop, toBottom, mergeDown, flatten
    }

    /// Layer properties to change; nil fields stay as they are.
    struct LayerChange: Equatable {
        var name: String?
        var isVisible: Bool?
        var opacity: Double?
        var mode: String?
    }

    struct Progress: Equatable {
        /// 0 ... 1, or `nil` while the amount is unknown.
        let fraction: Double?
        let text: String
    }

    /// A plug-in command with a menu entry that works on an image.
    struct Procedure: Equatable {
        let name: String
        /// Menu title; ends in "…" when the plug-in asks for settings first.
        let label: String
        /// The engine's menu path, e.g. "<Image>/Filters/Light and Shadow/[Shadow]".
        let menuPath: String
        let blurb: String
        /// Runnable on the image's selected layers (when listed for an image).
        let isSensitive: Bool
    }

    enum RunMode {
        /// The plug-in may show its own dialog first.
        case interactive
        /// Repeats with the settings used last, without a dialog.
        case withLastValues
    }

    enum RunOutcome: Equatable {
        case completed, cancelled
    }

    struct ImageInfo: Equatable {
        let width: Int
        let height: Int
        let layerCount: Int
        let isDirty: Bool
        let precision: String
    }

    enum LayerKind: Equatable {
        case pixel, group, text, link, vector
    }

    struct Layer: Equatable {
        let id: Int32
        let parent: Int32
        let depth: Int
        let kind: LayerKind
        let name: String
        let mode: String
        let isVisible: Bool
        let hasMask: Bool
        let isSelected: Bool
        let opacity: Double
        let bounds: CGRect
        let filterCount: Int
    }

    struct UndoInfo: Equatable {
        let undoCount: Int
        let redoCount: Int
        let nextUndo: String
        let nextRedo: String
    }

    /// A paint stroke's tool and settings. `nil` numbers keep the engine's
    /// default for that tool.
    struct Brush: Equatable {
        enum Tool: UInt32, CaseIterable {
            case paintbrush = 0, pencil, airbrush, eraser, smudge, blur, sharpen, dodge, burn, clone, heal
        }

        enum Tones: UInt32 {
            case midtones = 0, shadows, highlights
        }

        /// Where clone and heal copy from: a layer of any open image and a
        /// point in that image.
        struct Source: Equatable {
            var drawable: Int32
            var x: Double
            var y: Double
        }

        var tool: Tool = .paintbrush
        var size: Double = 12
        var opacity: Double = 1
        var red: Double = 0, green: Double = 0, blue: Double = 0
        var pressureSize = true
        var hardness: Double?
        var rate: Double?
        var flow: Double?
        var exposure: Double?
        var tones: Tones = .midtones
        var antiErase = false
        var source: Source?
    }

    // MARK: Selection types

    enum SelectOperation: UInt32 {
        case replace = 0, add, subtract, intersect
    }

    enum SelectShape: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case polygon([CGPoint])
    }

    struct SelectOptions: Equatable {
        var operation: SelectOperation = .replace
        var antialias = true
        var feather: Double = 0
        var cornerRadius: Double = 0
        /// Color selections: 0 ... 1; GIMP's default is 15/255.
        var threshold: Double = 15.0 / 255.0
        var contiguous = true
        var sampleMerged = false
    }

    enum SelectCommand: UInt32 {
        case all = 1, none, invert, feather, grow, shrink, border, sharpen, fromAlpha
    }

    /// One edge of the selection outline, on pixel corners in image pixels.
    struct Segment: Equatable {
        let from: CGPoint
        let to: CGPoint
    }

    struct StrokePoint: Equatable {
        var x: Double
        var y: Double
        var pressure: Double = 1
        var xTilt: Double = 0
        var yTilt: Double = 0
        var timeMilliseconds: UInt32 = 0
    }

    let version: String
    private let api: GlimsEngineAPI
    private let engine: OpaquePointer
    private let relay: EventRelay

    /// Starts GIMP's engine. Takes seconds; the first start with a new user
    /// directory registers every plug-in. Only one engine per process.
    static func start(api pointer: UnsafePointer<GlimsEngineAPI>,
                      userDirectory: URL,
                      cacheDirectory: URL,
                      onEvent: @escaping @MainActor (Event) -> Void) throws -> EngineSession {
        let api = pointer.pointee
        let relay = EventRelay(handler: onEvent)
        var engine: OpaquePointer?
        var error: UnsafeMutablePointer<CChar>?

        let status = userDirectory.path.withCString { user in
            cacheDirectory.path.withCString { cache in
                var config = GlimsEngineConfig(
                    struct_size: UInt32(MemoryLayout<GlimsEngineConfig>.size),
                    user_directory: user,
                    cache_directory: cache,
                    on_event: engineEventCallback,
                    event_context: Unmanaged.passUnretained(relay).toOpaque())
                return api.start(&config, &engine, &error)
            }
        }
        guard status == GLIMS_STATUS_OK, let engine else {
            throw EngineError(status: Int32(status.rawValue), message: takeString(error, api: api) ?? "The engine failed to start.")
        }
        return EngineSession(api: api, engine: engine, relay: relay)
    }

    private init(api: GlimsEngineAPI, engine: OpaquePointer, relay: EventRelay) {
        self.api = api
        self.engine = engine
        self.relay = relay
        self.version = api.engine_version(engine).map { String(cString: $0) } ?? "?"
    }

    /// Stops the engine. It cannot be started again in this process.
    func stop() {
        api.stop(engine)
    }

    // MARK: Images

    func newImage(width: Int, height: Int) throws -> Int32 {
        var image: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_new(engine, Int32(width), Int32(height), &image, &error), error)
        return image
    }

    func openImage(path: String) throws -> Int32 {
        var image: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_open(engine, path, &image, &error), error)
        return image
    }

    func copyPixels(_ image: Int32, merged: Bool) throws -> ClipboardImage {
        var output = GlimsPixelBuffer()
        var error: UnsafeMutablePointer<CChar>?
        defer { api.free_pixels(output.pixels) }
        try check(api.image_copy_pixels(engine, image, merged, &output, &error), error)
        let count = try ClipboardImage.byteCount(width: Int(output.bounds.width), height: Int(output.bounds.height))
        guard count == output.byte_count, let pixels = output.pixels else { throw ClipboardImage.TransferError.invalidImage }
        return ClipboardImage(width: Int(output.bounds.width), height: Int(output.bounds.height),
                              pixels: Data(bytes: pixels, count: count),
                              origin: CGPoint(x: Int(output.bounds.x), y: Int(output.bounds.y)))
    }

    func clearPixels(_ image: Int32, background: NSColor) throws {
        var color = Self.color(background)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_clear(engine, image, &color, &error), error)
    }

    func pastePixels(_ image: Int32, pixels: ClipboardImage, at origin: CGPoint) throws -> Int32 {
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) <= 524_288, abs(origin.y) <= 524_288,
              pixels.pixels.count == (try ClipboardImage.byteCount(width: pixels.width, height: pixels.height)) else {
            throw ClipboardImage.TransferError.invalidImage
        }
        let bounds = GlimsRect(x: Int32(origin.x.rounded()), y: Int32(origin.y.rounded()),
                               width: Int32(pixels.width), height: Int32(pixels.height))
        var layer: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try pixels.pixels.withUnsafeBytes { bytes in
            try check(api.image_paste_pixels(engine, image, bounds, bytes.bindMemory(to: UInt8.self).baseAddress,
                                             bytes.count, &layer, &error), error)
        }
        return layer
    }

    func closeImage(_ image: Int32) throws {
        try check(api.image_close(engine, image), nil)
    }

    func info(_ image: Int32) throws -> ImageInfo {
        var info = GlimsImageInfo()
        try check(api.image_info(engine, image, &info), nil)
        return ImageInfo(width: Int(info.width), height: Int(info.height),
                         layerCount: Int(info.layer_count), isDirty: info.dirty,
                         precision: Self.string(info.precision))
    }

    /// Renders `area` (in scaled pixels) of the composited image at `scale`
    /// as an sRGB image with premultiplied alpha.
    func render(_ image: Int32, scale: Double, area: CGRect) throws -> CGImage {
        let rect = GlimsRect(x: Int32(area.minX), y: Int32(area.minY),
                             width: Int32(area.width), height: Int32(area.height))
        let width = Int(rect.width), height = Int(rect.height)
        let stride = width * 4
        let data = NSMutableData(length: stride * height)!
        try check(api.image_render(engine, image, scale, rect,
                                   data.mutableBytes.assumingMemoryBound(to: UInt8.self), stride), nil)

        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    func save(_ image: Int32, to path: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_save(engine, image, path, &error), error)
    }

    func export(_ image: Int32, to path: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_export(engine, image, path, &error), error)
    }

    func layers(_ image: Int32) throws -> [Layer] {
        var count: Int32 = 0
        try check(api.image_layers(engine, image, nil, 0, &count), nil)
        var rows = [GlimsLayerInfo](repeating: GlimsLayerInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.image_layers(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map(Self.layer)
    }

    func undoInfo(_ image: Int32) throws -> UndoInfo {
        var info = GlimsUndoInfo()
        try check(api.image_undo_info(engine, image, &info), nil)
        return UndoInfo(undoCount: Int(info.undo_count), redoCount: Int(info.redo_count),
                        nextUndo: Self.string(info.next_undo), nextRedo: Self.string(info.next_redo))
    }

    func undo(_ image: Int32) throws { try check(api.image_undo(engine, image), nil) }
    func redo(_ image: Int32) throws { try check(api.image_redo(engine, image), nil) }

    // MARK: Painting

    func beginStroke(image: Int32, layer: Int32, brush: Brush, first: StrokePoint) throws -> Int32 {
        var settings = GlimsBrushSettings(struct_size: UInt32(MemoryLayout<GlimsBrushSettings>.size),
                                          size: brush.size, opacity: brush.opacity,
                                          red: brush.red, green: brush.green, blue: brush.blue,
                                          pressure_size: brush.pressureSize,
                                          tool: brush.tool.rawValue,
                                          hardness: brush.hardness ?? -1, rate: brush.rate ?? -1,
                                          flow: brush.flow ?? -1, exposure: brush.exposure ?? -1,
                                          tones: brush.tones.rawValue, anti_erase: brush.antiErase,
                                          source_drawable: brush.source?.drawable ?? 0,
                                          source_x: brush.source?.x ?? 0, source_y: brush.source?.y ?? 0)
        var point = Self.point(first)
        var stroke: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.stroke_begin(engine, image, layer, &settings, &point, &stroke, &error), error)
        return stroke
    }

    func continueStroke(_ stroke: Int32, points: [StrokePoint]) throws {
        let converted = points.map(Self.point)
        try converted.withUnsafeBufferPointer { buffer in
            try check(api.stroke_continue(engine, stroke, buffer.baseAddress, buffer.count), nil)
        }
    }

    func endStroke(_ stroke: Int32) throws {
        try check(api.stroke_end(engine, stroke), nil)
    }

    // MARK: Filters

    func beginFilter(image: Int32, drawable: Int32, operation: String) throws -> Int32 {
        var filter: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.filter_begin(engine, image, drawable, operation, &filter, &error), error)
        return filter
    }

    func setFilter(_ filter: Int32, _ property: String, to value: Double) throws {
        try check(api.filter_set_double(engine, filter, property, value), nil)
    }

    func commitFilter(_ filter: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.filter_commit(engine, filter, &error), error)
    }

    func abortFilter(_ filter: Int32) throws {
        try check(api.filter_abort(engine, filter), nil)
    }

    // MARK: Selections

    func select(_ shape: SelectShape, image: Int32, options: SelectOptions = SelectOptions()) throws {
        var settings = Self.selectOptions(options)
        let (kind, points): (GlimsSelectShape, [GlimsPoint])
        switch shape {
        case .rectangle(let rect):
            (kind, points) = (GLIMS_SHAPE_RECTANGLE, Self.corners(rect))
        case .ellipse(let rect):
            (kind, points) = (GLIMS_SHAPE_ELLIPSE, Self.corners(rect))
        case .polygon(let vertices):
            (kind, points) = (GLIMS_SHAPE_POLYGON, vertices.map { GlimsPoint(x: $0.x, y: $0.y) })
        }
        try points.withUnsafeBufferPointer { buffer in
            try check(api.select_shape(engine, image, kind.rawValue, buffer.baseAddress, buffer.count, &settings), nil)
        }
    }

    func selectColor(at point: CGPoint, image: Int32, options: SelectOptions = SelectOptions()) throws {
        var settings = Self.selectOptions(options)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.select_color(engine, image, GlimsPoint(x: point.x, y: point.y), &settings, &error), error)
    }

    func select(_ command: SelectCommand, image: Int32, radius: Double = 0) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.select_command(engine, image, command.rawValue, radius, &error), error)
    }

    /// The selection's bounding box in image pixels, or nil when nothing is selected.
    func selectionBounds(image: Int32) throws -> CGRect? {
        var empty = true
        var bounds = GlimsRect()
        try check(api.selection_bounds(engine, image, &empty, &bounds), nil)
        return empty ? nil : CGRect(x: Int(bounds.x), y: Int(bounds.y), width: Int(bounds.width), height: Int(bounds.height))
    }

    func selectionOutline(image: Int32) throws -> [Segment] {
        var count: Int32 = 0
        try check(api.selection_outline(engine, image, nil, 0, &count), nil)
        var segments = [GlimsSegment](repeating: GlimsSegment(), count: Int(count))
        var filled: Int32 = 0
        try segments.withUnsafeMutableBufferPointer { buffer in
            try check(api.selection_outline(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return segments.prefix(Int(min(count, filled))).map {
            Segment(from: CGPoint(x: Int($0.x1), y: Int($0.y1)), to: CGPoint(x: Int($0.x2), y: Int($0.y2)))
        }
    }

    private static func corners(_ rect: CGRect) -> [GlimsPoint] {
        [GlimsPoint(x: rect.minX, y: rect.minY), GlimsPoint(x: rect.maxX, y: rect.maxY)]
    }

    private static func selectOptions(_ options: SelectOptions) -> GlimsSelectOptions {
        GlimsSelectOptions(struct_size: UInt32(MemoryLayout<GlimsSelectOptions>.size),
                           operation: options.operation.rawValue, antialias: options.antialias,
                           feather: options.feather, corner_radius: options.cornerRadius,
                           threshold: options.threshold, contiguous: options.contiguous,
                           sample_merged: options.sampleMerged)
    }

    // MARK: Editing

    func fill(image: Int32, at point: CGPoint, mode: FillMode, color: NSColor, opacity: Double = 1,
              threshold: Double = 15.0 / 255.0, sampleMerged: Bool = false) throws {
        var settings = GlimsFillSettings(struct_size: UInt32(MemoryLayout<GlimsFillSettings>.size),
                                         mode: mode.rawValue, color: Self.color(color), opacity: opacity,
                                         threshold: threshold, sample_merged: sampleMerged, antialias: true)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.fill(engine, image, GlimsPoint(x: point.x, y: point.y), &settings, &error), error)
    }

    func gradient(image: Int32, from: CGPoint, to: CGPoint, shape: GradientShape,
                  fromColor: NSColor, toColor: NSColor, opacity: Double = 1) throws {
        var settings = GlimsGradientSettings(struct_size: UInt32(MemoryLayout<GlimsGradientSettings>.size),
                                             shape: shape.rawValue, from: Self.color(fromColor),
                                             to: Self.color(toColor), opacity: opacity)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.gradient(engine, image, GlimsPoint(x: from.x, y: from.y), GlimsPoint(x: to.x, y: to.y),
                               &settings, &error), error)
    }

    func selectLayer(_ layer: Int32, image: Int32) throws {
        try check(api.layer_select(engine, image, layer), nil)
    }

    /// Returns the layer the command created, if any.
    @discardableResult
    func layerCommand(_ command: LayerCommand, image: Int32, layer: Int32 = 0) throws -> Int32? {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_command(engine, image, layer, command.rawValue, &result, &error), error)
        return result == 0 ? nil : result
    }

    func changeLayer(_ layer: Int32, image: Int32, _ change: LayerChange) throws {
        var settings = GlimsLayerChange()
        settings.struct_size = UInt32(MemoryLayout<GlimsLayerChange>.size)
        var properties: UInt32 = 0
        if let name = change.name {
            properties |= GLIMS_LAYER_NAME.rawValue
            Self.copy(name, into: &settings.name)
        }
        if let visible = change.isVisible {
            properties |= GLIMS_LAYER_VISIBLE.rawValue
            settings.visible = visible
        }
        if let opacity = change.opacity {
            properties |= GLIMS_LAYER_OPACITY.rawValue
            settings.opacity = opacity
        }
        if let mode = change.mode {
            properties |= GLIMS_LAYER_MODE.rawValue
            Self.copy(mode, into: &settings.mode)
        }
        settings.properties = properties
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_change(engine, image, layer, &settings, &error), error)
    }

    func moveLayer(_ layer: Int32, image: Int32, by offset: CGSize) throws {
        try check(api.layer_move(engine, image, layer, offset.width, offset.height), nil)
    }

    func crop(image: Int32, to rect: CGRect) throws {
        var error: UnsafeMutablePointer<CChar>?
        let area = GlimsRect(x: Int32(rect.minX.rounded()), y: Int32(rect.minY.rounded()),
                             width: Int32(rect.width.rounded()), height: Int32(rect.height.rounded()))
        try check(api.image_crop(engine, image, area, &error), error)
    }

    func transformImage(_ image: Int32, _ transform: Transform) throws {
        try check(api.image_transform(engine, image, transform.rawValue), nil)
    }

    func transformLayer(_ layer: Int32, image: Int32, _ transform: Transform) throws {
        try check(api.layer_transform(engine, image, layer, transform.rawValue), nil)
    }

    /// Applies `matrix` (image pixels, y down) to the layer as one undo step.
    func transformLayer(_ layer: Int32, image: Int32, matrix: CGAffineTransform,
                        interpolation: Interpolation) throws {
        var values = GlimsMatrix(m: ((Double(matrix.a), Double(matrix.c), Double(matrix.tx)),
                                     (Double(matrix.b), Double(matrix.d), Double(matrix.ty)),
                                     (0, 0, 1)))
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_transform_matrix(engine, image, layer, &values, interpolation.rawValue, &error),
                  error)
    }

    // MARK: Text

    /// The font names text settings take, sorted.
    func fonts() throws -> [String] {
        var names: UnsafeMutablePointer<CChar>?
        try check(api.fonts(engine, &names), nil)
        defer { api.free_string(names) }
        return names.map { String(cString: $0).split(separator: "\n").map(String.init) } ?? []
    }

    /// Adds a text layer with its top-left at `position`; returns it.
    func addTextLayer(image: Int32, text: String, settings: TextSettings, at position: CGPoint) throws -> Int32 {
        var values = Self.textSettings(settings)
        var layer: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.text_layer_new(engine, image, text, &values, GlimsPoint(x: position.x, y: position.y),
                                     &layer, &error), error)
        return layer
    }

    func textLayer(image: Int32, layer: Int32) throws -> (text: String, settings: TextSettings) {
        var values = GlimsTextSettings()
        values.struct_size = UInt32(MemoryLayout<GlimsTextSettings>.size)
        var text: UnsafeMutablePointer<CChar>?
        try check(api.text_layer_get(engine, image, layer, &text, &values), nil)
        defer { api.free_string(text) }
        let settings = TextSettings(
            font: Self.string(values.font), size: values.size,
            color: NSColor(srgbRed: values.color.red, green: values.color.green,
                           blue: values.color.blue, alpha: values.color.alpha),
            justify: TextSettings.Justify(rawValue: values.justify) ?? .left,
            lineSpacing: values.line_spacing, letterSpacing: values.letter_spacing,
            antialias: values.antialias)
        return (text.map { String(cString: $0) } ?? "", settings)
    }

    /// Nil text keeps the text; nil settings keep the look.
    func setTextLayer(image: Int32, layer: Int32, text: String?, settings: TextSettings?) throws {
        var error: UnsafeMutablePointer<CChar>?
        if var values = settings.map(Self.textSettings) {
            try check(api.text_layer_set(engine, image, layer, text, &values, &error), error)
        } else {
            try check(api.text_layer_set(engine, image, layer, text, nil, &error), error)
        }
    }

    private static func textSettings(_ settings: TextSettings) -> GlimsTextSettings {
        var values = GlimsTextSettings()
        values.struct_size = UInt32(MemoryLayout<GlimsTextSettings>.size)
        copy(settings.font, into: &values.font)
        values.size = settings.size
        values.color = color(settings.color)
        values.justify = settings.justify.rawValue
        values.line_spacing = settings.lineSpacing
        values.letter_spacing = settings.letterSpacing
        values.antialias = settings.antialias
        return values
    }

    // MARK: Paths

    struct PathInfo: Equatable {
        let id: Int32
        let name: String
        let isVisible: Bool
        let isSelected: Bool
    }

    /// How `strokePath` draws a path: a line of one color.
    struct LineSettings: Equatable {
        var width: Double = 2
        var color: NSColor = .black
        var antialias = true
    }

    func paths(_ image: Int32) throws -> [PathInfo] {
        var count: Int32 = 0
        try check(api.paths(engine, image, nil, 0, &count), nil)
        var rows = [GlimsPathInfo](repeating: GlimsPathInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.paths(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map {
            PathInfo(id: $0.id, name: Self.string($0.name), isVisible: $0.visible, isSelected: $0.selected)
        }
    }

    func path(_ path: Int32, image: Int32) throws -> VectorPath {
        var subpathCount: Int32 = 0
        var pointCount: Int32 = 0
        try check(api.path_get(engine, image, path, nil, 0, &subpathCount, nil, 0, &pointCount), nil)
        var subpaths = [GlimsSubpath](repeating: GlimsSubpath(), count: Int(subpathCount))
        var points = [GlimsPathPoint](repeating: GlimsPathPoint(), count: Int(pointCount))
        var readSubpaths: Int32 = 0
        var readPoints: Int32 = 0
        try subpaths.withUnsafeMutableBufferPointer { subpathBuffer in
            try points.withUnsafeMutableBufferPointer { pointBuffer in
                try check(api.path_get(engine, image, path, subpathBuffer.baseAddress, subpathCount, &readSubpaths,
                                       pointBuffer.baseAddress, pointCount, &readPoints), nil)
            }
        }
        // The path may have grown between the two calls; read what fits.
        var result = VectorPath()
        var next = 0
        for subpath in subpaths.prefix(Int(min(subpathCount, readSubpaths))) {
            let end = next + Int(subpath.count)
            guard end <= min(Int(pointCount), Int(readPoints)) else { break }
            let anchors = points[next..<end].map {
                VectorPath.Anchor(point: CGPoint(x: $0.anchor.x, y: $0.anchor.y),
                                  handleIn: CGPoint(x: $0.in.x, y: $0.in.y),
                                  handleOut: CGPoint(x: $0.out.x, y: $0.out.y))
            }
            result.subpaths.append(VectorPath.Subpath(anchors: anchors, isClosed: subpath.closed))
            next = end
        }
        return result
    }

    /// Replaces a path's shape, or with a nil `path` adds a new path and
    /// selects it; one undo step either way. Returns the path.
    @discardableResult
    func setPath(_ path: Int32?, image: Int32, name: String? = nil, _ shape: VectorPath) throws -> Int32 {
        let subpaths = shape.subpaths.map { GlimsSubpath(count: Int32($0.anchors.count), closed: $0.isClosed) }
        let points = shape.subpaths.flatMap(\.anchors).map {
            GlimsPathPoint(in: GlimsPoint(x: $0.handleIn.x, y: $0.handleIn.y),
                           anchor: GlimsPoint(x: $0.point.x, y: $0.point.y),
                           out: GlimsPoint(x: $0.handleOut.x, y: $0.handleOut.y))
        }
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.path_set(engine, image, path ?? 0, name, subpaths, Int32(subpaths.count),
                               points, Int32(points.count), &result, &error), error)
        return result
    }

    /// Nil keeps a property; renaming and showing or hiding are undo steps.
    func changePath(_ path: Int32, image: Int32, name: String? = nil, visible: Bool? = nil,
                    select: Bool = false) throws {
        var error: UnsafeMutablePointer<CChar>?
        let visibility: Int32 = visible.map { $0 ? 1 : 0 } ?? -1
        try withOptionalCString(name) { name in
            var change = GlimsPathChange(struct_size: UInt32(MemoryLayout<GlimsPathChange>.size),
                                         name: name, visible: visibility, select: select)
            try check(api.path_change(engine, image, path, &change, &error), error)
        }
    }

    func deletePath(_ path: Int32, image: Int32) throws {
        try check(api.path_delete(engine, image, path), nil)
    }

    func selectPath(_ path: Int32, image: Int32, options: SelectOptions = SelectOptions()) throws {
        var values = Self.selectOptions(options)
        try check(api.path_to_selection(engine, image, path, &values), nil)
    }

    /// Draws the path on `layer` (nil: the selected layer).
    func strokePath(_ path: Int32, image: Int32, layer: Int32? = nil, settings: LineSettings) throws {
        var values = GlimsLineSettings(struct_size: UInt32(MemoryLayout<GlimsLineSettings>.size),
                                       width: settings.width, color: Self.color(settings.color),
                                       antialias: settings.antialias)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.path_stroke(engine, image, path, layer ?? 0, &values, &error), error)
    }

    private func withOptionalCString(_ string: String?,
                                     _ body: (UnsafePointer<CChar>?) throws -> Void) rethrows {
        guard let string else { return try body(nil) }
        try string.withCString { try body($0) }
    }

    func scaleImage(_ image: Int32, width: Int, height: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_scale(engine, image, Int32(width), Int32(height), &error), error)
    }

    func resizeCanvas(_ image: Int32, width: Int, height: Int, offset: CGPoint, fill: NSColor) throws {
        var color = Self.color(fill)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_resize_canvas(engine, image, Int32(width), Int32(height),
                                          Int32(offset.x), Int32(offset.y), &color, &error), error)
    }

    private static func color(_ color: NSColor) -> GlimsColor {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return GlimsColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                          blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    /// Copies a string into a fixed-size C char array, truncated on a UTF-8
    /// character boundary and NUL-terminated.
    private static func copy<T>(_ string: String, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { bytes in
            var utf8 = Array(string.utf8)
            if utf8.count >= bytes.count {
                utf8 = Array(utf8.prefix(bytes.count - 1))
                while let last = utf8.last, last & 0xC0 == 0x80 { utf8.removeLast() }
                if let last = utf8.last, last >= 0xC0 { utf8.removeLast() }
            }
            bytes.copyBytes(from: utf8)
            bytes[utf8.count] = 0
        }
    }

    // MARK: Plug-in procedures

    /// Plug-in commands with menu entries. With an image, `isSensitive`
    /// reflects its selected layers.
    func procedures(image: Int32? = nil) throws -> [Procedure] {
        var count: Int32 = 0
        try check(api.procedures(engine, image ?? 0, nil, 0, &count), nil)
        var rows = [GlimsProcedureInfo](repeating: GlimsProcedureInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.procedures(engine, image ?? 0, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map { row in
            Procedure(name: Self.string(row.name), label: Self.string(row.label),
                      menuPath: Self.string(row.menu_path), blurb: Self.string(row.blurb),
                      isSensitive: row.sensitive)
        }
    }

    /// Runs a plug-in command on the image's selected layers and returns
    /// when it finished, including the time its dialog is open. Never call
    /// this on the main thread. While it runs, edits of any image fail with
    /// a busy error.
    func runProcedure(_ name: String, image: Int32, mode: RunMode) throws -> RunOutcome {
        var error: UnsafeMutablePointer<CChar>?
        let runMode = mode == .interactive ? GLIMS_RUN_INTERACTIVE : GLIMS_RUN_WITH_LAST_VALUES
        let status = api.procedure_run(engine, image, name, runMode.rawValue, &error)
        if status == GLIMS_STATUS_CANCELLED {
            _ = Self.takeString(error, api: api)
            return .cancelled
        }
        try check(status, error)
        return .completed
    }

    /// Asks the running plug-in command to stop. Returns false when none runs.
    @discardableResult
    func cancelProcedure() -> Bool {
        api.procedure_cancel(engine) == GLIMS_STATUS_OK
    }

    // MARK: Helpers

    private func check(_ status: GlimsStatus, _ error: UnsafeMutablePointer<CChar>?) throws {
        let message = Self.takeString(error, api: api)
        guard status == GLIMS_STATUS_OK else {
            throw EngineError(status: Int32(status.rawValue), message: message ?? Self.describe(status))
        }
    }

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?, api: GlimsEngineAPI) -> String? {
        guard let pointer else { return nil }
        defer { api.free_string(pointer) }
        return String(cString: pointer)
    }

    private static func describe(_ status: GlimsStatus) -> String {
        switch status {
        case GLIMS_STATUS_INVALID_ARGUMENT: return "The engine rejected the request."
        case GLIMS_STATUS_NOT_FOUND: return "The engine has no such image, layer or session."
        case GLIMS_STATUS_BUSY: return "The engine is busy with another operation."
        case GLIMS_STATUS_CANCELLED: return "Cancelled."
        case GLIMS_STATUS_NOT_RUNNING: return "The engine is not running."
        default: return "The engine reported an error."
        }
    }

    /// Reads a NUL-terminated C string from a fixed-size char array.
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            let chars = bytes.bindMemory(to: CChar.self)
            let end = chars.firstIndex(of: 0) ?? chars.count
            return String(decoding: bytes.prefix(end), as: UTF8.self)
        }
    }

    private static func point(_ point: StrokePoint) -> GlimsStrokePoint {
        GlimsStrokePoint(x: point.x, y: point.y, pressure: point.pressure,
                         xtilt: point.xTilt, ytilt: point.yTilt, time_ms: point.timeMilliseconds)
    }

    private static func layer(_ row: GlimsLayerInfo) -> Layer {
        let kind: LayerKind
        switch Int(row.kind) {
        case Int(GLIMS_LAYER_GROUP.rawValue): kind = .group
        case Int(GLIMS_LAYER_TEXT.rawValue): kind = .text
        case Int(GLIMS_LAYER_LINK.rawValue): kind = .link
        case Int(GLIMS_LAYER_VECTOR.rawValue): kind = .vector
        default: kind = .pixel
        }
        return Layer(id: row.id, parent: row.parent, depth: Int(row.depth), kind: kind,
                     name: string(row.name), mode: string(row.mode), isVisible: row.visible,
                     hasMask: row.has_mask, isSelected: row.selected, opacity: row.opacity,
                     bounds: CGRect(x: Int(row.bounds.x), y: Int(row.bounds.y),
                                    width: Int(row.bounds.width), height: Int(row.bounds.height)),
                     filterCount: Int(row.filter_count))
    }
}

/// Receives engine events on the engine thread and hands them to the main
/// queue. The C callback must not block or call back into the engine.
private final class EventRelay: @unchecked Sendable {
    let handler: @MainActor (EngineSession.Event) -> Void

    init(handler: @escaping @MainActor (EngineSession.Event) -> Void) {
        self.handler = handler
    }

    func deliver(_ event: EngineSession.Event) {
        DispatchQueue.main.async { [handler] in handler(event) }
    }
}

private let engineEventCallback: GlimsEventCallback = { context, eventPointer in
    guard let context, let event = eventPointer?.pointee else { return }
    let relay = Unmanaged<EventRelay>.fromOpaque(context).takeUnretainedValue()
    switch event.kind {
    case UInt32(GLIMS_EVENT_PROJECTION_CHANGED.rawValue):
        relay.deliver(.projectionChanged(image: event.image,
                                         rect: CGRect(x: Int(event.rect.x), y: Int(event.rect.y),
                                                      width: Int(event.rect.width), height: Int(event.rect.height))))
    case UInt32(GLIMS_EVENT_LAYERS_CHANGED.rawValue):
        relay.deliver(.layersChanged(image: event.image))
    case UInt32(GLIMS_EVENT_UNDO_CHANGED.rawValue):
        relay.deliver(.undoChanged(image: event.image))
    case UInt32(GLIMS_EVENT_MESSAGE.rawValue):
        relay.deliver(.message(event.text.map { String(cString: $0) } ?? ""))
    case UInt32(GLIMS_EVENT_SELECTION_CHANGED.rawValue):
        relay.deliver(.selectionChanged(image: event.image))
    case UInt32(GLIMS_EVENT_SIZE_CHANGED.rawValue):
        relay.deliver(.sizeChanged(image: event.image))
    case UInt32(GLIMS_EVENT_PROGRESS.rawValue):
        let text = event.text.map { String(cString: $0) } ?? ""
        relay.deliver(.progress(event.active
            ? EngineSession.Progress(fraction: event.value < 0 ? nil : event.value, text: text)
            : nil))
    default:
        break
    }
}
