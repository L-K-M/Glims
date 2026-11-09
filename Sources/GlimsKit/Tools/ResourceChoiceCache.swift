import CoreGraphics

/// Presentation data belongs to an exact persistent choice. A delayed
/// preview or missing-resource result must never describe a newer choice.
/// Keyed by whatever identifies the choice's owner (a `ToolID` for
/// brushes, the resource kind for the global gradient).
struct ResourceChoiceCache<Key: Hashable> {
    private struct Preview {
        let identity: EngineSession.ResourceIdentity
        let image: CGImage
    }
    private var previews: [Key: Preview] = [:]
    private var missing: [Key: EngineSession.ResourceIdentity] = [:]

    mutating func setPreview(_ image: CGImage?, identity: EngineSession.ResourceIdentity?, for key: Key) {
        if let image, let identity {
            previews[key] = Preview(identity: identity, image: image)
        } else {
            previews[key] = nil
        }
    }

    mutating func setMissing(_ identity: EngineSession.ResourceIdentity?, for key: Key) {
        missing[key] = identity
    }

    func preview(for key: Key, choice: EngineSession.ResourceIdentity?) -> CGImage? {
        guard let choice, previews[key]?.identity == choice else { return nil }
        return previews[key]?.image
    }

    func missingIdentity(for key: Key, choice: EngineSession.ResourceIdentity?) -> EngineSession.ResourceIdentity? {
        guard let choice, missing[key] == choice else { return nil }
        return choice
    }

    mutating func reset(_ key: Key) {
        previews[key] = nil
        missing[key] = nil
    }

    /// A catalog mutation invalidates presentation only, never the saved choice.
    mutating func invalidate(identity: EngineSession.ResourceIdentity) {
        for key in Array(previews.keys) where previews[key]?.identity == identity { previews[key] = nil }
        for key in Array(missing.keys) where missing[key] == identity { missing[key] = nil }
    }
}

/// The brush chooser's per-tool presentation cache.
typealias BrushChoiceCache = ResourceChoiceCache<ToolID>
