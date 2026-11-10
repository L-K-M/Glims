/// Pure value state for spring-loaded tool letter keys: decides temporary
/// ownership and restoration from literal timestamps and selection revisions.
/// Callers perform the actual selection and restoration; this type never
/// touches ToolState, AppKit, events, windows, the engine or persistence.
struct SpringToolLettersState {
    static let holdThreshold = 0.3

    private struct Hold {
        let keyCode: Int
        let time: Double
        let selected: ToolID
        let selectedRevision: UInt64
        let previous: ToolID
        let previousRevision: UInt64
        var used = false
        var deferredRestore = false
    }

    private var holds: [Int: Hold] = [:]
    private var ownerKey: Int?
    private var pointerActive = false
    /// Captured when input is accepted, independently of later selection
    /// ownership. Explicit tool picks invalidate restoration, not cleanup.
    private(set) var ownsInteraction = false

    func canPress(keyCode: Int, isRepeat: Bool) -> Bool {
        !isRepeat && holds[keyCode] == nil
    }

    func isHeld(keyCode: Int) -> Bool {
        holds[keyCode] != nil
    }

    mutating func press(keyCode: Int, at time: Double, previous: ToolID, previousRevision: UInt64,
                        selected: ToolID, selectedRevision: UInt64) {
        let baselinePrevious: ToolID
        let baselinePreviousRevision: UInt64
        if let ownerKey, let owner = holds[ownerKey], previousRevision == owner.selectedRevision {
            baselinePrevious = owner.previous
            baselinePreviousRevision = owner.previousRevision
        } else {
            baselinePrevious = previous
            baselinePreviousRevision = previousRevision
        }
        // Released deferred owners have handed their baseline to this press.
        // Only the newest owner can finish on pointer release.
        holds = holds.filter { !$0.value.deferredRestore }
        holds[keyCode] = Hold(keyCode: keyCode, time: time, selected: selected,
                              selectedRevision: selectedRevision,
                              previous: baselinePrevious,
                              previousRevision: baselinePreviousRevision)
        ownerKey = keyCode
    }

    mutating func pointerBegan(using tool: ToolID, selectionRevision: UInt64) {
        pointerActive = true
        ownsInteraction = false
        guard let ownerKey, var owner = holds[ownerKey] else { return }
        if tool == owner.selected && selectionRevision == owner.selectedRevision {
            ownsInteraction = true
            owner.used = true
            holds[ownerKey] = owner
        }
    }

    mutating func pointerEnded(selectionRevision: UInt64) -> ToolID? {
        pointerActive = false
        ownsInteraction = false
        guard let ownerKey, let owner = holds[ownerKey], owner.deferredRestore else { return nil }
        holds.removeValue(forKey: ownerKey)
        self.ownerKey = nil
        if selectionRevision == owner.selectedRevision {
            return owner.previous
        }
        return nil
    }

    mutating func release(keyCode: Int, at time: Double, selectionRevision: UInt64) -> ToolID? {
        guard let hold = holds[keyCode] else { return nil }
        guard ownerKey == keyCode else {
            holds.removeValue(forKey: keyCode)
            return nil
        }
        if shouldRestore(hold: hold, at: time) {
            if selectionRevision == hold.selectedRevision {
                if pointerActive {
                    holds[keyCode]?.deferredRestore = true
                    return nil
                }
                holds.removeValue(forKey: keyCode)
                ownerKey = nil
                return hold.previous
            }
            holds.removeValue(forKey: keyCode)
            ownerKey = nil
            return nil
        } else {
            holds.removeValue(forKey: keyCode)
            ownerKey = nil
            return nil
        }
    }

    mutating func cancel(selectionRevision: UInt64) -> ToolID? {
        let owned = ownerKey.flatMap { holds[$0] }
        holds.removeAll()
        ownerKey = nil
        pointerActive = false
        ownsInteraction = false
        guard let owned, selectionRevision == owned.selectedRevision else { return nil }
        return owned.previous
    }

    mutating func promote() {
        holds.removeAll()
        ownerKey = nil
        pointerActive = false
        ownsInteraction = false
    }

    private func shouldRestore(hold: Hold, at time: Double) -> Bool {
        if hold.used { return true }
        let elapsed = time - hold.time
        guard elapsed.isFinite else { return false }
        return elapsed >= Self.holdThreshold
    }
}
