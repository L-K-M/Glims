import Foundation

@MainActor
enum ResourceCatalogChanges {
    struct Change {
        let kind: EngineSession.ResourceKind
        let oldIdentity: EngineSession.ResourceIdentity
        let newIdentity: EngineSession.ResourceIdentity?
    }
    private final class Observer {
        weak var owner: AnyObject?
        let receive: (Change) -> Void
        init(owner: AnyObject, receive: @escaping (Change) -> Void) { self.owner = owner; self.receive = receive }
    }
    private static var observers: [Observer] = []
    static func observe(owner: AnyObject, receive: @escaping (Change) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, receive: receive))
    }
    static func publish(_ change: Change) {
        observers.removeAll { $0.owner == nil }
        for observer in observers where observer.owner != nil { observer.receive(change) }
    }
}

@MainActor
enum ResourceReferenceMigration {
    /// Called by the counted document completion, independently of form lifetime.
    static func renamed(source: ResourceDuplicateValidation.Source,
                        identity: EngineSession.ResourceIdentity,
                        tools: ToolState = .shared,
                        patterns: PatternFillStore = .shared,
                        presets: PaintToolPresetStore = .shared) -> String? {
        guard source.identity != identity else { return nil }
        var failures: [String] = []
        if source.kind == .brush {
            do { _ = try presets.migrateBrushResource(from: source.identity, to: identity) }
            catch { failures.append("Saved presets could not be updated: \(error)") }
        }
        do {
            switch source.kind {
            case .brush, .gradient: try tools.migrateResourceIdentity(kind: source.kind, from: source.identity, to: identity)
            case .pattern: _ = try patterns.migrateIdentity(from: source.identity, to: identity)
            }
        } catch { failures.append("Saved resource choices could not be updated: \(error)") }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
