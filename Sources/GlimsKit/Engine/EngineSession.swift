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

        /// True only when the engine itself reported NOT_FOUND: the named
        /// image, layer, resource or session does not exist. Any other
        /// failure (busy, locked, engine error, ...) must not be read as
        /// "missing".
        var isNotFound: Bool { status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue) }
        var isBusy: Bool { status == Int32(GLIMS_STATUS_BUSY.rawValue) }

        /// Any thrown error as an `EngineError`, wrapping non-facade errors
        /// so callers can classify results (NOT_FOUND vs other) uniformly.
        static func coerce(_ error: Error) -> EngineError {
            if let engineError = error as? EngineError { return engineError }
            return EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                               message: String(describing: error))
        }
        var requiresRasterization: Bool { status == Int32(GLIMS_STATUS_REQUIRES_RASTERIZE.rawValue) }
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
        case channelsChanged(image: Int32)
        /// A guide was added, removed or moved; re-read `guides(_:)`.
        case guidesChanged(image: Int32)
    }

    // MARK: Editing types

    enum FillMode: UInt32 {
        case similarColors = 1, selection
    }

    /// How a pattern fill paints (GlimsPatternFillSettings): the pattern
    /// tiled from the drawable's origin instead of a solid color. It has
    /// no color fields of its own; the pattern comes from the resource
    /// handle the call carries.
    struct PatternFillSettings: Equatable {
        var mode: FillMode = .selection
        /// 0 ... 1; refused outside the range, not clamped.
        var opacity: Double = 1
        /// Similar colors: 0 ... 1; refused outside the range.
        var threshold: Double = 15.0 / 255.0
        var sampleMerged = false
        var antialias = true
    }

    enum GradientShape: UInt32, CaseIterable, Codable {
        case linear = 0, bilinear, radial
    }

    /// The color space a selected-resource gradient blends its stops in
    /// (GlimsGradientBlendSpace). Facade-owned values; the engine's enum
    /// never crosses the boundary.
    enum GradientBlendSpace: UInt32, Codable {
        case rgbPerceptual = 0
        /// Reserved: native engines currently report UNSUPPORTED.
        case rgbLinear
        case cieLab
    }

    /// A gradient drawn with a selected gradient resource: the stops
    /// come from the resource, with `foreground`/`background` feeding
    /// its foreground/background stop types. Both colors are opaque —
    /// the engine's FG/BG context has no alpha, so a translucent color
    /// is refused rather than silently flattened; transparent stop
    /// types (such as FG-to-transparent) belong to the resource itself.
    struct ResourceGradientSettings: Equatable {
        var shape = GradientShape.linear
        var foreground = NSColor.black
        var background = NSColor.white
        var opacity: Double = 1
        var reverse = false
        var blendSpace = GradientBlendSpace.rgbPerceptual
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
        /// Pixel layers only; the engine refuses groups and editable
        /// text, link and vector layers (rasterized instances count as
        /// pixels). Already fitting or already tight layers are a no-op.
        case fitToImage = 10, trimToContent
        /// Turns a genuine editable text, link or vector layer
        /// pixel-behaving while it keeps its structured source (one undo
        /// step); an already rasterized instance is a no-op. Ordinary
        /// pixel layers and groups throw UNSUPPORTED.
        case rasterize = 12
        /// The inverse: discards the pixel edits of a rasterized text,
        /// link or vector layer and regenerates it from its retained
        /// source (one undo step); an already editable instance is a
        /// no-op. Pixel layers, groups and layers without a retained
        /// source throw UNSUPPORTED. Not routed through the ordinary
        /// document queue yet — the root owns the confirmed-restore
        /// dispatch, and a link restore may read its file natively.
        case restoreSource = 13
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

    /// The locks a layer or group can hold (GlimsLayerLock).
    struct LayerLocks: OptionSet, Equatable {
        let rawValue: UInt32
        static let pixels = LayerLocks(rawValue: GLIMS_LOCK_PIXELS.rawValue)
        static let position = LayerLocks(rawValue: GLIMS_LOCK_POSITION.rawValue)
        static let alpha = LayerLocks(rawValue: GLIMS_LOCK_ALPHA.rawValue)

        /// What each lock is called in the Layer menu, in display order.
        static let menuOrder: [(lock: LayerLocks, title: String)] = [
            (.pixels, "Pixels"), (.position, "Position"), (.alpha, "Transparency"),
        ]

        /// The lock's short name for rows and VoiceOver.
        var name: String {
            switch self {
            case .pixels: return "pixels"
            case .position: return "position"
            case .alpha: return "transparency"
            default: return "lock"
            }
        }
    }

    /// A layer's or group's lock state (GlimsLayerState): `local` is the
    /// item's own locks, `effective` what the engine enforces on it — an
    /// ancestor group's lock counts too, and for a group the PIXELS and
    /// POSITION bits also cover a locked descendant.
    struct LayerLockState: Equatable {
        let local: LayerLocks
        let effective: LayerLocks
    }

    struct UndoInfo: Equatable {
        let undoCount: Int
        let redoCount: Int
        let nextUndo: String
        let nextRedo: String
    }

    /// One state of an image's undo history (GlimsHistoryRow): `position`
    /// orders states from the earliest retained one; `name` is the action
    /// that produced the state.
    struct HistoryRow: Equatable {
        let position: Int32
        let name: String
    }

    /// A consistent read of an image's undo history (GlimsHistoryInfo):
    /// the revision these rows and the current position were seen
    /// together with. It changes whenever the history changes, so moving
    /// to a state is only valid while the revision matches.
    struct History: Equatable {
        let revision: UInt64
        let currentPosition: Int32
        let rows: [HistoryRow]
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
        /// Persist the selected brush's identity, never a session-local
        /// handle. The stroke resolves it on the engine worker so a stale
        /// or removed resource fails explicitly instead of painting with
        /// a different brush after an engine restart.
        var resource: ResourceIdentity?
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
        var color = try Self.color(background)
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

    /// Adapter caps mirrored from the facade (glims_engine.h, slot 132):
    /// the largest destination ICC blob and the largest output buffer the
    /// native call accepts.
    private static let maxDestinationICCBytes = 16 * 1024 * 1024
    private static let maxRenderBufferBytes = 512 * 1024 * 1024

    /// Renders `area` (in scaled pixels) of the composited image at `scale`
    /// converted into the exact RGB destination ICC profile
    /// `destinationICC`, as premultiplied 8-bit RGBA. The returned
    /// `CGImage` is tagged with a color space built from those exact ICC
    /// bytes, so Quartz must not reinterpret the pixels. The caller owns
    /// the fallback policy: when no usable destination exists, call
    /// `render(_:scale:area:)` (sRGB) instead — the native call never
    /// falls back to sRGB silently.
    static func destinationRenderLayout(scale: Double, area: CGRect, iccByteCount: Int)
        throws -> (rect: GlimsRect, stride: Int, bytes: Int) {
        guard scale.isFinite, scale >= 1.0 / 1_048_576, scale <= 32,
              iccByteCount > 0, iccByteCount <= maxDestinationICCBytes else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The render request is out of range.")
        }
        let x = area.origin.x, y = area.origin.y
        let width = area.size.width, height = area.size.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x.rounded() == x, y.rounded() == y,
              width.rounded() == width, height.rounded() == height,
              x >= Double(Int32.min), x <= Double(Int32.max),
              y >= Double(Int32.min), y <= Double(Int32.max),
              width >= 1, height >= 1,
              width <= Double(Int32.max), height <= Double(Int32.max),
              x + width <= Double(Int32.max), y + height <= Double(Int32.max) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The render area is not a finite integral rectangle in range.")
        }
        let samplingScale = Double(Float(scale))
        guard [x, y, x + width, y + height].allSatisfy({ abs($0 / samplingScale) <= 67_108_864 }) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The render area exceeds the engine's sampling range.")
        }
        let stride = Int(width) * 4  // width is bounded by Int32, on macOS 64-bit
        // Divide the byte cap before multiplying: two Int32 dimensions times
        // four can overflow Int64 even though each dimension is in range.
        guard stride <= Int(Int32.max), Int(height) <= maxRenderBufferBytes / stride else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The render output buffer would exceed the adapter limit.")
        }
        return (GlimsRect(x: Int32(x), y: Int32(y), width: Int32(width), height: Int32(height)),
                stride, stride * Int(height))
    }

    func render(_ image: Int32, scale: Double, area: CGRect, destinationICC: Data) throws -> CGImage {
        let layout = try Self.destinationRenderLayout(scale: scale, area: area,
                                                      iccByteCount: destinationICC.count)
        // Parse ICC only after its byte cap and the output bounds are checked.
        guard let space = CGColorSpace(iccData: destinationICC as CFData), space.model == .rgb else {
            throw EngineError(status: Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                              message: "The destination ICC data is not a usable RGB color profile.")
        }
        let rect = layout.rect, stride = layout.stride
        guard let data = NSMutableData(length: layout.bytes) else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The render output buffer could not be allocated.")
        }
        var error: UnsafeMutablePointer<CChar>?
        try destinationICC.withUnsafeBytes { icc in
            try check(api.image_render_to_profile(engine, image, scale, rect,
                                                  icc.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                  destinationICC.count,
                                                  data.mutableBytes.assumingMemoryBound(to: UInt8.self),
                                                  stride, &error), error)
        }

        // `data` owns the bytes for the provider's (and so the image's)
        // whole lifetime, exactly as in render(_:scale:area:).
        let provider = CGDataProvider(data: data)!
        return CGImage(width: Int(rect.width), height: Int(rect.height),
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: space,
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

    func saveCopy(_ image: Int32, to path: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_save_copy(engine, image, path, &error), error)
    }

    /// File > Open as Layers: every layer of the file lands in the image
    /// above the selected layer, as one undo step. Returns the new layer
    /// ids, top first. Loads through the file plug-ins, so call it off
    /// the main thread.
    func openLayers(image: Int32, path: String) throws -> [Int32] {
        var count: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        var buffer = [GlimsItemID](repeating: 0, count: 1024)
        try check(buffer.withUnsafeMutableBufferPointer { buffer in
            api.image_open_layers(engine, image, path, buffer.baseAddress,
                                  Int32(buffer.count), &count, &error)
        }, error)
        guard count > buffer.count else { return Array(buffer.prefix(Int(count))) }
        // More layers than the buffer: the import selected all of them.
        return try layers(image).filter(\.isSelected).map(\.id)
    }

    /// File > Place: puts the file into the image as a link layer that
    /// keeps a live reference to it, as one undo step. Returns the new
    /// layer's id. Throws `EngineError` with `GLIMS_STATUS_UNSUPPORTED`
    /// on engines without link layers (before GIMP 3.2).
    func placeLink(image: Int32, path: String) throws -> Int32 {
        var layer: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_place_link(engine, image, path, &layer, &error), error)
        return layer
    }

    /// Whether the engine is known to place genuine link layers: they
    /// arrived in GIMP 3.2, and older engines answer `placeLink` with
    /// UNSUPPORTED. `nil` when the version string does not parse — the
    /// facade's own answer then decides instead of a guess.
    var supportsLinkLayers: Bool? {
        Self.supportsLinkLayers(version: version)
    }

    /// Parses an engine `major.minor[.micro]` version string.
    static func supportsLinkLayers(version: String) -> Bool? {
        Self.version(version, isAtLeast: (3, 2))
    }

    /// Whether the engine is known to make genuine vector layers from
    /// paths: they arrived in GIMP 3.2, and older engines answer
    /// `toVectorLayer` with UNSUPPORTED. `nil` when the version string
    /// does not parse — the facade's own answer then decides.
    var supportsVectorLayers: Bool? {
        Self.supportsVectorLayers(version: version)
    }

    /// Parses an engine `major.minor[.micro]` version string.
    static func supportsVectorLayers(version: String) -> Bool? {
        Self.version(version, isAtLeast: (3, 2))
    }

    /// Whether an engine `major.minor[.micro]` version string is at least
    /// `majorMinor`; nil when it does not parse.
    static func version(_ version: String, isAtLeast majorMinor: (major: Int, minor: Int)) -> Bool? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return major > majorMinor.major || (major == majorMinor.major && minor >= majorMinor.minor)
    }

    func newImage(pixels: ClipboardImage) throws -> Int32 {
        guard pixels.pixels.count == (try ClipboardImage.byteCount(width: pixels.width, height: pixels.height)) else {
            throw ClipboardImage.TransferError.invalidImage
        }
        var image: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try pixels.pixels.withUnsafeBytes { bytes in
            try check(api.image_from_pixels(engine, Int32(pixels.width), Int32(pixels.height),
                                             bytes.bindMemory(to: UInt8.self).baseAddress,
                                             bytes.count, &image, &error), error)
        }
        return image
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

    // MARK: History and snapshots

    /// How many times `history` re-reads with the size the engine last
    /// reported before giving up.
    private static let historyReadAttempts = 4

    /// The image's undo history as one consistent list (image_history).
    /// The engine can grow the list between the size probe and the fill;
    /// the read is retried a bounded number of times with the size it
    /// last reported, never indexing past the rows allocated.
    func history(_ image: Int32) throws -> History {
        var info = GlimsHistoryInfo()
        try check(api.image_history(engine, image, nil, 0, &info), nil)
        var capacity = info.count
        for _ in 0..<Self.historyReadAttempts {
            var rows = [GlimsHistoryRow](repeating: GlimsHistoryRow(), count: Int(capacity))
            try rows.withUnsafeMutableBufferPointer { buffer in
                try check(api.image_history(engine, image, buffer.baseAddress, capacity, &info), nil)
            }
            guard info.count > capacity else {
                // `info` pairs this exact read's revision with its rows.
                return History(revision: info.revision, currentPosition: info.current_position,
                               rows: rows.prefix(Int(info.count)).map {
                                   HistoryRow(position: $0.position, name: Self.string($0.name)) })
            }
            capacity = info.count
        }
        throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                          message: "The image history kept changing while it was being read.")
    }

    /// Moves through undo/redo to a state from `history`. A stale
    /// `revision` or an invalid position is refused without changing the
    /// image; BUSY while a stroke, preview or plug-in is active
    /// (image_history_move).
    func moveHistory(_ image: Int32, revision: UInt64, to position: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_history_move(engine, image, revision, position, &error), error)
    }

    /// An independent unsaved image with the source's layers, filters and
    /// paths and an empty history (image_duplicate). The source's file
    /// identity, pixels and history are unchanged. BUSY while a stroke,
    /// preview or plug-in is active.
    func duplicateImage(_ image: Int32) throws -> Int32 {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_duplicate(engine, image, &result, &error), error)
        return result
    }

    // MARK: Painting

    /// Starts a stroke on `drawable` — a layer or a layer mask's drawable
    /// id — and returns the stroke session `continueStroke`/`endStroke`
    /// take.
    func beginStroke(image: Int32, drawable: Int32, brush: Brush, first: StrokePoint) throws -> Int32 {
        var settings = Self.nativeBrush(brush)
        var point = Self.point(first)
        var stroke: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        if let identity = brush.resource {
            let resource = try resolveResource(identity, kind: .brush)
            try check(api.stroke_begin_with_brush_resource(engine, image, drawable, resource,
                                                          &settings, &point, &stroke, &error), error)
        } else {
            try check(api.stroke_begin(engine, image, drawable, &settings, &point, &stroke, &error), error)
        }
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

    /// Captured same-image source pixels are detached before the preview starts.
    /// Apply merges into target pixels; the auxiliary graph is not an XCF effect.
    func beginFilter(image: Int32, drawable: Int32, operation: String, source: Int32) throws -> Int32 {
        guard drawable > 0, source > 0, operation == "gegl:bump-map" else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Choose a pixel layer and a valid Bump Map source.")
        }
        var filter: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = operation.withCString { name in
            api.filter_begin_with_source(engine, image, drawable, name, source, &filter, &error)
        }
        try check(status, error)
        guard filter > 0 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The filter preview did not start.")
        }
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

    // MARK: Filter metadata

    /// Whether a native property form can drive the operation
    /// (GlimsFilterOpSupport).
    enum FilterOpSupport: Equatable {
        case supported
        /// Needs a second input layer; a later slice.
        case needsAuxInput
        /// Its settings live on a config object (Curves & co.); a later slice.
        case needsConfig
    }

    /// One filter operation of the engine catalog (GlimsOperationInfo).
    struct FilterOperation: Equatable {
        /// The engine's name, e.g. "gegl:gaussian-blur".
        let name: String
        /// The operation's human title, e.g. "Gaussian Blur".
        let title: String
        /// The engine's categories, split on ':'.
        let categories: [String]
        let blurb: String
        let support: FilterOpSupport
    }

    /// The property kinds the facade can read and write
    /// (GlimsFilterValueKind); `unsupported` rows show as disabled.
    enum FilterValueKind: Equatable {
        case unsupported, number, integer, boolean, enumeration, string, color
    }

    /// One editable property of an operation (GlimsFilterProperty).
    /// `minimum`/`maximum` are the absolute limits; `uiMinimum`…`uiGamma`
    /// the engine's suggested form range and mapping. Fields a kind does
    /// not use are zero.
    struct FilterProperty: Equatable {
        let name: String
        let label: String
        let blurb: String
        /// The engine's unit hint key, e.g. "pixel-distance"; "" when none.
        let unit: String
        let kind: FilterValueKind
        let minimum: Double
        let maximum: Double
        let uiMinimum: Double
        let uiMaximum: Double
        let uiStepSmall: Double
        let uiStepBig: Double
        let uiGamma: Double
        /// Suggested decimals; -1 for the default.
        let uiDigits: Int
        let defaultNumber: Double
        let defaultBool: Bool
        /// An enum's default nick, a string's default text.
        let defaultString: String
        let defaultColor: NSColor
        /// The enum's valid nick count.
        let choiceCount: Int
        /// The enum's choices; the catalog fills them in.
        var choices: [FilterEnumChoice] = []
    }

    /// One valid value of an enum property: `nick` is what the setter
    /// accepts, `label` what the user reads.
    struct FilterEnumChoice: Equatable {
        let nick: String
        let label: String
    }

    /// A typed property value of an open filter session.
    enum FilterValue: Equatable {
        case number(Double)
        case integer(Int64)
        case boolean(Bool)
        /// The choice's nick.
        case enumeration(String)
        case string(String)
        case color(NSColor)
    }

    /// The catalog's filter operations, sorted by name.
    func filterOperations() throws -> [FilterOperation] {
        var count: Int32 = 0
        try check(api.filter_operations(engine, nil, 0, &count), nil)
        var rows = [GlimsOperationInfo](repeating: GlimsOperationInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.filter_operations(engine, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map(Self.filterOperation)
    }

    /// One operation's editable properties in declaration order.
    func filterOperationProperties(_ operation: String) throws -> [FilterProperty] {
        var count: Int32 = 0
        try check(api.filter_operation_properties(engine, operation, nil, 0, &count), nil)
        var rows = [GlimsFilterProperty](repeating: GlimsFilterProperty(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.filter_operation_properties(engine, operation, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map(Self.property)
    }

    /// An enum property's valid nicks and labels.
    func filterEnumChoices(_ operation: String, property: String) throws -> [FilterEnumChoice] {
        var count: Int32 = 0
        try check(api.filter_enum_choices(engine, operation, property, nil, 0, &count), nil)
        var rows = [GlimsFilterEnumChoice](repeating: GlimsFilterEnumChoice(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.filter_enum_choices(engine, operation, property, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled)))
            .map { FilterEnumChoice(nick: Self.string($0.nick), label: Self.string($0.label)) }
    }

    struct BrightnessContrastSettings: Equatable {
        var brightness: Double = 0
        var contrast: Double = 0

        var isValid: Bool {
            brightness.isFinite && contrast.isFinite
                && (-1...1).contains(brightness) && (-1...1).contains(contrast)
        }
    }

    func brightnessContrastSettings(_ filter: Int32) throws -> BrightnessContrastSettings {
        var raw = GlimsBrightnessContrastSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsBrightnessContrastSettings>.size)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_brightness_contrast_get(engine, filter, &raw, &error)
        try check(status, error)
        let value = BrightnessContrastSettings(brightness: raw.brightness, contrast: raw.contrast)
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The adjustment settings could not be read.")
        }
        return value
    }

    func setBrightnessContrastSettings(_ filter: Int32, to value: BrightnessContrastSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: "Brightness and contrast must be between −1 and 1.")
        }
        var raw = GlimsBrightnessContrastSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsBrightnessContrastSettings>.size)
        raw.brightness = value.brightness; raw.contrast = value.contrast
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_brightness_contrast_set(engine, filter, &raw, &error)
        try check(status, error)
    }

    struct ColorBalanceSettings: Equatable {
        struct Range: Equatable {
            var cyanRed: Double = 0
            var magentaGreen: Double = 0
            var yellowBlue: Double = 0

            var isValid: Bool {
                [cyanRed, magentaGreen, yellowBlue].allSatisfy { $0.isFinite && (-1...1).contains($0) }
            }
        }
        var shadows = Range()
        var midtones = Range()
        var highlights = Range()
        var preserveLuminosity = true

        var isValid: Bool { shadows.isValid && midtones.isValid && highlights.isValid }
    }

    func colorBalanceSettings(_ filter: Int32) throws -> ColorBalanceSettings {
        var raw = GlimsColorBalanceSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsColorBalanceSettings>.size)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_color_balance_get(engine, filter, &raw, &error)
        try check(status, error)
        func range(_ value: GlimsColorBalanceRange) -> ColorBalanceSettings.Range {
            .init(cyanRed: value.cyan_red, magentaGreen: value.magenta_green, yellowBlue: value.yellow_blue)
        }
        let value = ColorBalanceSettings(shadows: range(raw.shadows), midtones: range(raw.midtones),
                                        highlights: range(raw.highlights), preserveLuminosity: raw.preserve_luminosity == 1)
        guard value.isValid, raw.preserve_luminosity <= 1 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The color balance settings could not be read.")
        }
        return value
    }

    func setColorBalanceSettings(_ filter: Int32, to value: ColorBalanceSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: "Color balance corrections must be between −1 and 1.")
        }
        func range(_ value: ColorBalanceSettings.Range) -> GlimsColorBalanceRange {
            .init(cyan_red: value.cyanRed, magenta_green: value.magentaGreen, yellow_blue: value.yellowBlue)
        }
        var raw = GlimsColorBalanceSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsColorBalanceSettings>.size)
        raw.preserve_luminosity = value.preserveLuminosity ? 1 : 0
        raw.shadows = range(value.shadows); raw.midtones = range(value.midtones); raw.highlights = range(value.highlights)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_color_balance_set(engine, filter, &raw, &error)
        try check(status, error)
    }

    /// Complete Levels values; the channel shown by a form is not native state.
    struct LevelsSettings: Equatable {
        struct Channel: Equatable {
            var lowInput: Double = 0
            var highInput: Double = 1
            var gamma: Double = 1
            var lowOutput: Double = 0
            var highOutput: Double = 1

            var isValid: Bool {
                [lowInput, highInput, lowOutput, highOutput].allSatisfy {
                    $0.isFinite && (0...1).contains($0)
                } && gamma.isFinite && (0.1...10).contains(gamma)
            }
        }

        var trc: ColorTRC = .linear
        var clampInput = false
        var clampOutput = false
        var value = Channel()
        var red = Channel()
        var green = Channel()
        var blue = Channel()
        var alpha = Channel()

        var isValid: Bool {
            // Equal or inverted endpoints are valid native mappings.
            [ColorTRC.linear, .nonlinear, .perceptual].contains(trc) &&
                [value, red, green, blue, alpha].allSatisfy { $0.isValid }
        }
    }

    func levelsSettings(_ filter: Int32) throws -> LevelsSettings {
        var raw = GlimsLevelsSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsLevelsSettings>.size)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_levels_get(engine, filter, &raw, &error)
        try check(status, error)
        guard let trc = ColorTRC(rawValue: raw.trc), trc != .unknown,
              raw.clamp_input <= 1, raw.clamp_output <= 1 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The Levels settings could not be read.")
        }
        func channel(_ value: GlimsLevelsChannel) -> LevelsSettings.Channel {
            .init(lowInput: value.low_input, highInput: value.high_input, gamma: value.gamma,
                  lowOutput: value.low_output, highOutput: value.high_output)
        }
        let value = LevelsSettings(trc: trc, clampInput: raw.clamp_input == 1,
            clampOutput: raw.clamp_output == 1, value: channel(raw.value), red: channel(raw.red),
            green: channel(raw.green), blue: channel(raw.blue), alpha: channel(raw.alpha))
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The Levels settings could not be read.")
        }
        return value
    }

    func setLevelsSettings(_ filter: Int32, to value: LevelsSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                message: "Levels endpoints must be between 0 and 1, gamma between 0.1 and 10, and the transfer curve must be known.")
        }
        func channel(_ value: LevelsSettings.Channel) -> GlimsLevelsChannel {
            .init(low_input: value.lowInput, high_input: value.highInput, gamma: value.gamma,
                  low_output: value.lowOutput, high_output: value.highOutput)
        }
        var raw = GlimsLevelsSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsLevelsSettings>.size)
        raw.trc = value.trc.rawValue
        raw.clamp_input = value.clampInput ? 1 : 0
        raw.clamp_output = value.clampOutput ? 1 : 0
        raw.value = channel(value.value); raw.red = channel(value.red)
        raw.green = channel(value.green); raw.blue = channel(value.blue); raw.alpha = channel(value.alpha)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_levels_set(engine, filter, &raw, &error)
        try check(status, error)
    }

    private func decodeCurves(_ raw: GlimsCurvesSnapshot) throws -> CurvesSettings {
        func malformed() -> EngineError {
            EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The Curves settings could not be read.")
        }
        func channel(_ raw: GlimsCurveState) throws -> CurveState {
            guard let kind = CurveKind(rawValue: raw.kind), raw.identity <= 1,
                  raw.point_count <= 65_536, raw.sample_count == 256,
                  raw.point_count == 0 || raw.points != nil, let samples = raw.samples else { throw malformed() }
            var points: [CurvePoint] = []
            if let pointer = raw.points {
                points = try UnsafeBufferPointer(start: pointer, count: Int(raw.point_count)).map {
                    guard let type = CurvePointKind(rawValue: $0.kind) else { throw malformed() }
                    return CurvePoint(x: $0.x, y: $0.y, kind: type)
                }
            }
            let value = CurveState(kind: kind, identity: raw.identity == 1, points: points,
                                   samples: Array(UnsafeBufferPointer(start: samples, count: 256)))
            guard value.isValid else { throw malformed() }
            return value
        }
        guard let trc = ColorTRC(rawValue: raw.trc), trc != .unknown else { throw malformed() }
        return try CurvesSettings(trc: trc, value: channel(raw.value), red: channel(raw.red),
                                   green: channel(raw.green), blue: channel(raw.blue), alpha: channel(raw.alpha))
    }

    func curvesSettings(_ filter: Int32) throws -> CurvesSettings {
        var raw = GlimsCurvesSnapshot()
        raw.struct_size = UInt32(MemoryLayout<GlimsCurvesSnapshot>.size)
        defer { api.free_curves_snapshot(&raw) }
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_curves_get(engine, filter, &raw, &error)
        try check(status, error)
        return try decodeCurves(raw)
    }

    func editCurve(_ filter: Int32, edit: CurveEdit) throws -> CurvesSettings {
        guard edit.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Curve coordinates and samples must be from 0 to 1, with points ordered by input.")
        }
        var input = GlimsCurveEdit()
        input.struct_size = UInt32(MemoryLayout<GlimsCurveEdit>.size)
        input.channel = edit.channel.rawValue
        var points: [GlimsCurvePoint] = []
        var samples: [Double] = []
        switch edit {
        case .smooth(_, let value):
            input.mode = GLIMS_CURVE_EDIT_SMOOTH_POINTS.rawValue
            points = value.map { GlimsCurvePoint(x: $0.x, y: $0.y, kind: $0.kind.rawValue) }
        case .free(_, let value):
            input.mode = GLIMS_CURVE_EDIT_FREE_SAMPLES.rawValue
            samples = value
        case .reset:
            input.mode = GLIMS_CURVE_EDIT_RESET.rawValue
        }
        var raw = GlimsCurvesSnapshot()
        raw.struct_size = UInt32(MemoryLayout<GlimsCurvesSnapshot>.size)
        defer { api.free_curves_snapshot(&raw) }
        var error: UnsafeMutablePointer<CChar>?
        let status = points.withUnsafeBufferPointer { pointBuffer in
            samples.withUnsafeBufferPointer { sampleBuffer in
                input.point_count = UInt32(pointBuffer.count)
                input.points = pointBuffer.isEmpty ? nil : pointBuffer.baseAddress
                input.sample_count = UInt32(sampleBuffer.count)
                input.samples = sampleBuffer.isEmpty ? nil : sampleBuffer.baseAddress
                return api.filter_curves_edit(engine, filter, &input, &raw, &error)
            }
        }
        try check(status, error)
        return try decodeCurves(raw)
    }

    func setCurvesTRC(_ filter: Int32, to trc: ColorTRC) throws -> CurvesSettings {
        guard trc != .unknown else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: "Choose a transfer curve.")
        }
        var raw = GlimsCurvesSnapshot()
        raw.struct_size = UInt32(MemoryLayout<GlimsCurvesSnapshot>.size)
        defer { api.free_curves_snapshot(&raw) }
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_curves_set_trc(engine, filter, trc.rawValue, &raw, &error)
        try check(status, error)
        return try decodeCurves(raw)
    }

    struct HueSaturationSettings: Equatable {
        struct Range: Equatable {
            var hue: Double = 0
            var saturation: Double = 0
            var lightness: Double = 0
            var isValid: Bool {
                [hue, saturation, lightness].allSatisfy { $0.isFinite && (-1...1).contains($0) }
            }
        }
        var overlap: Double = 0
        var master = Range()
        var red = Range()
        var yellow = Range()
        var green = Range()
        var cyan = Range()
        var blue = Range()
        var magenta = Range()
        var isValid: Bool {
            overlap.isFinite && (0...1).contains(overlap) &&
                [master, red, yellow, green, cyan, blue, magenta].allSatisfy { $0.isValid }
        }
    }

    func hueSaturationSettings(_ filter: Int32) throws -> HueSaturationSettings {
        var raw = GlimsHueSaturationSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsHueSaturationSettings>.size)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_hue_saturation_get(engine, filter, &raw, &error)
        try check(status, error)
        func range(_ value: GlimsHueSaturationRange) -> HueSaturationSettings.Range {
            .init(hue: value.hue, saturation: value.saturation, lightness: value.lightness)
        }
        let value = HueSaturationSettings(overlap: raw.overlap, master: range(raw.master), red: range(raw.red),
            yellow: range(raw.yellow), green: range(raw.green), cyan: range(raw.cyan),
            blue: range(raw.blue), magenta: range(raw.magenta))
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The hue and saturation settings could not be read.")
        }
        return value
    }

    func setHueSaturationSettings(_ filter: Int32, to value: HueSaturationSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                message: "Hue, saturation and lightness must be between −1 and 1; overlap must be between 0 and 1.")
        }
        func range(_ value: HueSaturationSettings.Range) -> GlimsHueSaturationRange {
            .init(hue: value.hue, saturation: value.saturation, lightness: value.lightness)
        }
        var raw = GlimsHueSaturationSettings()
        raw.struct_size = UInt32(MemoryLayout<GlimsHueSaturationSettings>.size)
        raw.overlap = value.overlap
        raw.master = range(value.master); raw.red = range(value.red); raw.yellow = range(value.yellow)
        raw.green = range(value.green); raw.cyan = range(value.cyan); raw.blue = range(value.blue)
        raw.magenta = range(value.magenta)
        var error: UnsafeMutablePointer<CChar>?
        let status = api.filter_hue_saturation_set(engine, filter, &raw, &error)
        try check(status, error)
    }

    /// One property's current value in an open filter session.
    func filterProperty(_ filter: Int32, _ property: String) throws -> FilterValue {
        var value = GlimsFilterValue()
        try check(api.filter_get_property(engine, filter, property, &value), nil)
        guard let converted = Self.value(value) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned a value kind the form cannot read.")
        }
        return converted
    }

    /// Sets one property of an open filter session; the preview updates
    /// without an undo step.
    func setFilterProperty(_ filter: Int32, _ property: String, to value: FilterValue) throws {
        var raw = try Self.rawValue(value)
        try check(api.filter_set_property(engine, filter, property, &raw), nil)
    }

    private static func filterOperation(_ row: GlimsOperationInfo) -> FilterOperation {
        let support: FilterOpSupport
        switch Int(row.support) {
        case Int(GLIMS_FILTER_OP_AUX_INPUT.rawValue): support = .needsAuxInput
        case Int(GLIMS_FILTER_OP_CONFIG.rawValue): support = .needsConfig
        default: support = .supported
        }
        return FilterOperation(name: string(row.name), title: string(row.title),
                               categories: string(row.categories).split(separator: ":").map(String.init),
                               blurb: string(row.blurb), support: support)
    }

    private static func property(_ row: GlimsFilterProperty) -> FilterProperty {
        let kind: FilterValueKind
        switch Int(row.kind) {
        case Int(GLIMS_FILTER_VALUE_NUMBER.rawValue): kind = .number
        case Int(GLIMS_FILTER_VALUE_INTEGER.rawValue): kind = .integer
        case Int(GLIMS_FILTER_VALUE_BOOL.rawValue): kind = .boolean
        case Int(GLIMS_FILTER_VALUE_ENUM.rawValue): kind = .enumeration
        case Int(GLIMS_FILTER_VALUE_STRING.rawValue): kind = .string
        case Int(GLIMS_FILTER_VALUE_COLOR.rawValue): kind = .color
        default: kind = .unsupported
        }
        return FilterProperty(name: string(row.name), label: string(row.label),
                              blurb: string(row.blurb), unit: string(row.unit), kind: kind,
                              minimum: row.min, maximum: row.max,
                              uiMinimum: row.ui_min, uiMaximum: row.ui_max,
                              uiStepSmall: row.ui_step_small, uiStepBig: row.ui_step_big,
                              uiGamma: row.ui_gamma, uiDigits: Int(row.ui_digits),
                              defaultNumber: row.default_number, defaultBool: row.default_bool,
                              defaultString: string(row.default_string),
                              defaultColor: Self.nsColor(row.default_color),
                              choiceCount: Int(row.choice_count))
    }

    private static func value(_ raw: GlimsFilterValue) -> FilterValue? {
        switch Int(raw.kind) {
        case Int(GLIMS_FILTER_VALUE_NUMBER.rawValue): return .number(raw.number)
        case Int(GLIMS_FILTER_VALUE_INTEGER.rawValue): return .integer(raw.integer)
        case Int(GLIMS_FILTER_VALUE_BOOL.rawValue): return .boolean(raw.boolean)
        case Int(GLIMS_FILTER_VALUE_ENUM.rawValue): return .enumeration(string(raw.string))
        case Int(GLIMS_FILTER_VALUE_STRING.rawValue): return .string(string(raw.string))
        case Int(GLIMS_FILTER_VALUE_COLOR.rawValue): return .color(Self.nsColor(raw.color))
        default: return nil
        }
    }

    private static func rawValue(_ value: FilterValue) throws -> GlimsFilterValue {
        var raw = GlimsFilterValue()
        switch value {
        case .number(let number):
            guard number.isFinite else {
                throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                  message: "The filter setting needs a finite number.")
            }
            raw.kind = GLIMS_FILTER_VALUE_NUMBER.rawValue
            raw.number = number
        case .integer(let integer):
            raw.kind = GLIMS_FILTER_VALUE_INTEGER.rawValue
            raw.integer = integer
        case .boolean(let boolean):
            raw.kind = GLIMS_FILTER_VALUE_BOOL.rawValue
            raw.boolean = boolean
        case .enumeration(let nick):
            raw.kind = GLIMS_FILTER_VALUE_ENUM.rawValue
            copy(nick, into: &raw.string)
        case .string(let text):
            raw.kind = GLIMS_FILTER_VALUE_STRING.rawValue
            copy(text, into: &raw.string)
        case .color(let color):
            raw.kind = GLIMS_FILTER_VALUE_COLOR.rawValue
            raw.color = try Self.color(color)
        }
        return raw
    }

    private static func nsColor(_ color: GlimsColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
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

    /// Strokes the selection's boundary on `drawable` — an attached layer
    /// of the image (nil: the selected layer) — with `brush`'s tool and
    /// settings, as exactly one undo step (selection_stroke). The native
    /// core suspends the selection for the stroke, so the line straddles
    /// the boundary and paints both sides of it; the selection itself is
    /// never modified. `brush.resource` is resolved to a live handle
    /// here, on the engine worker this call runs on — never a session id
    /// is stored — and a nil resource keeps the established convention of
    /// `beginStroke`: the stroke inherits the user context's current
    /// brush. An empty selection, a non-layer target (group, mask,
    /// channel), a locked target, bad settings or a stale/malformed
    /// brush handle fail without changing pixels or history; BUSY while
    /// a stroke, a filter session or a plug-in holds the image.
    func strokeSelection(image: Int32, drawable: Int32? = nil, brush: Brush) throws {
        var settings = Self.nativeBrush(brush)
        var error: UnsafeMutablePointer<CChar>?
        let resource: ResourceID
        if let identity = brush.resource {
            resource = try resolveResource(identity, kind: .brush)
        } else {
            resource = 0
        }
        try check(api.selection_stroke(engine, image, drawable ?? 0, resource, &settings, &error), error)
    }

    // MARK: Floating selections (Paste Into)

    /// What a floating selection is attached to (GlimsFloatingTargetKind).
    enum FloatingTargetKind: UInt32 {
        case layer = 1, layerMask = 2, channel = 3
    }

    /// The image's floating-selection state (image_floating_selection):
    /// the floating layer's id and the drawable it is attached to, both
    /// zero when no floating selection is active.
    struct FloatingState: Equatable {
        /// The floating layer's id; 0 when none is active.
        let floating: Int32
        /// The drawable the floating layer is attached to; 0 when none.
        let target: Int32
        /// What the target is; nil when no floating selection is active.
        let targetKind: FloatingTargetKind?
        var isActive: Bool { floating != 0 }
    }

    /// How `floatingCommand(_:image:expected:)` resolves a floating
    /// selection (GlimsFloatingCommand); each case is one undo step.
    enum FloatingCommand: UInt32 {
        /// Merge the floating layer into its attached target.
        case anchor = 1
        /// Detach it as an independent layer; refused for mask/channel targets.
        case toLayer = 2
        /// Remove it without merging.
        case discard = 3
    }

    /// The image's floating selection, as a plain read (allowed at any
    /// time, also while the image is busy): `.isActive` false with zero
    /// ids when none exists. Throws NOT_FOUND for an unknown image and
    /// INVALID_ARGUMENT if the engine reports an unknown target kind.
    func floatingSelection(_ image: Int32) throws -> FloatingState {
        var state = GlimsFloatingState()
        state.struct_size = UInt32(MemoryLayout<GlimsFloatingState>.size)
        try check(api.image_floating_selection(engine, image, &state), nil)
        let kind: FloatingTargetKind?
        if state.active {
            guard let parsed = FloatingTargetKind(rawValue: state.target_kind) else {
                throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                  message: "The engine returned an unknown floating target kind.")
            }
            kind = parsed
        } else {
            kind = nil
        }
        return FloatingState(floating: state.floating, target: state.target, targetKind: kind)
    }

    /// Pastes `pixels` into the existing selection of `image`, attached
    /// to `target` (0: the image's selected drawable), as a floating
    /// selection — exactly one undo step, returned as the floating
    /// layer's id. The preview is clipped to the selection; the target's
    /// own pixels stay unchanged until `floatingCommand` resolves it,
    /// and the selection itself is never modified. Unlike
    /// `pastePixels`, this never creates an independent new layer.
    /// Throws FAILED when a floating selection already exists (it must
    /// be resolved first, never silently anchored), when there is no
    /// selection or it does not intersect the target, or for a group,
    /// locked or otherwise invalid target; REQUIRES_RASTERIZE for a
    /// genuine editable text/link/vector layer target; NOT_FOUND for an
    /// unknown image or a stale/foreign target id; INVALID_ARGUMENT for
    /// malformed pixels; BUSY while a stroke, filter session or plug-in
    /// holds the image.
    @discardableResult
    func pasteInto(_ image: Int32, target: Int32 = 0, pixels: ClipboardImage) throws -> Int32 {
        guard pixels.pixels.count == (try ClipboardImage.byteCount(width: pixels.width, height: pixels.height)) else {
            throw ClipboardImage.TransferError.invalidImage
        }
        let bounds = GlimsRect(x: Int32(pixels.origin.x.rounded()), y: Int32(pixels.origin.y.rounded()),
                               width: Int32(pixels.width), height: Int32(pixels.height))
        var floating: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try pixels.pixels.withUnsafeBytes { bytes in
            try check(api.image_paste_into(engine, image, target, bounds,
                                           bytes.bindMemory(to: UInt8.self).baseAddress,
                                           bytes.count, &floating, &error), error)
        }
        return floating
    }

    /// Resolves the floating selection `expected` names in `image` with
    /// `command`, one undo step. `expected` must be the id of the
    /// floating selection that is actually active — 0 throws
    /// INVALID_ARGUMENT and a stale/foreign id NOT_FOUND; neither falls
    /// back to the active floating selection. Returns the layer id for
    /// `.toLayer`, nil for `.anchor`/`.discard`. Throws FAILED with the
    /// engine's reason for `.toLayer` on a mask/channel-attached floating
    /// selection, NOT_FOUND when no floating selection exists, BUSY
    /// while a stroke, filter session or plug-in holds the image.
    @discardableResult
    func floatingCommand(_ command: FloatingCommand, image: Int32, expected: Int32) throws -> Int32? {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.floating_command(engine, image, expected, command.rawValue, &result, &error), error)
        return result == 0 ? nil : result
    }

    /// How `floatSelection(_:image:target:mode:)` takes the selected
    /// pixels off their target (GlimsFloatMode): `.move` cuts them out of
    /// it, `.copy` leaves the target untouched.
    enum FloatMode: UInt32 {
        /// Cut the selection out of the target; it keeps a transparent hole.
        case move = 1
        /// Copy the selection; the target's pixels stay as they are.
        case copy = 2
    }

    /// Floats the current selection of `image` into a floating selection
    /// attached to `target` (0: the image's selected drawable, which must
    /// be exactly one), as exactly one undo step, and returns the floating
    /// layer's id. The selection is cleared by the float; `move` leaves a
    /// transparent hole in the target where the selection was, `copy`
    /// does not. The floating layer lands on the selection's bounds and
    /// `moveLayer` moves it from there; resolve it with `floatingCommand`.
    /// Throws FAILED when a floating selection already exists, when there
    /// is no selection or it does not intersect the target, or for the
    /// selection mask itself, a group target or a core failure;
    /// NOT_FOUND for an unknown image or a stale/foreign target id;
    /// INVALID_ARGUMENT for an unknown mode; LOCKED for `.move` on a
    /// content- or alpha-locked target (`.copy` is non-destructive);
    /// REQUIRES_RASTERIZE for a genuine editable text/link/vector target;
    /// BUSY while a stroke, filter session or plug-in holds the image.
    @discardableResult
    func floatSelection(_ image: Int32, target: Int32 = 0, mode: FloatMode) throws -> Int32 {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.selection_float(engine, image, target, mode.rawValue, &result, &error), error)
        return result
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
                                         mode: mode.rawValue, color: try Self.color(color), opacity: opacity,
                                         threshold: threshold, sample_merged: sampleMerged, antialias: true)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.fill(engine, image, GlimsPoint(x: point.x, y: point.y), &settings, &error), error)
    }

    /// Fills the selected drawable (the active layer, its mask while mask
    /// editing is on, or a selected channel) with the pattern `pattern`,
    /// tiled from the drawable's origin, as one undo step. `pattern` is a
    /// live handle from `resources(_:)`/`resolveResource(_:kind:)`; a
    /// stale, foreign or non-pattern handle throws NOT_FOUND, and a
    /// malformed one (0, high bits, above the native id range)
    /// INVALID_ARGUMENT. `seed` is in image pixels and only matters for
    /// `.similarColors`. Runs synchronously on the engine thread, so call
    /// it off the main thread like the other edits.
    func fillPattern(image: Int32, pattern: ResourceID, seed: CGPoint,
                     _ settings: PatternFillSettings) throws {
        var native = GlimsPatternFillSettings(struct_size: UInt32(MemoryLayout<GlimsPatternFillSettings>.size),
                                             mode: settings.mode.rawValue, opacity: settings.opacity,
                                             threshold: settings.threshold, sample_merged: settings.sampleMerged,
                                             antialias: settings.antialias)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.fill_pattern(engine, image, pattern, GlimsPoint(x: seed.x, y: seed.y), &native, &error), error)
    }

    func gradient(image: Int32, from: CGPoint, to: CGPoint, shape: GradientShape,
                  fromColor: NSColor, toColor: NSColor, opacity: Double = 1) throws {
        var settings = GlimsGradientSettings(struct_size: UInt32(MemoryLayout<GlimsGradientSettings>.size),
                                             shape: shape.rawValue, from: try Self.color(fromColor),
                                             to: try Self.color(toColor), opacity: opacity)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.gradient(engine, image, GlimsPoint(x: from.x, y: from.y), GlimsPoint(x: to.x, y: to.y),
                               &settings, &error), error)
    }

    /// Draws a gradient with the gradient resource `gradient` names, on
    /// the selected drawable, one undo step. Unlike `gradient(image:from:to:shape:fromColor:toColor:)`,
    /// which always paints the built-in foreground-to-background ramp,
    /// the stops come from the resource — there is no fallback when the
    /// handle does not resolve. `gradient` is a session handle from
    /// `resources(_:)` or `resolveResource(_:kind:)`; throw NOT_FOUND's
    /// caller for anything else. The resource is never mutated.
    func gradient(image: Int32, resource gradient: ResourceID, from: CGPoint, to: CGPoint,
                  settings: ResourceGradientSettings) throws {
        var values = GlimsResourceGradientSettings(
            struct_size: UInt32(MemoryLayout<GlimsResourceGradientSettings>.size),
            shape: settings.shape.rawValue,
            foreground: try Self.color(settings.foreground),
            background: try Self.color(settings.background),
            opacity: settings.opacity, reverse: settings.reverse,
            blend_space: settings.blendSpace.rawValue)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.gradient_resource(engine, image, gradient,
                                        GlimsPoint(x: from.x, y: from.y), GlimsPoint(x: to.x, y: to.y),
                                        &values, &error), error)
    }

    /// A layer's structured-content source (layer_source_info): its own
    /// class kind — kept after rasterization, unlike `Layer.kind` —
    /// whether it currently behaves as pixels, and whether the text,
    /// link or path source survived.
    struct LayerSource: Equatable {
        let kind: LayerKind
        /// The editable predicate is off: the layer's content is pixels.
        let isRasterized: Bool
        /// The layer still carries its text, link or path source.
        let hasSource: Bool
    }

    /// The layer's structured-source state (`layer` 0: the selected
    /// layer). A read; throws NOT_FOUND for a stale, foreign or closed
    /// id.
    func layerSource(_ layer: Int32, image: Int32) throws -> LayerSource {
        var info = GlimsLayerSourceInfo()
        info.struct_size = UInt32(MemoryLayout<GlimsLayerSourceInfo>.size)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_source_info(engine, image, layer, &info, &error), error)
        let kind: LayerKind
        switch Int(info.source_kind) {
        case Int(GLIMS_LAYER_GROUP.rawValue): kind = .group
        case Int(GLIMS_LAYER_TEXT.rawValue): kind = .text
        case Int(GLIMS_LAYER_LINK.rawValue): kind = .link
        case Int(GLIMS_LAYER_VECTOR.rawValue): kind = .vector
        case Int(GLIMS_LAYER_PIXEL.rawValue): kind = .pixel
        default:
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned an unknown layer source kind.")
        }
        return LayerSource(kind: kind, isRasterized: info.is_rasterized, hasSource: info.has_source)
    }

    func selectLayer(_ layer: Int32, image: Int32) throws {
        try check(api.layer_select(engine, image, layer), nil)
    }

    /// The image's selected layer ids in the engine's own order — the
    /// order `selectLayers(_:image:)` last set, active layer first
    /// (image_selected_layers). A plain read: allowed at any time, also
    /// while a stroke, a filter session or a plug-in holds the image;
    /// throws NOT_FOUND for an unknown image.
    func selectedLayers(_ image: Int32) throws -> [Int32] {
        try Self.readWholeSelection { ids, capacity, count in
            try self.check(self.api.image_selected_layers(self.engine, image, ids, capacity, &count), nil)
        }
    }

    /// Selects exactly `layers`, in that order, as the image's whole
    /// selected-layer list (image_select_layers); an empty array clears
    /// it. Transient: no undo step, no dirty flag, no pixel, selection
    /// or mask change; a change delivers `layersChanged`. The whole
    /// input is validated before any mutation: INVALID_ARGUMENT for a
    /// repeated id, the id 0, or a mask/channel/path id; NOT_FOUND for a
    /// stale, foreign or detached id, or an unknown image; FAILED while
    /// a floating selection is active unless `layers` is exactly that
    /// floating layer (which is a no-op, never an anchor).
    func selectLayers(_ layers: [Int32], image: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try layers.withUnsafeBufferPointer { buffer in
            try check(api.image_select_layers(engine, image, buffer.baseAddress, buffer.count, &error), error)
        }
    }

    /// The image's selected item ids of `kind`, in the engine's own order
    /// — the order `selectItems(_:kind:image:)` last set, active item
    /// first (image_selected_items, slot 137). A plain read: allowed at
    /// any time, also while the image is busy; throws INVALID_ARGUMENT for
    /// an unknown kind, NOT_FOUND for an unknown image.
    /// A count/fill pair may race a native selection change. Retry growth
    /// instead of publishing a truncated list as the whole selection.
    static func readWholeSelection(_ read: (UnsafeMutablePointer<Int32>?, Int32, inout Int32) throws -> Void) throws -> [Int32] {
        for _ in 0..<3 {
            var capacity: Int32 = 0
            try read(nil, 0, &capacity)
            guard (0...1_000_000).contains(capacity) else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The engine returned an invalid selection size.")
            }
            if capacity == 0 { return [] }
            var ids = [Int32](repeating: 0, count: Int(capacity))
            var total: Int32 = 0
            try ids.withUnsafeMutableBufferPointer { buffer in
                try read(buffer.baseAddress, capacity, &total)
            }
            guard total >= 0 else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The engine returned an invalid selection size.")
            }
            if total > capacity { continue }
            let selected = Array(ids.prefix(Int(total)))
            guard selected.allSatisfy({ $0 > 0 }), Set(selected).count == selected.count else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The engine returned invalid selected item IDs.")
            }
            return selected
        }
        throw EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue), message: "The selection changed while it was being read. Try again.")
    }

    func selectedItems(_ kind: ItemSetKind, image: Int32) throws -> [Int32] {
        try Self.readWholeSelection { ids, capacity, count in
            try self.check(self.api.image_selected_items(self.engine, image, kind.rawValue, ids, capacity, &count), nil)
        }
    }

    /// Selects exactly `items`, in that order, as the image's whole
    /// selected list of `kind` (image_select_items, slot 136); an empty
    /// array clears channel/path selection; an empty layer array is refused.
    /// Channels go back to the layers the channel selection replaced. Transient: no undo step, no dirty flag, no
    /// pixel, selection-mask or layer-mask data change; a floating selection is never
    /// anchored. Requires edit readiness: throws BUSY while a stroke, a
    /// filter preview or a plug-in holds the image. The whole input is
    /// validated before any mutation: INVALID_ARGUMENT for a repeated id,
    /// the id 0, an id of another kind or a negative count; NOT_FOUND for
    /// a stale, foreign or detached id, or an unknown image; FAILED under an
    /// active floating selection unless `items` is exactly that floating
    /// layer (a no-op, never an anchor) — a non-empty channel list is
    /// refused there, an empty one is allowed, and path selection is
    /// allowed under a floating selection.
    func selectItems(_ items: [Int32], kind: ItemSetKind, image: Int32) throws {
        guard items.count <= Int(Int32.max) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The item list is too long for the engine interface.")
        }
        var error: UnsafeMutablePointer<CChar>?
        try items.withUnsafeBufferPointer { buffer in
            try check(api.image_select_items(engine, image, kind.rawValue,
                                             buffer.baseAddress, Int32(buffer.count), &error), error)
        }
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

    // MARK: Layer tree structure

    /// The item's own locks and the locks the engine enforces on it
    /// (`layer` 0: the selected layer).
    func layerState(_ layer: Int32, image: Int32) throws -> LayerLockState {
        var state = GlimsLayerState()
        try check(api.layer_state(engine, image, layer, &state), nil)
        return LayerLockState(local: LayerLocks(rawValue: state.locks),
                              effective: LayerLocks(rawValue: state.locked))
    }

    /// Adds a layer group at `index` among `parent`'s children (`parent`
    /// 0: the image's top level), pass-through and selected, as one undo
    /// step. Returns it.
    @discardableResult
    func createGroup(image: Int32, parent: Int32 = 0, index: Int32, name: String? = nil) throws -> Int32 {
        var group: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(name) { name in
            try check(api.create_group(engine, image, parent, index, name, &group, &error), error)
        }
        return group
    }

    /// Creates a committed pass-through group with one filter using its
    /// native default parameters. Group and effect share one Undo step;
    /// edit the returned effect through the ordinary preview lifecycle.
    func createAdjustmentLayer(image: Int32, parent: Int32 = 0, index: Int32,
                               operation: String, name: String? = nil) throws
        -> (layer: Int32, effect: Int32) {
        guard !operation.isEmpty, !operation.utf8.contains(0),
              name.map({ !$0.isEmpty && !$0.utf8.contains(0) }) ?? true else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The adjustment name or operation contains invalid text.")
        }
        var layer: Int32 = 0
        var effect: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(name) { name in
            try check(api.adjustment_layer_new(engine, image, parent, index,
                                                operation, name, &layer, &effect, &error), error)
        }
        return (layer, effect)
    }

    /// Moves `item` to `index` among `newParent`'s children (`newParent`
    /// 0: the image's top level) as one undo step; undo and redo restore
    /// the exact position. `index` counts the children as they are after
    /// removing `item` when it is among them.
    func reparentLayer(_ item: Int32, image: Int32, toParent newParent: Int32, index: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.reparent_layer(engine, image, item, newParent, index, &error), error)
    }

    /// Sets the lock bits in `mask` on `item` (0: the selected layer) to
    /// `values`' bits as one undo step; locks outside `mask` stay.
    func setLayerLocks(_ item: Int32, image: Int32, mask: LayerLocks, values: LayerLocks) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.set_layer_locks(engine, image, item, mask.rawValue, values.rawValue, &error), error)
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

    // MARK: Layer masks

    /// A layer's mask state (GlimsMaskState): `mask` is the mask's
    /// drawable id — usable as the drawable argument of `beginStroke`,
    /// `beginFilter` and `drawableThumbnail` — or 0 when the layer has
    /// none. `enabled` gates the mask's effect on the composite,
    /// `editing` makes it the target of painting, fills and gradients
    /// while its layer is the only selected one, and `showing` displays
    /// the mask itself instead of the composite.
    struct MaskState: Equatable {
        var mask: Int32 = 0
        var enabled = false
        var editing = false
        var showing = false
    }

    /// What a new layer mask is made from (GlimsMaskSource), in the
    /// order the Add Mask form lists them.
    enum MaskSource: UInt32, CaseIterable {
        case white = 1, black, alpha, alphaTransfer = 4, selection, grayscale

        var title: String {
            switch self {
            case .white: return "White (full opacity)"
            case .black: return "Black (full transparency)"
            case .alpha: return "Layer's alpha channel"
            case .alphaTransfer: return "Layer's alpha channel (transparency transferred to layer)"
            case .selection: return "Selection"
            case .grayscale: return "Grayscale copy of the layer"
            }
        }
    }

    /// What `applyLayerMask` does with a mask (GlimsMaskApply).
    enum MaskApply: UInt32 {
        /// Bakes the mask into the layer, then removes it.
        case apply = 1
        /// Removes the mask without applying it.
        case discard
    }

    /// The mask flags `setLayerMask` touches (GlimsMaskFlag).
    struct MaskFlags: OptionSet, Equatable {
        let rawValue: UInt32
        static let enabled = MaskFlags(rawValue: GLIMS_MASK_ENABLED.rawValue)
        static let editing = MaskFlags(rawValue: GLIMS_MASK_EDITING.rawValue)
        static let showing = MaskFlags(rawValue: GLIMS_MASK_SHOWING.rawValue)
    }

    /// Reads `layer`'s mask state; `mask` is 0 when it has none.
    func layerMask(_ layer: Int32, image: Int32) throws -> MaskState {
        var state = GlimsMaskState()
        try check(api.layer_mask(engine, image, layer, &state), nil)
        return MaskState(mask: state.mask, enabled: state.enabled,
                         editing: state.editing, showing: state.showing)
    }

    /// Adds a mask made from `source` to `layer` and returns its drawable
    /// id. With `edit` the mask also becomes the edit target of painting,
    /// fills and gradients while `layer` stays the only selected layer.
    /// Fails when `layer` already has a mask or is empty.
    @discardableResult
    func addLayerMask(_ layer: Int32, image: Int32, source: MaskSource,
                      edit: Bool = false) throws -> Int32 {
        var mask: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_mask_add(engine, image, layer, source.rawValue, edit, &mask, &error), error)
        return mask
    }

    /// Sets the `MaskFlags` bits named by `flags` to `values`'s bits;
    /// flags outside `flags` keep their state.
    func setLayerMask(_ layer: Int32, image: Int32, flags: MaskFlags, values: MaskFlags) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_mask_set(engine, image, layer, flags.rawValue, values.rawValue, &error), error)
    }

    /// Applies `layer`'s mask into the layer or discards it. Applying is
    /// refused on groups and text, link and vector layers.
    func applyLayerMask(_ layer: Int32, image: Int32, mode: MaskApply) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_mask_apply(engine, image, layer, mode.rawValue, &error), error)
    }

    /// Combines `layer`'s mask into the selection by `operation`.
    func layerMaskToSelection(_ layer: Int32, image: Int32,
                              operation: SelectOperation) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.layer_mask_to_selection(engine, image, layer, operation.rawValue, &error), error)
    }

    /// `drawable`'s pixels (a layer, layer mask or channel id) scaled down
    /// to fit `maxSize` × `maxSize`, never up-scaled: straight-alpha
    /// 8-bit sRGB RGBA. Nil when the drawable is gone or empty.
    func drawableThumbnail(_ drawable: Int32, image: Int32,
                           maxSize: Int32 = 32) throws -> CGImage? {
        var width: Int32 = 0
        var height: Int32 = 0
        // The written size never exceeds maxSize on an edge, so this
        // buffer always holds the whole image in one call.
        var pixels = [UInt8](repeating: 0, count: Int(maxSize) * Int(maxSize) * 4)
        try pixels.withUnsafeMutableBufferPointer { buffer in
            try check(api.drawable_thumbnail(engine, image, drawable, maxSize,
                                            buffer.baseAddress, buffer.count, &width, &height), nil)
        }
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0 else { return nil }
        let data = Data(bytes: pixels, count: w * h * 4) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: Committed effects

    struct Effect: Equatable {
        let id: Int32
        let name: String
        let operation: String
        let isEnabled: Bool
        let opacity: Double
    }

    struct EffectChange: Equatable {
        /// An empty name restores the operation's default title.
        var name: String?
        var isEnabled: Bool?
        var opacity: Double?
    }

    enum EffectCommand: UInt32 {
        case remove = 1, merge, raise, lower, toTop, toBottom
    }

    /// Top first, in the order displayed beneath the drawable. Live
    /// preview sessions are separate from these committed effect ids.
    func effects(on drawable: Int32, image: Int32) throws -> [Effect] {
        var count: Int32 = 0
        try check(api.drawable_effects(engine, image, drawable, nil, 0, &count), nil)
        var rows = [GlimsEffectInfo](repeating: GlimsEffectInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.drawable_effects(engine, image, drawable, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map {
            Effect(id: $0.id, name: Self.string($0.name), operation: Self.string($0.operation),
                   isEnabled: $0.enabled, opacity: $0.opacity)
        }
    }

    func changeEffect(_ effect: Int32, on drawable: Int32, image: Int32, _ change: EffectChange) throws {
        var settings = GlimsEffectChange()
        settings.struct_size = UInt32(MemoryLayout<GlimsEffectChange>.size)
        if let name = change.name {
            settings.properties |= GLIMS_EFFECT_NAME.rawValue
            Self.copy(name, into: &settings.name)
        }
        if let enabled = change.isEnabled {
            settings.properties |= GLIMS_EFFECT_ENABLED.rawValue
            settings.enabled = enabled
        }
        if let opacity = change.opacity {
            settings.properties |= GLIMS_EFFECT_OPACITY.rawValue
            settings.opacity = opacity
        }
        var error: UnsafeMutablePointer<CChar>?
        try check(api.effect_change(engine, image, drawable, effect, &settings, &error), error)
    }

    func effectCommand(_ command: EffectCommand, effect: Int32, on drawable: Int32, image: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.effect_command(engine, image, drawable, effect, command.rawValue, &error), error)
    }

    /// Opens a live session editing committed effect `effect` of
    /// `drawable` (filter_edit_begin): property reads see its current
    /// parameters, writes preview new ones through its own mask at its
    /// stack position. `commitFilter` writes them back into the same
    /// effect — id, order, name, enabled and opacity kept — as one undo
    /// step; `abortFilter` restores it untouched. Returns a filter
    /// session id, not an effect id; a stale, foreign, removed or
    /// preview effect id is NOT_FOUND.
    func beginEditingEffect(_ effect: Int32, on drawable: Int32, image: Int32) throws -> Int32 {
        var filter: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.filter_edit_begin(engine, image, drawable, effect, &filter, &error), error)
        return filter
    }

    // MARK: Channels and components

    struct Components: OptionSet, Equatable {
        let rawValue: UInt32
        static let red = Components(rawValue: GLIMS_COMPONENT_RED.rawValue)
        static let green = Components(rawValue: GLIMS_COMPONENT_GREEN.rawValue)
        static let blue = Components(rawValue: GLIMS_COMPONENT_BLUE.rawValue)
        static let alpha = Components(rawValue: GLIMS_COMPONENT_ALPHA.rawValue)
        static let gray = Components(rawValue: GLIMS_COMPONENT_GRAY.rawValue)
        static let indexed = Components(rawValue: GLIMS_COMPONENT_INDEXED.rawValue)
    }

    enum ComponentMode: UInt32 {
        case rgb = 1, grayscale, indexed
    }

    struct ComponentState: Equatable {
        let mode: ComponentMode
        let supported: Components
        let active: Components
        let visible: Components
    }

    struct Channel: Equatable {
        let id: Int32
        let name: String
        let isVisible: Bool
        let isSelected: Bool
        let isQuickMask: Bool
        /// Overlay opacity; the color's alpha reports the same value.
        let opacity: Double
        let color: NSColor
    }

    struct ChannelChange: Equatable {
        var name: String?
        var isVisible: Bool?
        var opacity: Double?
        /// Includes overlay opacity through alpha. An explicit
        /// `opacity` takes precedence when both fields are supplied.
        var color: NSColor?
    }

    enum ChannelCommand: UInt32 {
        case select = 1, duplicate, delete
    }

    struct QuickMaskState: Equatable {
        let enabled: Bool
        /// A drawable id while enabled; zero otherwise.
        let channel: Int32
        let inverted: Bool
        let color: NSColor
    }

    func components(_ image: Int32) throws -> ComponentState {
        var state = GlimsComponentState()
        try check(api.image_components(engine, image, &state), nil)
        guard let mode = ComponentMode(rawValue: state.mode) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned an unknown image component model.")
        }
        return ComponentState(mode: mode, supported: Components(rawValue: state.supported),
                              active: Components(rawValue: state.active),
                              visible: Components(rawValue: state.visible))
    }

    /// Changes only the named component bits. Changing active
    /// components returns the native paint target from channels to
    /// layers. These display/edit choices carry no undo step.
    func setComponents(_ image: Int32, activeMask: Components = [], activeValues: Components = [],
                       visibleMask: Components = [], visibleValues: Components = []) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_set_components(engine, image, activeMask.rawValue, activeValues.rawValue,
                                            visibleMask.rawValue, visibleValues.rawValue, &error), error)
    }

    func channels(_ image: Int32) throws -> [Channel] {
        var count: Int32 = 0
        try check(api.image_channels(engine, image, nil, 0, &count), nil)
        var rows = [GlimsChannelInfo](repeating: GlimsChannelInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.image_channels(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return rows.prefix(Int(min(count, filled))).map { row in
            Channel(id: row.id, name: Self.string(row.name), isVisible: row.visible,
                    isSelected: row.selected, isQuickMask: row.quick_mask,
                    opacity: row.opacity, color: Self.nsColor(row.color))
        }
    }

    /// Saves the selection as a selected, initially hidden channel.
    @discardableResult
    func channelFromSelection(_ image: Int32, name: String? = nil) throws -> Int32 {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(name) { name in
            try check(api.channel_from_selection(engine, image, name, &result, &error), error)
        }
        return result
    }

    func changeChannel(_ channel: Int32, image: Int32, _ change: ChannelChange) throws {
        var settings = GlimsChannelChange()
        settings.struct_size = UInt32(MemoryLayout<GlimsChannelChange>.size)
        if let name = change.name {
            settings.properties |= GLIMS_CHANNEL_NAME.rawValue
            Self.copy(name, into: &settings.name)
        }
        if let visible = change.isVisible {
            settings.properties |= GLIMS_CHANNEL_VISIBLE.rawValue
            settings.visible = visible
        }
        if let opacity = change.opacity {
            settings.properties |= GLIMS_CHANNEL_OPACITY.rawValue
            settings.opacity = opacity
        }
        if let color = change.color {
            settings.properties |= GLIMS_CHANNEL_COLOR.rawValue
            settings.color = try Self.color(color)
        }
        var error: UnsafeMutablePointer<CChar>?
        try check(api.channel_change(engine, image, channel, &settings, &error), error)
    }

    /// Select with channel zero returns to the selected layers.
    /// Duplicate returns its new channel id; Delete returns nil.
    @discardableResult
    func channelCommand(_ command: ChannelCommand, channel: Int32, image: Int32) throws -> Int32? {
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.channel_command(engine, image, channel, command.rawValue, &result, &error), error)
        return result == 0 ? nil : result
    }

    func channelToSelection(_ channel: Int32, image: Int32, operation: SelectOperation) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.channel_to_selection(engine, image, channel, operation.rawValue, &error), error)
    }

    func quickMask(_ image: Int32) throws -> QuickMaskState {
        var state = GlimsQuickMaskState()
        try check(api.image_quick_mask(engine, image, &state), nil)
        return QuickMaskState(enabled: state.enabled, channel: state.channel,
                              inverted: state.inverted, color: Self.nsColor(state.color))
    }

    func setQuickMask(_ image: Int32, enabled: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_set_quick_mask(engine, image, enabled, &error), error)
    }

    // MARK: Color state and conversions

    /// The image's color model, as `colorInfo` reports it and
    /// `convertMode` takes (GlimsColorMode). Conversion to `.indexed`
    /// goes through `convertToIndexed`, which takes palette and dither
    /// settings; an indexed image's info still reports `.indexed`.
    enum ColorMode: UInt32 {
        case unknown = 0, rgb = 1, grayscale = 2, indexed = 3

        /// The model's name in the window title and menus.
        var title: String {
            switch self {
            case .rgb: return "RGB"
            case .grayscale: return "Grayscale"
            case .indexed: return "Indexed"
            case .unknown: return "Unknown"
            }
        }
    }

    /// The component type of the image's precision (GlimsColorComponent).
    enum ColorComponent: UInt32 {
        case unknown = 0, u8 = 1, u16, u32, half, float, double

        /// The choices the Precision form offers, in display order —
        /// 8/16/32-bit integer, then 16/32/64-bit float.
        static let conversionChoices: [ColorComponent] = [.u8, .u16, .u32, .half, .float, .double]

        var title: String {
            switch self {
            case .u8: return "8-bit integer"
            case .u16: return "16-bit integer"
            case .u32: return "32-bit integer"
            case .half: return "16-bit float"
            case .float: return "32-bit float"
            case .double: return "64-bit float"
            case .unknown: return "Unknown"
            }
        }
    }

    /// The transfer curve of the image's precision (GlimsColorTRC).
    enum ColorTRC: UInt32 {
        case unknown = 0, linear = 1, nonlinear, perceptual

        /// The choices the Precision form offers, in display order.
        static let conversionChoices: [ColorTRC] = [.linear, .nonlinear, .perceptual]

        var title: String {
            switch self {
            case .linear: return "Linear"
            case .nonlinear: return "Non-linear"
            case .perceptual: return "Perceptual"
            case .unknown: return "Unknown"
            }
        }
    }

    /// The image's color state (GlimsColorInfo): `component` and `trc`
    /// together are the precision `ImageInfo.precision` reports as a nick.
    struct ColorInfo: Equatable {
        let mode: ColorMode
        let component: ColorComponent
        let trc: ColorTRC
        /// The effective profile's label — the image's own when it has
        /// one, the engine's builtin fallback otherwise; "" when none.
        let profileLabel: String
        /// Whether an ICC profile travels with the image and its files.
        let hasEmbeddedProfile: Bool
    }

    /// The image's color model, precision and effective profile
    /// (image_color_info). A read; always allowed, also while a stroke,
    /// a preview or a plug-in holds the image.
    func colorInfo(_ image: Int32) throws -> ColorInfo {
        var info = GlimsColorInfo()
        try check(api.image_color_info(engine, image, &info), nil)
        return ColorInfo(mode: ColorMode(rawValue: info.mode) ?? .unknown,
                         component: ColorComponent(rawValue: info.component) ?? .unknown,
                         trc: ColorTRC(rawValue: info.trc) ?? .unknown,
                         profileLabel: Self.string(info.profile_label),
                         hasEmbeddedProfile: info.profile_embedded)
    }

    /// Image ▸ Mode ▸ …: the whole image's color model as one undo
    /// step (image_convert_mode). A no-op changes nothing and pushes no
    /// undo; converting to `.indexed` stays UNSUPPORTED here — use
    /// `convertToIndexed`; BUSY while a stroke, a preview or a plug-in
    /// holds the image.
    func convertMode(_ image: Int32, to mode: ColorMode) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_convert_mode(engine, image, mode.rawValue, &error), error)
    }

    /// Image ▸ Precision…: the image's component type and transfer
    /// curve as one undo step with no dithering
    /// (image_convert_precision). Every component/TRC pair is valid on
    /// RGB and grayscale images; an indexed image accepts only u8
    /// non-linear and answers anything else UNSUPPORTED. Same no-op
    /// and busy rules as `convertMode`.
    func convertPrecision(_ image: Int32, component: ColorComponent, trc: ColorTRC) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_convert_precision(engine, image, component.rawValue, trc.rawValue, &error),
                  error)
    }

    /// A rendering intent for profile conversion (GlimsProfileIntent):
    /// the facade's own values 1–4, never the engine's native enum.
    enum ProfileIntent: UInt32, Codable {
        case perceptual = 1, relativeColorimetric, saturation, absoluteColorimetric

        /// The choices the Convert form offers, in display order.
        static let conversionChoices: [ProfileIntent] = [.perceptual, .relativeColorimetric,
                                                          .saturation, .absoluteColorimetric]

        var title: String {
            switch self {
            case .perceptual: return "Perceptual"
            case .relativeColorimetric: return "Relative Colorimetric"
            case .saturation: return "Saturation"
            case .absoluteColorimetric: return "Absolute Colorimetric"
            }
        }
    }

    /// Ordinary conversion preserves editable layer types. Rasterization
    /// is admitted only after the caller has obtained explicit consent.
    enum ProfileConversionPolicy: Equatable {
        case preserveEditableLayers, rasterizeEditableLayers
    }

    /// Image ▸ Color Profile ▸ Assign…: embed the ICC profile at `path`
    /// without converting pixel component values, or discard the
    /// embedded profile when `path` is nil (image_assign_profile).
    /// One undo group; assigning an equal profile is a no-op. BUSY while
    /// a stroke, a preview or a plug-in holds the image.
    func assignProfile(_ image: Int32, path: String?) throws {
        try Self.validateProfilePathText(path)
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(path) { path in
            try check(api.image_assign_profile(engine, image, path, &error), error)
        }
    }

    /// Image ▸ Color Profile ▸ Convert…: convert pixels to preserve
    /// appearance in the destination ICC profile
    /// (image_convert_profile); a nil `path` chooses the image
    /// model/precision's builtin profile. `intent` and
    /// `blackPointCompensation` apply only to this conversion.
    /// Indexed images answer UNSUPPORTED — their native palette
    /// conversion ignores intent and BPC. Same undo, no-op and busy
    /// rules as `assignProfile`.
    func convertProfile(_ image: Int32, path: String?, intent: ProfileIntent,
                        blackPointCompensation: Bool,
                        policy: ProfileConversionPolicy = .preserveEditableLayers) throws {
        try Self.validateProfilePathText(path)
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(path) { path in
            switch policy {
            case .preserveEditableLayers:
                try check(api.image_convert_profile(engine, image, path, intent.rawValue,
                                                   blackPointCompensation, &error), error)
            case .rasterizeEditableLayers:
                try check(api.image_convert_profile_rasterizing(engine, image, path, intent.rawValue,
                                                               blackPointCompensation, &error), error)
            }
        }
    }

    /// File paths must reach the C facade without CString truncation.
    private static func validateProfilePathText(_ path: String?) throws {
        guard path?.utf8.contains(0) != true else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The profile path contains invalid text.")
        }
    }

    /// The palette an indexed conversion builds (GlimsIndexedPalette):
    /// the facade's own values, never the engine's enum.
    enum IndexedPalette: UInt32 {
        /// Quantize to the image's own colors, at most `maxColors`.
        case generated = 1
        /// The fixed 216-color web palette.
        case web = 2
        /// Black and white.
        case mono = 3
        /// The call's own `customColors` list.
        case custom = 4
    }

    /// How an indexed conversion dithers (GlimsIndexedDither).
    enum IndexedDither: UInt32 {
        case none = 1
        case floydSteinberg = 2
        /// Floyd-Steinberg, reduced color bleeding.
        case floydSteinbergLowBleed = 3
        /// The engine's built-in positioned/ordered matrix.
        case fixed = 4
    }

    /// What `convertToIndexed` does when the image holds a genuine
    /// editable text, vector or link layer the conversion would
    /// rasterize (GlimsIndexedPreservation).
    enum IndexedPreservation: UInt32 {
        /// Refuse; nothing changes.
        case preserveEditable = 1
        /// Rasterize them inside the conversion's one undo step; their
        /// structured sources are retained and restored by undo.
        case allowRasterize = 2
    }

    /// How `convertToIndexed` quantizes (GlimsIndexedSettings).
    /// `maxColors` applies only to `.generated` (2 ... 256).
    /// `removeUnused` drops unused and duplicate colormap entries; the
    /// engine honors it for `.web` and `.custom` and ignores it
    /// otherwise. `ditherText` quantizes text layers' pixels like a
    /// raster layer; with it off a text layer is re-rendered and stays
    /// editable. `customColors` is the `.custom` palette: 1 ... 256
    /// colors; the engine keeps opaque colors only, so non-opaque
    /// entries are refused.
    struct IndexedSettings: Equatable {
        var palette: IndexedPalette = .generated
        var maxColors: Int32 = 256
        var removeUnused = true
        var dither: IndexedDither = .none
        var ditherAlpha = false
        var ditherText = false
        var preservation: IndexedPreservation = .preserveEditable
        var customColors: [NSColor] = []
    }

    /// Converts the whole image to indexed color as exactly one undo
    /// step (image_convert_indexed). An already indexed image is a
    /// no-op. `.preserveEditable` (the default) reports
    /// `EngineError.requiresRasterization` when the image holds a
    /// genuine editable vector or link layer, or a genuine editable
    /// text layer while `ditherText` is on; retry with
    /// `.allowRasterize` after consent. Throws UNSUPPORTED for a
    /// non-8-bit-non-linear precision or a layer stack containing a
    /// group, BUSY while a stroke, a preview or a plug-in holds the
    /// image, and INVALID_ARGUMENT for invalid settings.
    func convertToIndexed(_ image: Int32, settings: IndexedSettings) throws {
        var values = GlimsIndexedSettings(
            struct_size: UInt32(MemoryLayout<GlimsIndexedSettings>.size),
            palette: settings.palette.rawValue,
            max_colors: settings.maxColors,
            remove_unused: settings.removeUnused,
            dither: settings.dither.rawValue,
            dither_alpha: settings.ditherAlpha,
            dither_text: settings.ditherText,
            preservation: settings.preservation.rawValue)
        let colors: [GlimsColor]
        if settings.palette == .custom {
            guard (1...256).contains(settings.customColors.count) else {
                throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                  message: "A custom palette needs from 1 to 256 colors.")
            }
            colors = try settings.customColors.map(Self.color)
        } else {
            colors = []
        }
        var error: UnsafeMutablePointer<CChar>?
        // The buffer covers the complete synchronous C call; an empty
        // list passes a NULL base address, valid for non-custom modes.
        try colors.withUnsafeBufferPointer { buffer in
            try check(api.image_convert_indexed(engine, image, &values,
                                                buffer.baseAddress, Int32(buffer.count), &error),
                      error)
        }
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
        var values = try Self.textSettings(settings)
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
        if var values = try settings.map(Self.textSettings) {
            try check(api.text_layer_set(engine, image, layer, text, &values, &error), error)
        } else {
            try check(api.text_layer_set(engine, image, layer, text, nil, &error), error)
        }
    }

    private static func textSettings(_ settings: TextSettings) throws -> GlimsTextSettings {
        var values = GlimsTextSettings()
        values.struct_size = UInt32(MemoryLayout<GlimsTextSettings>.size)
        copy(settings.font, into: &values.font)
        values.size = settings.size
        values.color = try color(settings.color)
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

    /// How `fillPath` fills a path: a solid color at an opacity, with an
    /// antialiased edge. No pattern and no fill rule of its own.
    struct PathFillSettings: Equatable {
        var color: NSColor = .black
        var opacity: Double = 1
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
                                       width: settings.width, color: try Self.color(settings.color),
                                       antialias: settings.antialias)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.path_stroke(engine, image, path, layer ?? 0, &values, &error), error)
    }

    /// Fills the area `path` encloses on `drawable` — a layer, a layer mask
    /// or a channel of the image (0: the selected drawable) — with a solid
    /// color, as one undo step. The fill stays inside the selection and
    /// honors the drawable's mask and pixel locks; a group or a locked
    /// target is refused. The engine revalidates the path and the target.
    func fillPath(_ path: Int32, image: Int32, drawable: Int32, settings: PathFillSettings) throws {
        var values = GlimsPathFillSettings(struct_size: UInt32(MemoryLayout<GlimsPathFillSettings>.size),
                                           color: try Self.color(settings.color), opacity: settings.opacity,
                                           antialias: settings.antialias)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.path_fill(engine, image, path, drawable, &values, &error), error)
    }

    /// Makes a genuine vector layer from `path`, above the selected layer
    /// and itself selected, as one undo step. `name` (nil: the path's
    /// name) sets the layer's name. Returns the new layer's id. Throws
    /// `EngineError` with `GLIMS_STATUS_UNSUPPORTED` on engines without
    /// vector layers (before GIMP 3.2); the call never degrades to a
    /// raster copy. The layer keeps the same path object, so editing the
    /// path re-renders it.
    func toVectorLayer(_ path: Int32, image: Int32, name: String? = nil) throws -> Int32 {
        var layer: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(name) { name in
            try check(api.path_to_vector_layer(engine, image, path, name, &layer, &error), error)
        }
        return layer
    }

    // MARK: Vector layer style

    /// A vector layer's stroke cap; facade-owned values only
    /// (GlimsVectorCapStyle) — the engine's enum never crosses.
    enum VectorCapStyle: UInt32, CaseIterable, Equatable {
        case butt = 1, round, square

        var name: String {
            switch self {
            case .butt: return "Butt"
            case .round: return "Round"
            case .square: return "Square"
            }
        }
    }

    /// A vector layer's stroke join; facade-owned values only
    /// (GlimsVectorJoinStyle).
    enum VectorJoinStyle: UInt32, CaseIterable, Equatable {
        case miter = 1, round, bevel

        var name: String {
            switch self {
            case .miter: return "Miter"
            case .round: return "Round"
            case .bevel: return "Bevel"
            }
        }
    }

    /// Which fields of a `VectorStyleChange` apply; the bits are the
    /// facade's own (GlimsVectorStyleProperty). A change that flags nothing
    /// alters nothing and pushes no undo.
    struct VectorStyleProperty: OptionSet, Equatable {
        let rawValue: UInt32
        static let enableFill = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_ENABLE_FILL.rawValue)
        static let fillColor = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_FILL_COLOR.rawValue)
        static let fillAntialias = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_FILL_ANTIALIAS.rawValue)
        static let enableStroke = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_ENABLE_STROKE.rawValue)
        static let strokeColor = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_COLOR.rawValue)
        static let strokeAntialias = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS.rawValue)
        static let strokeWidth = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_WIDTH.rawValue)
        static let strokeCap = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_CAP.rawValue)
        static let strokeJoin = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_JOIN.rawValue)
        static let strokeMiter = VectorStyleProperty(rawValue: GLIMS_VECTOR_STYLE_STROKE_MITER.rawValue)
    }

    /// A genuine vector layer's native fill/stroke style, as
    /// `vector_layer_style_get` reports it. Solid paint only: a layer whose
    /// native fill or stroke is a pattern reports UNSUPPORTED instead of
    /// converting it. Opacity, paint mode, unit, dash offset, feather and
    /// stroke method are not persisted by the native format and are not
    /// exposed here. Colors are explicit sRGB; `strokeWidth` is in image
    /// pixels.
    struct VectorStyle: Equatable {
        var fillEnabled: Bool
        var fillColor: NSColor
        var fillAntialias: Bool
        var strokeEnabled: Bool
        var strokeColor: NSColor
        var strokeAntialias: Bool
        var strokeWidth: Double
        var strokeCap: VectorCapStyle
        var strokeJoin: VectorJoinStyle
        var strokeMiterLimit: Double
    }

    /// A requested change; the bits of `properties` say which fields
    /// apply, the rest keep their state — including every option the
    /// facade does not expose.
    struct VectorStyleChange: Equatable {
        var properties: VectorStyleProperty = []
        var fillEnabled = false
        var fillColor: NSColor = .black
        var fillAntialias = true
        var strokeEnabled = false
        var strokeColor: NSColor = .black
        var strokeAntialias = true
        var strokeWidth: Double = 2
        var strokeCap: VectorCapStyle = .butt
        var strokeJoin: VectorJoinStyle = .miter
        var strokeMiterLimit: Double = 4
    }

    /// Reads a genuine vector layer's native style (GIMP 3.2+). This is a
    /// read, always allowed — but it still touches the engine, so callers
    /// off the main thread keep it there. NOT_FOUND for a non-vector
    /// layer, UNSUPPORTED before GIMP 3.2 and for a native pattern style.
    func vectorLayerStyle(_ layer: Int32, image: Int32) throws -> VectorStyle {
        var style = GlimsVectorStyle()
        style.struct_size = UInt32(MemoryLayout<GlimsVectorStyle>.size)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.vector_layer_style_get(engine, image, layer, &style, &error), error)
        return Self.vectorStyle(style)
    }

    /// Applies the flagged fields of `change` to a genuine vector layer as
    /// exactly one native undo step; a change that would alter nothing is
    /// a no-op that pushes no undo. All guards run before any mutation:
    /// BUSY, INVALID_ARGUMENT, NOT_FOUND, LOCKED, UNSUPPORTED (before
    /// GIMP 3.2 or a native pattern style).
    func changeVectorLayerStyle(_ layer: Int32, image: Int32, _ change: VectorStyleChange) throws {
        var values = GlimsVectorStyleChange(
            struct_size: UInt32(MemoryLayout<GlimsVectorStyleChange>.size),
            properties: change.properties.rawValue,
            enable_fill: change.fillEnabled,
            fill_color: try Self.color(change.fillColor),
            fill_antialias: change.fillAntialias,
            enable_stroke: change.strokeEnabled,
            stroke_color: try Self.color(change.strokeColor),
            stroke_antialias: change.strokeAntialias,
            stroke_width: change.strokeWidth,
            stroke_cap: change.strokeCap.rawValue,
            stroke_join: change.strokeJoin.rawValue,
            stroke_miter_limit: change.strokeMiterLimit)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.vector_layer_style_set(engine, image, layer, &values, &error), error)
    }

    private static func vectorStyle(_ style: GlimsVectorStyle) -> VectorStyle {
        VectorStyle(fillEnabled: style.enable_fill,
                    fillColor: nsColor(style.fill_color),
                    fillAntialias: style.fill_antialias,
                    strokeEnabled: style.enable_stroke,
                    strokeColor: nsColor(style.stroke_color),
                    strokeAntialias: style.stroke_antialias,
                    strokeWidth: style.stroke_width,
                    strokeCap: VectorCapStyle(rawValue: style.stroke_cap) ?? .butt,
                    strokeJoin: VectorJoinStyle(rawValue: style.stroke_join) ?? .miter,
                    strokeMiterLimit: style.stroke_miter_limit)
    }

    private func withOptionalCString(_ string: String?,
                                     _ body: (UnsafePointer<CChar>?) throws -> Void) rethrows {
        guard let string else { return try body(nil) }
        try string.withCString { try body($0) }
    }

    private func withOptionalPointer<T, Result>(_ value: T?,
                                                _ body: (UnsafePointer<T>?) throws -> Result) rethrows -> Result {
        guard let value else { return try body(nil) }
        return try withUnsafePointer(to: value) { try body($0) }
    }

    func scaleImage(_ image: Int32, width: Int, height: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_scale(engine, image, Int32(width), Int32(height), &error), error)
    }

    func resizeCanvas(_ image: Int32, width: Int, height: Int, offset: CGPoint, fill: NSColor) throws {
        var color = try Self.color(fill)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_resize_canvas(engine, image, Int32(width), Int32(height),
                                          Int32(offset.x), Int32(offset.y), &color, &error), error)
    }

    private static func color(_ color: NSColor) throws -> GlimsColor {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Choose a solid color that can be converted to sRGB.")
        }
        let components = [Double(rgb.redComponent), Double(rgb.greenComponent),
                          Double(rgb.blueComponent), Double(rgb.alphaComponent)]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Color components must be finite and between 0 and 1.")
        }
        return GlimsColor(red: components[0], green: components[1],
                          blue: components[2], alpha: components[3])
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

    // MARK: Resources

    /// The kind of a brush, pattern or gradient (GlimsResourceKind).
    /// Facade-owned values; the engine's own enum never crosses the boundary.
    enum ResourceKind: UInt32, CaseIterable {
        case brush = 1, pattern = 2, gradient = 3
    }

    /// A handle to one brush, pattern or gradient (GlimsResourceID):
    /// opaque, and local to the current engine session. A number can be
    /// reused after a restart. Persisted selections store
    /// `ResourceIdentity`, never these ids.
    typealias ResourceID = UInt64

    /// One row of the resource catalog (GlimsResourceInfo): the display
    /// name and handle of one brush, pattern or gradient; nothing rendered.
    struct Resource: Equatable {
        let id: ResourceID
        let kind: ResourceKind
        let displayName: String
    }

    /// The persistent identity of a resource: the triplet to store and
    /// later feed to `resolveResource(_:kind:)`. A nil `collection` is a
    /// value of its own, not an empty collection: Codable keeps the NULL
    /// and empty values apart so a persisted selection restores exactly
    /// what was stored.
    struct ResourceIdentity: Equatable, Codable {
        let name: String
        let collection: String?
        let isInternal: Bool

        /// Native resource lookup compares UTF-8 bytes, including normalization.
        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.isInternal == rhs.isInternal, lhs.name.utf8.elementsEqual(rhs.name.utf8) else { return false }
            switch (lhs.collection, rhs.collection) {
            case (nil, nil): return true
            case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
            default: return false
            }
        }
    }

    /// The engine's resources of `kind`, in the engine's own order (sort
    /// in the interface as you like): names and handles only, nothing
    /// rendered. The catalog can list hundreds of rows, so call this when
    /// a chooser opens, never eagerly on the main thread or at startup.
    func resources(_ kind: ResourceKind) throws -> [Resource] {
        var count: Int32 = 0
        try check(api.resources(engine, kind.rawValue, nil, 0, &count), nil)
        var rows = [GlimsResourceInfo](repeating: GlimsResourceInfo(), count: Int(count))
        var filled: Int32 = 0
        while true {
            let capacity = Int32(rows.count)
            filled = 0
            try rows.withUnsafeMutableBufferPointer { buffer in
                try check(api.resources(engine, kind.rawValue, buffer.baseAddress, capacity, &filled), nil)
            }
            // The second count is the total again: one above the buffer
            // means the catalog grew between the calls, so retry at the
            // reported size instead of returning a short list.
            guard filled > capacity else { break }
            rows = [GlimsResourceInfo](repeating: GlimsResourceInfo(), count: Int(filled))
        }
        return try rows.prefix(Int(max(filled, 0))).map { row in
            Resource(id: row.id, kind: try Self.resourceKind(row.kind), displayName: Self.string(row.name))
        }
    }

    /// The persistent identity of the resource `id` names: the triplet to
    /// store and later feed to `resolveResource(_:kind:)`. A nil
    /// `collection` is a value of its own, not an empty collection: pass
    /// back exactly what was received. The identity survives restarting
    /// the engine; nothing else is promised, since moving or renaming the
    /// underlying file changes it.
    func resourceIdentifiers(_ id: ResourceID) throws -> ResourceIdentity {
        var name: UnsafeMutablePointer<CChar>?
        var collection: UnsafeMutablePointer<CChar>?
        var isInternal = false
        var error: UnsafeMutablePointer<CChar>?
        let status = api.resource_identifiers(engine, id, &name, &collection, &isInternal, &error)
        // Own the returned strings until this call finishes, including
        // any error path that supplied them.
        defer {
            api.free_string(name)
            api.free_string(collection)
        }
        try check(status, error)
        guard let rawName = name else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine reported no resource identity.")
        }
        return ResourceIdentity(name: String(cString: rawName),
                                collection: collection.map { String(cString: $0) },
                                isInternal: isInternal)
    }

    /// The handle of the resource of `kind` that `identity` names, as
    /// `resourceIdentifiers(_:)` reported it. The match is exactly the
    /// engine's own: `collection` (nil and "" are distinct) and
    /// `isInternal` must agree, and for non-internal resources the name
    /// too. An internal resource's name is not compared (its display name
    /// is localized), and there is no name-only fallback for the rest.
    /// Throws NOT_FOUND when no resource of `kind` carries the identity.
    func resolveResource(_ identity: ResourceIdentity, kind: ResourceKind) throws -> ResourceID {
        guard !identity.name.utf8.contains(0), identity.collection?.utf8.contains(0) != true else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The resource identity contains invalid text.")
        }
        var handle: ResourceID = 0
        var error: UnsafeMutablePointer<CChar>?
        try withOptionalCString(identity.name) { name in
            try withOptionalCString(identity.collection) { collection in
                try check(api.resource_resolve(engine, kind.rawValue, name, collection,
                                               identity.isInternal, &handle, &error), error)
            }
        }
        return handle
    }

    /// An owned thumbnail of one brush, pattern or gradient: the
    /// straight-alpha 8-bit sRGB RGBA pixels of one `resource_thumbnail`
    /// call, copied out of the native buffer, plus the same pixels as a
    /// CGImage for display.
    struct ResourceThumbnail {
        let width: Int
        let height: Int
        /// Straight-alpha sRGB RGBA, exactly `width * height * 4` bytes.
        let pixels: Data
        /// The same pixels (sRGB, straight alpha, `width * 4` bytes per row).
        let image: CGImage
    }

    /// Renders a fresh thumbnail of the resource `id` names, fitted
    /// inside a `maxSize` x `maxSize` box (1 ... 512): gradients come
    /// back exactly `maxSize` x `max(1, maxSize / 2)`, brushes and
    /// patterns keep their source aspect and are never scaled up. Every
    /// call renders fresh; nothing is cached between calls.
    ///
    /// `foreground` and `background` are optional explicit recolor
    /// inputs: the foreground recolors mask-only brushes, and both feed
    /// gradients with foreground/background segments. Native contexts
    /// use opaque FG/BG, so a color's alpha never makes the preview
    /// transparent — the resource supplies alpha through its brush mask
    /// or transparent gradient stops. Nil uses the engine's canonical
    /// black foreground and white background. The colors apply to this
    /// call only: no user or global context is read or changed, and no
    /// image, catalog or resource is mutated.
    ///
    /// The render runs synchronously on the engine thread, so call this
    /// off the main thread, like `resources(_:)`.
    func resourceThumbnail(_ id: ResourceID, maxSize: Int32 = 32,
                           foreground: NSColor? = nil,
                           background: NSColor? = nil) throws -> ResourceThumbnail {
        var output = GlimsPixelBuffer()
        var error: UnsafeMutablePointer<CChar>?
        // The native buffer is owned from the call on, so it is freed on
        // every path, validation and CGImage-construction failures too.
        defer { api.free_pixels(output.pixels) }
        let foregroundColor = try foreground.map(Self.color)
        let backgroundColor = try background.map(Self.color)
        let status = withOptionalPointer(foregroundColor) { foreground in
            withOptionalPointer(backgroundColor) { background in
                api.resource_thumbnail(engine, id, maxSize, foreground, background, &output, &error)
            }
        }
        try check(status, error)

        let width = Int(output.bounds.width)
        let height = Int(output.bounds.height)
        let (pixelCount, countOverflow) = width.multipliedReportingOverflow(by: height)
        let (expectedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard output.bounds.x == 0, output.bounds.y == 0,
              width > 0, height > 0, width <= Int(maxSize), height <= Int(maxSize),
              !countOverflow, !byteOverflow,
              let nativePixels = output.pixels,
              output.byte_count == expectedBytes else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine returned a malformed resource thumbnail.")
        }
        let pixels = Data(bytes: nativePixels, count: expectedBytes)
        // Straight alpha, like drawableThumbnail: CGImageAlphaInfo.last
        // with an sRGB space and a width * 4 row stride over the copied
        // bytes.
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The resource thumbnail could not be decoded as straight-alpha sRGB.")
        }
        return ResourceThumbnail(width: width, height: height, pixels: pixels, image: image)
    }

    /// The dimension bound of a created resource: the native brush and
    /// pattern maximum, 10000 px in either dimension.
    static let resourceMaxDimension = 10_000
    /// The resource label bound in UTF-8 bytes: the native 256-byte
    /// label including its NUL terminator.
    static let resourceNameMaxUTF8Bytes = 255

    /// Validates one resource label (resource_create_pixels slot 129 and
    /// resource_duplicate slot 131 share this contract): nonempty UTF-8,
    /// no embedded NUL, at most 255 UTF-8 bytes (the native 256-byte label
    /// including its NUL terminator), and no Unicode control characters
    /// (general category Cc, exactly what the native side rejects with
    /// g_unichar_iscntrl). Throws INVALID_ARGUMENT.
    static func validateResourceName(_ name: String) throws {
        let utf8 = Array(name.utf8)
        guard !utf8.isEmpty, !utf8.contains(0), utf8.count <= resourceNameMaxUTF8Bytes else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The resource name must be nonempty UTF-8 without an "
                              + "embedded NUL, at most \(resourceNameMaxUTF8Bytes) bytes.")
        }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The resource name must not contain control characters.")
        }
    }

    /// Validates one resource-creation request (resource_create_pixels,
    /// slot 129) before any bridge allocation or native call, so a
    /// malformed request never reaches the engine: the kind (only brush
    /// and pattern; a gradient is UNSUPPORTED, anything else cannot be
    /// expressed here), the label (validateResourceName), the dimensions
    /// (1 ... 10000 with the exact overflow-checked width * height * 4
    /// byte count) and the brush spacing (1 ... 1000 for a brush, 0 for
    /// a pattern). Throws EngineError with the matching facade status.
    static func validateResourceCreation(kind: ResourceKind, name: String, width: Int, height: Int,
                                         byteCount: Int, brushSpacing: UInt32) throws {
        func invalid(_ message: String) -> EngineError {
            EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: message)
        }
        switch kind {
        case .brush, .pattern:
            break
        case .gradient:
            throw EngineError(status: Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                              message: "Creating a gradient from pixels is not supported.")
        }
        try validateResourceName(name)
        guard width >= 1, height >= 1,
              width <= resourceMaxDimension, height <= resourceMaxDimension else {
            throw invalid("The resource dimensions must be 1 ... \(resourceMaxDimension).")
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (expectedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, expectedBytes == byteCount else {
            throw invalid("The pixel buffer must be exactly width * height * 4 bytes.")
        }
        switch kind {
        case .brush:
            guard brushSpacing >= 1, brushSpacing <= 1000 else {
                throw invalid("The brush spacing must be 1 ... 1000.")
            }
        case .pattern:
            guard brushSpacing == 0 else {
                throw invalid("Patterns take no brush spacing (0).")
            }
        case .gradient:
            break // refused above
        }
    }

    /// Creates one saved bitmap resource from `pixels` and returns its
    /// handle (resource_create_pixels, slot 129): a bitmap brush or a
    /// pattern, saved to the engine's configured writable data folder and
    /// published to the engine's catalog. `pixels` is a ClipboardImage's
    /// owned straight-alpha RGBA buffer, passed only for the duration of
    /// the synchronous engine call — like pastePixels — and every typed
    /// input is validated (validateResourceCreation) before the RPC.
    ///
    /// BUSY while the engine is busy or any stroke or filter session is
    /// active; FAILED when a resource of the same kind already carries
    /// `name` (never silently renamed); UNSUPPORTED for a gradient; the
    /// handle output is zero on every failure. The returned handle works
    /// with resources(_:), resourceIdentifiers(_:), resolveResource(_:kind:),
    /// resourceThumbnail(_:) and the brush/pattern consumers, like any
    /// catalog handle. Call this off the main thread, like the other
    /// catalog work.
    func createResource(kind: ResourceKind, name: String, pixels: ClipboardImage,
                        brushSpacing: UInt32) throws -> ResourceID {
        let byteCount = try ClipboardImage.byteCount(width: pixels.width, height: pixels.height)
        guard pixels.pixels.count == byteCount else {
            throw ClipboardImage.TransferError.invalidImage
        }
        try Self.validateResourceCreation(kind: kind, name: name, width: pixels.width,
                                          height: pixels.height, byteCount: byteCount,
                                          brushSpacing: brushSpacing)
        var handle: ResourceID = 0
        var error: UnsafeMutablePointer<CChar>?
        try pixels.pixels.withUnsafeBytes { bytes in
            try name.withCString { cName in
                try check(api.resource_create_pixels(engine, kind.rawValue, cName,
                                                     Int32(pixels.width), Int32(pixels.height),
                                                     bytes.bindMemory(to: UInt8.self).baseAddress,
                                                     bytes.count, brushSpacing, &handle, &error), error)
            }
        }
        guard handle > 0 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine created no resource handle.")
        }
        return handle
    }

    /// Duplicates the saved resource `id` names as a new saved resource of
    /// the same kind under `name` (resource_duplicate, slot 131) and
    /// returns the new handle, distinct from `id`. The source determines
    /// its own kind — a built-in read-only resource may be duplicated when
    /// the engine supports it. The call takes no image and changes no
    /// image, undo history, selection, context or clipboard, and the
    /// source itself is never renamed, saved, deleted or dirtied.
    ///
    /// `name` is validated (validateResourceName) before the RPC; the
    /// UInt64 handles pass through the bridge unchanged. BUSY while the
    /// engine is busy or any stroke or filter session is active; FAILED
    /// on an exact same-kind name collision (never silently renamed) or a
    /// checked persistence failure; UNSUPPORTED when the engine cannot
    /// duplicate the source's kind; INVALID_ARGUMENT for an invalid name
    /// or a handle of 0 / outside the issued range; NOT_FOUND for a
    /// stale or foreign handle. The returned handle works with
    /// resources(_:), resourceIdentifiers(_:), resolveResource(_:kind:),
    /// resourceThumbnail(_:) and the brush/pattern/gradient consumers.
    /// Call this off the main thread, like the other catalog work.
    func duplicateResource(_ id: ResourceID, name: String) throws -> ResourceID {
        try Self.validateResourceName(name)
        var handle: ResourceID = 0
        var error: UnsafeMutablePointer<CChar>?
        try name.withCString { cName in
            try check(api.resource_duplicate(engine, id, cName, &handle, &error), error)
        }
        guard handle > 0 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine created no resource handle.")
        }
        return handle
    }

    struct ResourceMutationInfo: Equatable, Sendable {
        let flags: UInt32
        let guardToken: String?
        let reason: String?
        var canRename: Bool { flags & UInt32(GLIMS_RESOURCE_CAN_RENAME.rawValue) != 0 && guardToken != nil }
        var canDelete: Bool { flags & UInt32(GLIMS_RESOURCE_CAN_DELETE.rawValue) != 0 && guardToken != nil }
    }

    static func validateResourceGuard(_ token: String) throws {
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Refresh the resource before changing it.")
        }
    }

    /// Owned observed-state values only; query off-main and never persist the guard.
    func resourceMutationInfo(_ id: ResourceID) throws -> ResourceMutationInfo {
        var flags: UInt32 = 0
        var token: UnsafeMutablePointer<CChar>?, reason: UnsafeMutablePointer<CChar>?, error: UnsafeMutablePointer<CChar>?
        let status = api.resource_mutation_info(engine, id, &flags, &token, &reason, &error)
        let observed = Self.takeString(token, api: api)
        let explanation = Self.takeString(reason, api: api)
        try check(status, error)
        guard flags & ~UInt32(3) == 0 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The resource capabilities could not be read.")
        }
        if flags != 0 {
            guard let observed else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The resource file version could not be read.")
            }
            try Self.validateResourceGuard(observed)
        }
        return ResourceMutationInfo(flags: flags, guardToken: observed, reason: explanation)
    }

    func renameResource(_ id: ResourceID, guardToken: String, name: String) throws {
        try Self.validateResourceGuard(guardToken)
        try Self.validateResourceName(name)
        var error: UnsafeMutablePointer<CChar>?
        try guardToken.withCString { guardBytes in
            try name.withCString { nameBytes in
                try check(api.resource_rename(engine, id, guardBytes, nameBytes, &error), error)
            }
        }
    }

    func deleteResource(_ id: ResourceID, guardToken: String) throws {
        try Self.validateResourceGuard(guardToken)
        var error: UnsafeMutablePointer<CChar>?
        try guardToken.withCString { bytes in
            try check(api.resource_delete(engine, id, bytes, &error), error)
        }
    }

    /// One plain sRGB+alpha color value — the facade's GlimsColor contract
    /// (four finite components in 0...1) as an owned value type, independent
    /// of NSColor and AppKit, so gradient endpoints travel as plain data.
    struct RGBAColor: Equatable, Sendable {
        var red, green, blue, alpha: Double
    }

    /// Validates one gradient-creation request (resource_create_gradient,
    /// slot 138) before any native call: the label (validateResourceName)
    /// plus the .ggr edge rule — ASCII whitespace at either name edge is
    /// refused, never silently trimmed, because the native loader strips
    /// it and the name would change identity on reload — and both endpoints
    /// with every component (alpha included) finite and inside 0...1, with
    /// no clamping or normalization. Throws INVALID_ARGUMENT.
    static func validateGradientCreation(name: String, left: RGBAColor, right: RGBAColor) throws {
        func invalid(_ message: String) -> EngineError {
            EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: message)
        }
        try validateResourceName(name)
        let utf8 = Array(name.utf8)
        func asciiSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
        }
        if let first = utf8.first, let last = utf8.last,
           asciiSpace(first) || asciiSpace(last) {
            throw invalid("This resource format cannot preserve spaces at the "
                          + "start or end of its name.")
        }
        for (label, endpoint) in [("left", left), ("right", right)] {
            for (component, value) in [("red", endpoint.red), ("green", endpoint.green),
                                       ("blue", endpoint.blue), ("alpha", endpoint.alpha)] {
                guard value.isFinite, value >= 0, value <= 1 else {
                    throw invalid("The \(label) endpoint's \(component) must be finite "
                                  + "and inside 0...1.")
                }
            }
        }
    }

    /// Creates one saved two-endpoint gradient under `name`
    /// (resource_create_gradient, slot 138) and returns its handle: a
    /// static one-segment gradient whose endpoint colors are exactly
    /// `left` and `right`, saved to the engine's writable data folder and
    /// published to the gradient catalog. The call takes no image and
    /// changes no image, undo history, selection, context or clipboard.
    ///
    /// `name` and both endpoints are validated (validateGradientCreation)
    /// before the RPC; the plain RGBA values are copied into GlimsColor
    /// locals that live for the whole synchronous call, and the UInt64
    /// handle passes through the bridge unchanged. BUSY while the engine
    /// is busy or any stroke or filter session is active; FAILED on an
    /// exact same-kind name collision (never silently renamed) or a
    /// checked persistence failure; the handle output is zero on every
    /// failure. The returned handle works with resources(_:),
    /// resourceIdentifiers(_:), resolveResource(_:kind:),
    /// resourceThumbnail(_:) and the gradient consumers. Call this off
    /// the main thread, like the other catalog work.
    func createGradient(name: String, left: RGBAColor, right: RGBAColor) throws -> ResourceID {
        try Self.validateGradientCreation(name: name, left: left, right: right)
        var leftColor = GlimsColor(red: left.red, green: left.green,
                                   blue: left.blue, alpha: left.alpha)
        var rightColor = GlimsColor(red: right.red, green: right.green,
                                    blue: right.blue, alpha: right.alpha)
        var handle: ResourceID = 0
        var error: UnsafeMutablePointer<CChar>?
        try name.withCString { cName in
            try check(api.resource_create_gradient(engine, cName,
                                                  &leftColor, &rightColor, &handle, &error), error)
        }
        guard handle > 0 else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine created no resource handle.")
        }
        return handle
    }

    /// The facade kind of an engine row; unknown kind values never reach
    /// the interface.
    private static func resourceKind(_ raw: UInt32) throws -> ResourceKind {
        guard let kind = ResourceKind(rawValue: raw) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned an unknown resource kind.")
        }
        return kind
    }

    // MARK: Saved sets (read-only, slots 133/134)

    /// The kind of a saved set (GlimsItemSetKind). Facade-owned values;
    /// the engine's own classes never cross the boundary.
    enum ItemSetKind: UInt32, CaseIterable, Codable {
        case layer = 1, channel, path
    }

    /// One row of `itemSets(_:)` (GlimsItemSetInfo): the set's opaque
    /// identity token, kind, display name and live attached member count.
    /// The token — never the name — is the identity: it stays stable
    /// across quiet live-member rebuilds of the same set, expires when
    /// the set is explicitly removed or replaced through an undoable
    /// edit, and a set recreated under the same name gets a new token.
    /// `displayName` is display-only and may be truncated.
    struct ItemSet: Equatable {
        let token: UInt64
        let kind: ItemSetKind
        let displayName: String
        let memberCount: Int
    }

    /// The image's fixed saved sets (stored item sets), read-only: kinds
    /// in `ItemSetKind` order, the engine's stored-list order within a
    /// kind; pattern definitions are never listed. A plain read, allowed
    /// while the image is busy; it changes nothing.
    func itemSets(_ image: Int32) throws -> [ItemSet] {
        var count: Int32 = 0
        try check(api.image_item_sets(engine, image, nil, 0, &count), nil)
        guard count > 0 else { return [] }
        var rows = [GlimsItemSetInfo](repeating: GlimsItemSetInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.image_item_sets(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return try rows.prefix(Int(min(count, filled))).map { row in
            guard let kind = ItemSetKind(rawValue: row.kind) else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                  message: "The engine returned an unknown saved-set kind.")
            }
            return ItemSet(token: row.token, kind: kind,
                           displayName: Self.string(row.display_name),
                           memberCount: Int(row.member_count))
        }
    }

    /// The current attached member ids of the one saved set that `token`
    /// names in `image`, in stored membership order. Members deleted or
    /// detached from the image are skipped; an empty set returns [].
    /// Throws NOT_FOUND for a token this image does not own — foreign,
    /// stale or expired tokens are never retargeted to a same-named set.
    func itemSetMembers(_ image: Int32, token: UInt64) throws -> [Int32] {
        var count: Int32 = 0
        try check(api.image_item_set_members(engine, image, token, nil, 0, &count), nil)
        guard count > 0 else { return [] }
        var ids = [GlimsItemID](repeating: 0, count: Int(count))
        var filled: Int32 = 0
        try ids.withUnsafeMutableBufferPointer { buffer in
            try check(api.image_item_set_members(engine, image, token, buffer.baseAddress, count, &filled), nil)
        }
        return Array(ids.prefix(Int(min(count, filled))))
    }

    // MARK: Saved sets (edit, slot 135)

    /// One edit operation of `editItemSet(_:)` (GlimsItemSetEditOp).
    enum ItemSetEdit: UInt32 {
        /// Token 0, full new `name`, explicit `members` (empty = empty set).
        case create = 1
        /// Current `token`, explicit `members`, no name.
        case replace
        /// Current `token`, desired full `name`, no members.
        case rename
        /// Current `token`, no name, no members.
        case remove
    }

    /// C strings cannot represent an embedded NUL; reject it before any
    /// bridge allocation or native call can silently shorten the request.
    /// The engine enforces the rest of the full-name contract (nonempty
    /// valid UTF-8, no control characters, at most 255 bytes).
    static func validateItemSetName(_ name: String) throws {
        guard !name.utf8.contains(0) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "A saved-set name cannot contain a NUL character.")
        }
    }

    /// One undoable edit of one of `image`'s fixed saved sets (slot 135),
    /// addressed by the set's current identity token — never by name.
    /// Field relevance is strict, validated here as on the engine: `.create`
    /// needs token 0 and a full new `name`; `.replace` a current token,
    /// explicit `members`, no name; `.rename` a current token and the
    /// desired `name`, no members; `.remove` a current token and neither.
    /// Members are item ids, each positive, attached to `image`, of `kind`,
    /// unique; 0 never means "the current selection". Throws BUSY while a
    /// stroke, filter preview or plug-in holds the image, NOT_FOUND for an
    /// unknown image or a foreign/stale/expired token (never retargeted),
    /// INVALID_ARGUMENT for any malformed field. A successful mutating call
    /// is one native undo step; a no-op (identical members, same name)
    /// changes nothing. Returns the resulting set's token: fresh after
    /// CREATE/REPLACE/RENAME, the current one after a no-op, 0 after REMOVE
    /// and after every failure.
    @discardableResult
    func editItemSet(_ image: Int32, _ operation: ItemSetEdit, kind: ItemSetKind,
                     token: UInt64 = 0, name: String? = nil, members: [Int32] = []) throws -> UInt64 {
        func invalid(_ message: String) -> EngineError {
            EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue), message: message)
        }
        switch operation {
        case .create:
            guard token == 0, let name else {
                throw invalid("CREATE takes token 0 and a full new name.")
            }
            try Self.validateItemSetName(name)
        case .replace:
            guard token != 0, name == nil else {
                throw invalid("REPLACE takes a current token and explicit members only, no name.")
            }
        case .rename:
            guard token != 0, let name, members.isEmpty else {
                throw invalid("RENAME takes a current token and the desired name, no members.")
            }
            try Self.validateItemSetName(name)
        case .remove:
            guard token != 0, name == nil, members.isEmpty else {
                throw invalid("REMOVE takes a current token only, no name and no members.")
            }
        }
        guard members.count <= Int(Int32.max) else {
            throw invalid("The member list is too long for the engine interface.")
        }
        var outToken: UInt64 = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = members.withUnsafeBufferPointer { buffer in
            let memberPointer = buffer.isEmpty ? nil : buffer.baseAddress
            return name?.withCString { cName in
                api.image_item_set_edit(engine, image, operation.rawValue, kind.rawValue,
                                        token, cName, memberPointer, Int32(members.count),
                                        &outToken, &error)
            } ?? api.image_item_set_edit(engine, image, operation.rawValue, kind.rawValue,
                                         token, nil, memberPointer, Int32(members.count),
                                         &outToken, &error)
        }
        try check(status, error)
        return outToken
    }

    // MARK: Guides

    /// Which axis an image guide sits on (GlimsGuideOrientation). A
    /// guide's orientation is fixed at creation; `putGuide` never
    /// reorients an existing guide.
    enum GuideOrientation: UInt32 {
        /// A horizontal line; `position` is a y coordinate.
        case horizontal = 1
        /// A vertical line; `position` is an x coordinate.
        case vertical = 2
    }

    /// One of the image's ordinary guides (GlimsGuideInfo): `position`
    /// is in image pixels on the guide's axis — y for horizontal, x for
    /// vertical — inside 0 ... the image's extent on that axis.
    struct Guide: Equatable {
        let id: Int32
        let orientation: GuideOrientation
        let position: Int32
    }

    /// The image's ordinary guides in the engine's own order
    /// (image_guides). Custom tool-owned guides are never listed.
    func guides(_ image: Int32) throws -> [Guide] {
        var count: Int32 = 0
        try check(api.image_guides(engine, image, nil, 0, &count), nil)
        var rows = [GlimsGuideInfo](repeating: GlimsGuideInfo(), count: Int(count))
        var filled: Int32 = 0
        try rows.withUnsafeMutableBufferPointer { buffer in
            try check(api.image_guides(engine, image, buffer.baseAddress, count, &filled), nil)
        }
        return try rows.prefix(Int(min(count, filled))).map { row in
            guard let orientation = GuideOrientation(rawValue: row.orientation) else {
                throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                  message: "The engine returned a guide with an unknown orientation.")
            }
            return Guide(id: row.id, orientation: orientation, position: row.position)
        }
    }

    /// Adds a guide (`guide.id` 0, returns the new id) or moves the
    /// ordinary guide `guide.id` names to `guide.position` as one undo
    /// step each; `guide.orientation` must then be the guide's own — a
    /// reorienting put is refused. A move to the position the guide
    /// already holds is a no-op with no undo. BUSY while a stroke, a
    /// filter session or a plug-in holds the image.
    @discardableResult
    func putGuide(_ guide: Guide, image: Int32) throws -> Int32 {
        var request = GlimsGuideInfo(id: guide.id, orientation: guide.orientation.rawValue,
                                     position: guide.position)
        var result: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.guide_put(engine, image, &request, &result, &error), error)
        return result
    }

    /// Removes the ordinary guide `guide` names as one undo step;
    /// NOT_FOUND for a stale, foreign or custom tool-owned id.
    func removeGuide(_ guide: Int32, image: Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        try check(api.guide_remove(engine, image, guide, &error), error)
    }

    // MARK: Grid

    /// How the image's display grid renders its lines (GlimsGridStyle).
    /// Facade-owned values; the engine's enum never crosses the boundary.
    enum GridStyle: UInt32, CaseIterable {
        case dots = 1, intersections, onOffDash, doubleDash, solid
    }

    /// The image's display grid (GlimsGrid). Spacings and offsets are in
    /// the grid's own (unexposed) unit — the engine's default on a fresh
    /// image — bounded by the native properties: spacings finite and
    /// > 0 up to the native maximum, offsets inside the native signed
    /// range. The colors are non-linear sRGB, alpha included.
    struct Grid: Equatable {
        var style: GridStyle = .solid
        var spacingX: Double = 10
        var spacingY: Double = 10
        var offsetX: Double = 0
        var offsetY: Double = 0
        var foreground = NSColor.black
        var background = NSColor.white
    }

    /// The image's display grid, read as the current engine state
    /// (image_grid). A plain read: allowed at any time, also while a
    /// stroke, a filter session or a plug-in holds the image; mutates
    /// nothing.
    func grid(_ image: Int32) throws -> Grid {
        var out = GlimsGrid()
        out.struct_size = UInt32(MemoryLayout<GlimsGrid>.size)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_grid(engine, image, &out, &error), error)
        guard let style = GridStyle(rawValue: out.style) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned a grid with an unknown style.")
        }
        return Grid(style: style, spacingX: out.spacing_x, spacingY: out.spacing_y,
                    offsetX: out.offset_x, offsetY: out.offset_y,
                    foreground: Self.nsColor(out.foreground),
                    background: Self.nsColor(out.background))
    }

    /// Applies `grid` to the image (image_set_grid) as exactly one undo
    /// step; an identical grid is a no-op with no undo. All inputs are
    /// validated by the adapter before any mutation: INVALID_ARGUMENT
    /// for an unknown style, a non-finite/zero/negative/over-maximum
    /// spacing, an out-of-range offset or an invalid color; BUSY while
    /// a stroke, a filter session or a plug-in holds the image. Grid
    /// changes are metadata: pixels and the selection are never touched.
    func setGrid(_ grid: Grid, image: Int32) throws {
        var request = GlimsGrid()
        request.struct_size = UInt32(MemoryLayout<GlimsGrid>.size)
        request.style = grid.style.rawValue
        request.spacing_x = grid.spacingX
        request.spacing_y = grid.spacingY
        request.offset_x = grid.offsetX
        request.offset_y = grid.offsetY
        request.foreground = try Self.color(grid.foreground)
        request.background = try Self.color(grid.background)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_set_grid(engine, image, &request, &error), error)
    }

    // MARK: Image metadata

    /// An image-metadata domain (GlimsMetadataDomain). Facade-owned
    /// values; the native domain prefixes never cross the boundary.
    enum MetadataDomain: UInt32, CaseIterable {
        case exif = 1, iptc, xmp
    }

    /// What `editMetadata(_:tag:values:image:)` does to one tag
    /// (GlimsMetadataEdit): `set` replaces the tag's whole value list,
    /// `remove` erases it.
    enum MetadataEdit: UInt32 {
        case set = 1, remove
    }

    /// The tag names present on the image's metadata in `domain`
    /// (image_metadata_tags), in the engine's own order. A plain read:
    /// allowed at any time, also while a stroke, a filter session or a
    /// plug-in holds the image; it never creates metadata. An image with
    /// no metadata in that domain returns an empty array — the facade's
    /// honest empty owned vector, not nil.
    func metadataTags(_ image: Int32, domain: MetadataDomain) throws -> [String] {
        var result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_metadata_tags(engine, image, domain.rawValue, &result, &count, &error), error)
        defer { api.free_metadata_strings(result) }
        return Self.stringVector(result, count: count)
    }

    /// The value list of the single `tag` (image_metadata_values), in
    /// native order with duplicates kept — never flattened. A plain read
    /// with the same rules as `metadataTags`. A registered tag that is
    /// absent returns an empty array; an unregistered tag throws
    /// NOT_FOUND. Language-alternative (XMP LangAlt) tags return the
    /// native labeled fragments, not plain text and not a lossless
    /// language/value structure.
    func metadataValues(_ image: Int32, tag: String) throws -> [String] {
        try Self.validateMetadataStrings(tag: tag, values: [])
        var result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_metadata_values(engine, image, tag, &result, &count, &error), error)
        defer { api.free_metadata_strings(result) }
        return Self.stringVector(result, count: count)
    }

    /// Sets or removes ONE metadata `tag` (image_metadata_edit); there is
    /// no wildcard or group form. `set` replaces the tag's whole value
    /// list and requires at least one value — an empty array is refused,
    /// use `.remove` to erase; `remove` takes no values (pass []).
    /// A success is exactly one undo step; setting the values the tag
    /// already holds, or removing an absent tag, is a no-op with no undo.
    /// BUSY while a stroke, a filter session or a plug-in holds the
    /// image; every refusal leaves the image, its metadata and its
    /// history untouched. UNSUPPORTED for normalization-rewritten tags
    /// (the engine rewrites them from the image's own state on every
    /// metadata change), XMP language alternatives and new XMP
    /// Bag/Seq/Alt containers.
    func editMetadata(_ image: Int32, tag: String, _ operation: MetadataEdit, values: [String] = []) throws {
        try Self.validateMetadataStrings(tag: tag, values: values)
        // The facade takes a NULL-terminated-agnostic `const char *const *`:
        // marshal the Swift strings as C strings for the duration of the
        // synchronous call only; nothing is retained by the engine.
        let cValues: [UnsafePointer<CChar>?] = values.map { string in
            UnsafePointer<CChar>?(strdup(string))
        }
        defer { cValues.forEach { pointer in
            if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
        } }
        var error: UnsafeMutablePointer<CChar>?
        try cValues.withUnsafeBufferPointer { buffer in
            // An empty list passes a NULL vector, not an empty buffer:
            // REMOVE requires NULL with count 0, SET refuses count 0.
            let base = buffer.isEmpty ? nil : buffer.baseAddress
            try check(api.image_metadata_edit(engine, image, tag, operation.rawValue,
                                             base, Int32(buffer.count), &error), error)
        }
    }

    /// Captured ordered layer objects, duplicated as one native Undo group.
    /// An unexpected native insertion failure may leave copies; document
    /// callers must refresh their state even when this method throws.
    func duplicateLayers(_ image: Int32, layers: [Int32]) throws -> [Int32] {
        guard (1...256).contains(layers.count), layers.allSatisfy({ $0 > 0 }),
              Set(layers).count == layers.count else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Select between 1 and 256 different layers to duplicate.")
        }
        var copies = [Int32](repeating: 0, count: layers.count)
        var error: UnsafeMutablePointer<CChar>?
        let status = layers.withUnsafeBufferPointer { input in
            copies.withUnsafeMutableBufferPointer { output in
                api.image_duplicate_layers(engine, image, input.baseAddress, Int32(input.count), output.baseAddress, &error)
            }
        }
        try check(status, error)
        guard copies.allSatisfy({ $0 > 0 }), Set(copies).count == copies.count else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine returned an incomplete layer-copy list. Refresh the image before continuing.")
        }
        return copies
    }

    /// Delete captured ordinary pixel layers as one native Undo operation.
    func deleteLayers(_ image: Int32, layers: [Int32]) throws {
        guard (1...256).contains(layers.count), layers.allSatisfy({ $0 > 0 }),
              Set(layers).count == layers.count else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Select between 1 and 256 different layers to delete.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let status = layers.withUnsafeBufferPointer { input in
            api.image_delete_layers(engine, image, input.baseAddress, Int32(input.count), &error)
        }
        try check(status, error)
    }

    /// Resize the complete captured vector as one native Undo operation.
    func fitLayersToImage(_ image: Int32, layers: [Int32]) throws {
        guard (1...256).contains(layers.count), layers.allSatisfy({ $0 > 0 }),
              Set(layers).count == layers.count else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Select between 1 and 256 different layers to resize.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let status = layers.withUnsafeBufferPointer { input in
            api.image_fit_layers_to_image(engine, image, input.baseAddress, Int32(input.count), &error)
        }
        try check(status, error)
    }

    /// Changes ONE existing language key of a registered XMP LangAlt
    /// root property `tag` (image_metadata_edit_language): the key must
    /// already exist in the map under the exact `language` spelling
    /// reported by `metadataLanguages`, and `language`/`text` must be
    /// nonempty. Embedded NULs are rejected before any bridge allocation
    /// or native call can silently shorten the request.
    /// A success is exactly one undo step; an exact no-op (the key already
    /// holds `text`) is a no-op with no undo and no readiness gate. BUSY
    /// while a stroke, a filter session or a plug-in holds the image for a
    /// changed edit; every refusal leaves the image, its metadata and its
    /// history untouched.
    func editMetadataLanguage(_ image: Int32, tag: String, language: String, text: String) throws {
        try Self.validateMetadataStrings(tag: tag, values: [language, text])
        guard !language.isEmpty, !text.isEmpty else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "A language-alternative language and text must be nonempty strings.")
        }
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_metadata_edit_language(engine, image, tag, language, text, &error), error)
    }

    /// The facade's own value kind of a metadata tag
    /// (GlimsMetadataValueKind): how many values the tag holds natively.
    /// The native type names never cross the boundary as enums.
    enum MetadataValueKind: UInt32, CaseIterable {
        case single = 1, repeatable, bag, seq, alt, langAlt
    }

    /// The type/format policy bits of a tag descriptor
    /// (GlimsMetadataFormatPolicy). They say only whether the tag's type
    /// and format admit a SET or a REMOVE at all — an actual
    /// `editMetadata` can still refuse (BUSY, copy preservation, native
    /// validation), so a set bit never promises a write succeeds.
    struct MetadataFormatPolicy: OptionSet {
        let rawValue: UInt32
        static let supportsSet = MetadataFormatPolicy(rawValue: GLIMS_METADATA_FORMAT_SUPPORTS_SET.rawValue)
        static let supportsRemove = MetadataFormatPolicy(rawValue: GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE.rawValue)
    }

    /// A read-only descriptor of one registered metadata tag, decoded
    /// from `GlimsMetadataTagInfo` (slot 128). The bounded strings are
    /// already valid UTF-8 and NUL-terminated by the adapter.
    struct MetadataTagInfo: Equatable {
        var present: Bool
        var supportsMultiple: Bool
        var valueKind: MetadataValueKind
        var formatPolicy: MetadataFormatPolicy
        var label: String
        var description: String
        var typeName: String
    }

    /// The read-only descriptor of the single `tag`
    /// (image_metadata_tag_info, slot 128): presence on the image,
    /// native multiple-value support, the facade value kind, the
    /// type/format policy bits and the bounded native label, description
    /// and type name. A plain read with the same rules as
    /// `metadataValues`: allowed at any time, also while a stroke, a
    /// filter session or a plug-in holds the image; it never creates
    /// metadata and never mutates the image or its history.
    /// INVALID_ARGUMENT for a malformed tag (embedded NULs are rejected
    /// here, like every metadata input) or an undersized out struct;
    /// NOT_FOUND for an unknown image or an unregistered tag.
    func metadataTagInfo(_ image: Int32, tag: String) throws -> MetadataTagInfo {
        try Self.validateMetadataStrings(tag: tag, values: [])
        var out = GlimsMetadataTagInfo()
        out.struct_size = UInt32(MemoryLayout<GlimsMetadataTagInfo>.size)
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_metadata_tag_info(engine, image, tag, &out, &error), error)
        return try Self.decodeMetadataTagInfo(from: out)
    }

    /// Decodes a facade `GlimsMetadataTagInfo`. An unknown value kind
    /// throws — it is never coerced to an unrelated kind.
    static func decodeMetadataTagInfo(from out: GlimsMetadataTagInfo) throws -> MetadataTagInfo {
        guard let valueKind = MetadataValueKind(rawValue: out.value_kind) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "The engine returned a metadata value kind this build does not know.")
        }
        return MetadataTagInfo(present: out.present,
                               supportsMultiple: out.supports_multiple,
                               valueKind: valueKind,
                               formatPolicy: MetadataFormatPolicy(rawValue: out.format_policy),
                               label: Self.string(out.label),
                               description: Self.string(out.description),
                               typeName: Self.string(out.type_name))
    }

    /// One owned (language, text) pair of an image's language-alternative
    /// (XMP LangAlt) map (image_metadata_languages, slot 139). The
    /// language spelling is preserved exactly; the text is the exact
    /// rdf:li content, no trimming.
    struct MetadataLanguageValue: Equatable, Sendable {
        let language: String
        let text: String
    }

    /// The image's registered XMP LangAlt root property `tag`
    /// (image_metadata_languages, slot 139): the map's owned
    /// (language, text) pairs, in the engine's own map order. A plain
    /// read: allowed at any time, also while a stroke, a filter session
    /// or a plug-in holds the image; it never creates metadata and never
    /// mutates the image or its history. An image with no metadata, an
    /// absent root or an unregistered tag throws NOT_FOUND; a wrong kind
    /// or an unsupported representation throws UNSUPPORTED; a malformed
    /// tag throws INVALID_ARGUMENT. The result count is validated to
    /// 1...256 and every pair's UTF-8 and non-empty language/text are
    /// checked before the array is published; a bad result throws FAILED,
    /// never truncated. Call it off the main thread like other reads.
    func metadataLanguages(_ image: Int32, tag: String) throws -> [MetadataLanguageValue] {
        try Self.validateMetadataStrings(tag: tag, values: [])
        guard !tag.isEmpty else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "A metadata tag must be a nonempty string.")
        }
        var values: UnsafeMutablePointer<GlimsMetadataLanguageValue>?
        var count: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        try check(api.image_metadata_languages(engine, image, tag, &values, &count, &error), error)
        defer { api.metadata_languages_free(values) }
        return try Self.decodeMetadataLanguages(values, count: count)
    }

    /// Decodes the facade's owned language-alternative array: the count
    /// must be 1...256, the pointer non-NULL, and every pair a non-NULL
    /// valid-UTF-8 non-empty language and text with no embedded NUL. A
    /// bad result throws FAILED; it is never truncated or partially
    /// published.
    static func decodeMetadataLanguages(_ values: UnsafeMutablePointer<GlimsMetadataLanguageValue>?,
                                        count: Int32) throws -> [MetadataLanguageValue] {
        guard count >= 1, count <= 256, let values else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine returned an invalid language-alternative count.")
        }
        var result: [MetadataLanguageValue] = []
        result.reserveCapacity(Int(count))
        var languages = Set<String>()
        for index in 0..<Int(count) {
            let pair = values[index]
            guard let cLanguage = pair.language, let cText = pair.text,
                  let language = String(validatingCString: cLanguage),
                  let text = String(validatingCString: cText),
                  !language.isEmpty, !text.isEmpty,
                  languages.insert(language.lowercased()).inserted,
                  language.utf8.count == strlen(cLanguage),
                  text.utf8.count == strlen(cText) else {
                throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                  message: "The engine returned an invalid language-alternative pair.")
            }
            result.append(MetadataLanguageValue(language: language, text: text))
        }
        guard values[Int(count)].language == nil, values[Int(count)].text == nil else {
            throw EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                              message: "The engine returned an invalid language-alternative terminator.")
        }
        return result
    }

    /// C strings cannot represent embedded NULs; reject them before any
    /// bridge allocation or native call can silently shorten the request.
    static func validateMetadataStrings(tag: String, values: [String]) throws {
        guard !tag.utf8.contains(0), !values.contains(where: { $0.utf8.contains(0) }),
              values.count <= Int(Int32.max) else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Metadata tags and values cannot contain a NUL character, and the value count must fit the engine interface.")
        }
    }

    // MARK: Helpers

    /// Decodes one of the facade's owned NULL-terminated string vectors
    /// (`count` entries plus terminator) into a Swift array. The vector
    /// stays owned by the caller and is released with
    /// `free_metadata_strings`; nil decodes as empty.
    static func stringVector(_ vector: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
                             count: Int32) -> [String] {
        guard let vector, count > 0 else { return [] }
        var strings: [String] = []
        strings.reserveCapacity(Int(count))
        var entry = vector
        for _ in 0..<count {
            guard let cString = entry.pointee else { break }
            strings.append(String(cString: cString))
            entry += 1
        }
        return strings
    }

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
        case GLIMS_STATUS_LOCKED: return "Unlock the layer or its group before editing it."
        case GLIMS_STATUS_UNSUPPORTED: return "The engine version cannot do this."
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

    /// A Brush's captured settings as the facade's GlimsBrushSettings:
    /// nil option numbers become -1 (the engine's default for that tool).
    private static func nativeBrush(_ brush: Brush) -> GlimsBrushSettings {
        GlimsBrushSettings(struct_size: UInt32(MemoryLayout<GlimsBrushSettings>.size),
                           size: brush.size, opacity: brush.opacity,
                           red: brush.red, green: brush.green, blue: brush.blue,
                           pressure_size: brush.pressureSize,
                           tool: brush.tool.rawValue,
                           hardness: brush.hardness ?? -1, rate: brush.rate ?? -1,
                           flow: brush.flow ?? -1, exposure: brush.exposure ?? -1,
                           tones: brush.tones.rawValue, anti_erase: brush.antiErase,
                           source_drawable: brush.source?.drawable ?? 0,
                           source_x: brush.source?.x ?? 0, source_y: brush.source?.y ?? 0)
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
    case UInt32(GLIMS_EVENT_CHANNELS_CHANGED.rawValue):
        relay.deliver(.channelsChanged(image: event.image))
    case UInt32(GLIMS_EVENT_GUIDES.rawValue):
        relay.deliver(.guidesChanged(image: event.image))
    case UInt32(GLIMS_EVENT_PROGRESS.rawValue):
        let text = event.text.map { String(cString: $0) } ?? ""
        relay.deliver(.progress(event.active
            ? EngineSession.Progress(fraction: event.value < 0 ? nil : event.value, text: text)
            : nil))
    default:
        break
    }
}
