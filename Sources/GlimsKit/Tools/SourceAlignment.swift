/// How Clone and Heal carry their source from one stroke to the next.
///
/// The adapter always starts a stroke at the source it is given
/// (`GIMP_SOURCE_ALIGN_NO`). Aligned painting is made here by giving each
/// later stroke a source at the distance the first one fixed. The arithmetic
/// is on whole pixels, as in GIMP's `app/paint/gimpsourcecore.c`.
struct SourceAlignment {
    var isAligned = true {
        didSet { if !isAligned { reset() } }
    }
    private var offset: (x: Double, y: Double)?

    /// A new source point starts a new alignment.
    mutating func reset() {
        offset = nil
    }

    /// The source for a stroke that starts at `x`, `y`.
    func source(_ picked: EngineSession.Brush.Source, strokeAtX x: Double, y: Double) -> EngineSession.Brush.Source {
        guard isAligned, let offset else { return picked }
        return .init(drawable: picked.drawable, x: x.rounded(.down) + offset.x, y: y.rounded(.down) + offset.y)
    }

    /// Records an accepted stroke; only the first one fixes the distance.
    mutating func strokeStarted(_ picked: EngineSession.Brush.Source, atX x: Double, y: Double) {
        guard isAligned, offset == nil else { return }
        offset = (picked.x.rounded(.down) - x.rounded(.down), picked.y.rounded(.down) - y.rounded(.down))
    }
}
