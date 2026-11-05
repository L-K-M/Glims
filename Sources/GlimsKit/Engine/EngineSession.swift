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

    struct EngineError: Error, CustomStringConvertible, Equatable {
        let status: Int32
        let message: String

        var description: String { message }
    }

    enum Event: Equatable {
        case projectionChanged(image: Int32, rect: CGRect)
        case layersChanged(image: Int32)
        case undoChanged(image: Int32)
        case message(String)
        /// Progress of the running plug-in procedure; `nil` once it ended.
        case progress(Progress?)
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

    struct Brush: Equatable {
        var size: Double = 12
        var opacity: Double = 1
        var red: Double = 0, green: Double = 0, blue: Double = 0
        var pressureSize = true
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
                                          pressure_size: brush.pressureSize)
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
    case UInt32(GLIMS_EVENT_PROGRESS.rawValue):
        let text = event.text.map { String(cString: $0) } ?? ""
        relay.deliver(.progress(event.active
            ? EngineSession.Progress(fraction: event.value < 0 ? nil : event.value, text: text)
            : nil))
    default:
        break
    }
}
