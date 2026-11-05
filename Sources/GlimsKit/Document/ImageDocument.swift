import CoreGraphics
import Foundation

/// One open image in the engine, as the interface sees it.
///
/// The document keeps the state the interface shows (size, layers, undo)
/// and routes work to the engine off the main thread: pointer input and
/// filter edits go through one serial queue so they reach the engine in
/// order, and long operations (export, save) run on their own queue so they
/// never sit in front of painting.
@MainActor
final class ImageDocument {
    let session: EngineSession
    let image: Int32
    let name: String

    private(set) var info: EngineSession.ImageInfo
    private(set) var layers: [EngineSession.Layer] = []
    private(set) var undoInfo = EngineSession.UndoInfo(undoCount: 0, redoCount: 0, nextUndo: "", nextRedo: "")

    /// The layer painting and filters apply to.
    private(set) var activeLayer: Int32?
    var brush = EngineSession.Brush()

    /// Called after layers or undo state changed.
    var onStateChange: (() -> Void)?
    /// Called with the changed area in image pixels.
    var onProjectionChange: ((CGRect) -> Void)?
    /// Called with engine errors that the interface should show.
    var onError: ((String) -> Void)?

    nonisolated let inputQueue = DispatchQueue(label: "ch.lkmc.Glims.document.input", qos: .userInteractive)
    nonisolated let longQueue = DispatchQueue(label: "ch.lkmc.Glims.document.long", qos: .userInitiated)

    /// Touched only on `inputQueue`.
    private nonisolated(unsafe) var currentStroke: Int32?

    init(session: EngineSession, image: Int32, name: String) throws {
        self.session = session
        self.image = image
        self.name = name
        self.info = try session.info(image)
        try reload()
    }

    /// Re-reads layers, undo state and size from the engine.
    func reload() throws {
        info = try session.info(image)
        layers = try session.layers(image)
        undoInfo = try session.undoInfo(image)
        if activeLayer == nil || !layers.contains(where: { $0.id == activeLayer }) {
            activeLayer = layers.first(where: { $0.isSelected && $0.kind != .group })?.id
                ?? layers.first(where: { $0.kind != .group })?.id
        }
        onStateChange?()
    }

    func selectLayer(_ id: Int32) {
        guard layers.contains(where: { $0.id == id && $0.kind != .group }) else { return }
        activeLayer = id
        onStateChange?()
    }

    func handle(_ event: EngineSession.Event) {
        switch event {
        case .projectionChanged(let image, let rect) where image == self.image:
            onProjectionChange?(rect)
        case .layersChanged(let image) where image == self.image,
             .undoChanged(let image) where image == self.image:
            try? reload()
        default:
            break
        }
    }

    // MARK: Painting

    func beginStroke(at point: EngineSession.StrokePoint) {
        guard let layer = activeLayer else { return }
        let brush = self.brush
        inputQueue.async { [session, image] in
            do {
                self.currentStroke = try session.beginStroke(image: image, layer: layer, brush: brush, first: point)
            } catch {
                self.currentStroke = nil
                self.report(error)
            }
        }
    }

    func continueStroke(_ points: [EngineSession.StrokePoint]) {
        inputQueue.async { [session] in
            guard let stroke = self.currentStroke else { return }
            do { try session.continueStroke(stroke, points: points) } catch { self.report(error) }
        }
    }

    func endStroke() {
        inputQueue.async { [session] in
            guard let stroke = self.currentStroke else { return }
            self.currentStroke = nil
            do { try session.endStroke(stroke) } catch { self.report(error) }
        }
    }

    // MARK: Undo

    func undo() { run { session, image in try session.undo(image) } }
    func redo() { run { session, image in try session.redo(image) } }

    // MARK: Files

    func export(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        longQueue.async { [session, image] in
            let result: Error?
            do { try session.export(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func save(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        longQueue.async { [session, image] in
            let result: Error?
            do { try session.save(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Helpers

    /// Runs engine work on the input queue, after any pending pointer input.
    func run(_ work: @escaping (EngineSession, Int32) throws -> Void) {
        inputQueue.async { [session, image] in
            do { try work(session, image) } catch { self.report(error) }
        }
    }

    private nonisolated func report(_ error: Error) {
        let message = String(describing: error)
        DispatchQueue.main.async { self.onError?(message) }
    }
}
