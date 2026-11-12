import Foundation

/// GIMP's file and plug-in calls hold the single engine across images.
/// Admit them on the main actor: finish gestures, stop accepting edits,
/// then drain every document's accepted input before entering the engine.
@MainActor
final class EngineActivity {
    static let shared = EngineActivity()

    private final class DocumentReference {
        weak var value: ImageDocument?
        init(_ value: ImageDocument) { self.value = value }
    }

    private var documents: [DocumentReference] = []
    private let queue = DispatchQueue(label: "ch.lkmc.Glims.engine.activity", qos: .userInitiated)
    private var preparing = false
    private var idleActions: [@MainActor () -> Void] = []
    private var transformPreviewReads = 0
    private var afterTransformPreview: [@MainActor () -> Void] = []
    var isRenderingTransformPreview: Bool { transformPreviewReads != 0 }
    private(set) var label: String?
    private(set) weak var progressDocument: ImageDocument?
    var isBusy: Bool { label != nil }

    private var liveDocuments: [ImageDocument] {
        documents.removeAll { $0.value == nil }
        return documents.compactMap(\.value)
    }

    func register(_ document: ImageDocument) {
        guard !liveDocuments.contains(where: { $0 === document }) else { return }
        documents.append(DocumentReference(document))
    }

    func finishPendingInput() {
        liveDocuments.filter { !$0.isClosing }.forEach { $0.finishInputForEngineActivity() }
    }

    /// Background file work may queue behind another operation; the UI's
    /// accepted open requests and their lifecycle counts remain intact.
    func performWhenReady(label: String, work: @escaping () -> Void,
                          completion: @escaping @MainActor () -> Void = {}) {
        // A delegate may request more exclusive work while input is
        // being flushed. Queue that request without delaying the edits
        // emitted by the delegate itself.
        if preparing {
            idleActions.append { self.performWhenReady(label: label, work: work, completion: completion) }
            return
        }
        guard perform(label: label, work: work, completion: completion) else {
            whenIdle { self.performWhenReady(label: label, work: work, completion: completion) }
            return
        }
    }

    @discardableResult
    func perform(label: String, document: ImageDocument? = nil,
                 didAdmit: (@MainActor () -> Void)? = nil, work: @escaping () -> Void,
                 completion: @escaping @MainActor () -> Void) -> Bool {
        guard !isBusy, !preparing else { return false }
        preparing = true
        finishPendingInput()
        preparing = false
        self.label = label
        progressDocument = document
        // Reserve accepted command state before busy observers can stop or
        // restart recording. This hook must not notify observers itself.
        didAdmit?()
        let admittedDocuments = liveDocuments
        admittedDocuments.forEach { $0.onStateChange?() }
        let drained = DispatchGroup()
        for document in admittedDocuments {
            drained.enter()
            document.inputQueue.async { drained.leave() }
        }
        queue.async {
            drained.wait()
            work()
            DispatchQueue.main.async {
                self.label = nil
                self.progressDocument = nil
                // Dispatch cleanup first. If completion starts a new
                // activity, its barriers then include that cleanup.
                let actions = self.idleActions
                self.idleActions.removeAll()
                actions.forEach { self.whenIdle($0) }
                completion()
                self.liveDocuments.forEach { $0.onStateChange?() }
            }
        }
        return true
    }

    /// Cleanup (preview cancellation and image destruction) must wait
    /// for the engine, even though new user edits are refused meanwhile.
    func whenIdle(_ action: @escaping @MainActor () -> Void) {
        if isBusy { idleActions.append(action) } else { action() }
    }

    /// Rendering a private copy does not lock edits or finish the live
    /// gesture. Synchronous UI reads must nevertheless wait off the main
    /// thread's call stack until that copy has left the single native engine.
    func beginTransformPreview() { transformPreviewReads += 1 }

    func endTransformPreview() {
        precondition(transformPreviewReads > 0)
        transformPreviewReads -= 1
        guard transformPreviewReads == 0 else { return }
        let actions = afterTransformPreview
        afterTransformPreview.removeAll()
        actions.forEach { whenReadyForSynchronousRead($0) }
    }

    func whenReadyForSynchronousRead(_ action: @escaping @MainActor () -> Void) {
        whenIdle {
            if self.isRenderingTransformPreview { self.afterTransformPreview.append(action) }
            else { action() }
        }
    }

    /// Destruction follows file calls on the same queue. It needs no new
    /// edit gate once this image has drained; input in other images may
    /// continue. A later file call cannot overtake this cleanup.
    func closeImage(_ image: Int32, session: EngineSession,
                    completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try session.closeImage(image) }
            DispatchQueue.main.async {
                if case .failure(let error) = result,
                   (error as? EngineSession.EngineError)?.isBusy == true {
                    // A native link monitor can reload without an app job.
                    // Keep the session/image alive and leave the queue free
                    // for cancellation while that loader unwinds.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.closeImage(image, session: session, completion: completion)
                    }
                } else {
                    completion(result)
                }
            }
        }
    }

    /// Snapshot cleanup stays off the main thread and retries only native BUSY.
    /// An accepted Apply may already have consumed this exact token.
    func endInkSnapshot(_ token: UInt64, image: Int32, session: EngineSession,
                        kind: InkAdjustmentKind = .levels,
                        completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try kind.end(session, image: image, token: token) }
            DispatchQueue.main.async {
                if case .failure(let error) = result,
                   let native = error as? EngineSession.EngineError {
                    if native.isBusy {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.endInkSnapshot(token, image: image, session: session, kind: kind, completion: completion)
                        }
                        return
                    }
                    if native.isNotFound { completion(.success(())); return }
                }
                completion(result)
            }
        }
    }
}
