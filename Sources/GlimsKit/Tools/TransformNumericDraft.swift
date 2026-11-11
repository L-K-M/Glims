import CoreGraphics

/// A numeric draft belongs to one document/layer and one transform lifetime.
/// Ending a field edit or retargeting the palette never transfers that draft.
struct TransformNumericTarget: Equatable {
    let document: ObjectIdentifier
    let layer: Int32
    let original: CGRect
    let generation: UInt64
    let routeRevision: [Int]

    init(document: ObjectIdentifier, layer: Int32, original: CGRect, generation: UInt64,
         routeRevision: [Int] = []) {
        self.document = document
        self.layer = layer
        self.original = original
        self.generation = generation
        self.routeRevision = routeRevision
    }
}

struct TransformNumericDraft {
    private(set) var text: String
    private var committedText: String
    private(set) var target: TransformNumericTarget?
    private(set) var error: String?

    init(text: String) {
        self.text = text
        committedText = text
    }

    var hasDraft: Bool { text != committedText || error != nil }

    mutating func begin(target: TransformNumericTarget?) {
        if !hasDraft { self.target = target }
    }

    mutating func update(_ text: String) { self.text = text }

    func canCommit(to current: TransformNumericTarget?) -> Bool {
        target != nil && target == current
    }

    mutating func reject(_ message: String) { error = message }

    mutating func accept(text: String, target: TransformNumericTarget?) {
        self.text = text
        committedText = text
        self.target = target
        error = nil
    }

    mutating func cancel(text: String) { accept(text: text, target: nil) }

    mutating func refresh(_ text: String, target: TransformNumericTarget?, editing: Bool) {
        guard !hasDraft, !editing || self.target == target else { return }
        self.text = text
        committedText = text
        if !editing { self.target = nil }
    }
}
