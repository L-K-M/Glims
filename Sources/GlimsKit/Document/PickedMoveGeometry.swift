import Foundation

/// The integer arithmetic used by GIMP's item translation, independent of the
/// image's dimension limit. This validates a Pick move without changing its
/// integral snap policy or submitting a potentially overflowing native call.
enum PickedMoveGeometry {
    /// Core's SIGNED_ROUND is floor(value + 0.5), including negative ties.
    static func roundedDelta(_ value: Double) -> Int32? {
        guard value.isFinite else { return nil }
        let rounded = floor(value + 0.5)
        guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else { return nil }
        return Int32(rounded)
    }

    static func canTranslate(bounds: CGRect, by offset: CGSize) -> Bool {
        guard let dx = roundedDelta(Double(offset.width)),
              let dy = roundedDelta(Double(offset.height)) else { return false }
        return safeAxis(origin: Double(bounds.origin.x), size: Double(bounds.size.width), delta: dx)
            && safeAxis(origin: Double(bounds.origin.y), size: Double(bounds.size.height), delta: dy)
    }

    /// A group translates its descendants too. Check the same captured row
    /// against the supplied cache or fresh native rows, then every child that
    /// Core would translate. Unrelated layers do not constrain this move.
    static func canTranslate(_ row: EngineSession.Layer, in rows: [EngineSession.Layer],
                             by offset: CGSize) -> Bool {
        let matches = rows.filter { $0.id == row.id }
        guard matches.count == 1, let current = matches.first,
              current.bounds == row.bounds, current.kind == row.kind,
              canTranslate(bounds: current.bounds, by: offset) else { return false }
        guard current.kind == .group else { return true }
        let children = Dictionary(grouping: rows, by: \.parent)
        var remaining = [current.id]
        var visited: Set<Int32> = [current.id]
        while let parent = remaining.popLast() {
            for child in children[parent] ?? [] {
                guard visited.insert(child.id).inserted,
                      canTranslate(bounds: child.bounds, by: offset) else { return false }
                if child.kind == .group { remaining.append(child.id) }
            }
        }
        return true
    }

    private static func safeAxis(origin: Double, size: Double, delta: Int32) -> Bool {
        guard origin.isFinite, size.isFinite, size > 0,
              origin.rounded(.towardZero) == origin, size.rounded(.towardZero) == size,
              origin >= Double(Int32.min), origin <= Double(Int32.max),
              size <= Double(Int32.max) else { return false }
        let start = Int64(origin), length = Int64(size)
        let (oldEnd, oldOverflow) = start.addingReportingOverflow(length)
        let (moved, moveOverflow) = start.addingReportingOverflow(Int64(delta))
        let (newEnd, endOverflow) = moved.addingReportingOverflow(length)
        let nativeRange = Int64(Int32.min)...Int64(Int32.max)
        return !oldOverflow && !moveOverflow && !endOverflow
            && nativeRange.contains(oldEnd) && nativeRange.contains(moved) && nativeRange.contains(newEnd)
    }
}
