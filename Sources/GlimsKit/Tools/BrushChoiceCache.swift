import CoreGraphics

/// Presentation data belongs to an exact persistent choice. A delayed
/// preview or missing-resource result must never describe a newer choice.
struct BrushChoiceCache {
    private struct Preview {
        let identity: EngineSession.ResourceIdentity
        let image: CGImage
    }
    private var previews: [ToolID: Preview] = [:]
    private var missing: [ToolID: EngineSession.ResourceIdentity] = [:]

    mutating func setPreview(_ image: CGImage?, identity: EngineSession.ResourceIdentity?, for tool: ToolID) {
        if let image, let identity {
            previews[tool] = Preview(identity: identity, image: image)
        } else {
            previews[tool] = nil
        }
    }

    mutating func setMissing(_ identity: EngineSession.ResourceIdentity?, for tool: ToolID) {
        missing[tool] = identity
    }

    func preview(for tool: ToolID, choice: EngineSession.ResourceIdentity?) -> CGImage? {
        guard let choice, previews[tool]?.identity == choice else { return nil }
        return previews[tool]?.image
    }

    func missingIdentity(for tool: ToolID, choice: EngineSession.ResourceIdentity?) -> EngineSession.ResourceIdentity? {
        guard let choice, missing[tool] == choice else { return nil }
        return choice
    }

    mutating func reset(_ tool: ToolID) {
        previews[tool] = nil
        missing[tool] = nil
    }
}
