import CoreGraphics

/// A path's shape as the Path tool edits it and the canvas draws it:
/// subpaths of anchors, each with the handle before and after it, in image
/// pixels. A handle on its anchor makes a sharp corner. This is how the
/// engine stores a path (`GlimsPathPoint`), so a whole path goes to the
/// engine per edit.
///
/// ```
///      in ●───◆───● out        a smooth anchor: handles opposite
///                              each other through the anchor
///   ◆ (in = anchor = out)      a corner
/// ```
struct VectorPath: Equatable {

    struct Anchor: Equatable {
        var point: CGPoint
        var handleIn: CGPoint
        var handleOut: CGPoint

        /// A corner: both handles on the anchor.
        init(_ point: CGPoint) {
            self.init(point: point, handleIn: point, handleOut: point)
        }

        init(point: CGPoint, handleIn: CGPoint, handleOut: CGPoint) {
            self.point = point
            self.handleIn = handleIn
            self.handleOut = handleOut
        }

        var isCorner: Bool { handleIn == point && handleOut == point }

        /// Moves the anchor with its handles.
        mutating func move(by delta: CGSize) {
            point = point.offset(by: delta)
            handleIn = handleIn.offset(by: delta)
            handleOut = handleOut.offset(by: delta)
        }

        /// Puts the out handle at `out` and the in handle opposite it, as
        /// dragging from a new anchor does: a smooth anchor.
        mutating func pullHandles(to out: CGPoint) {
            handleOut = out
            handleIn = CGPoint(x: 2 * point.x - out.x, y: 2 * point.y - out.y)
        }
    }

    struct Subpath: Equatable {
        var anchors: [Anchor]
        var isClosed = false
    }

    /// One anchor: its subpath and its place in it.
    struct AnchorIndex: Hashable {
        var subpath: Int
        var anchor: Int
    }

    /// What a press can grab.
    enum Part: Equatable {
        case anchor(AnchorIndex)
        case handleIn(AnchorIndex)
        case handleOut(AnchorIndex)
    }

    var subpaths: [Subpath] = []

    var isEmpty: Bool { subpaths.isEmpty }

    var anchorCount: Int { subpaths.reduce(0) { $0 + $1.anchors.count } }

    subscript(index: AnchorIndex) -> Anchor {
        get { subpaths[index.subpath].anchors[index.anchor] }
        set { subpaths[index.subpath].anchors[index.anchor] = newValue }
    }

    func contains(_ index: AnchorIndex) -> Bool {
        subpaths.indices.contains(index.subpath)
            && subpaths[index.subpath].anchors.indices.contains(index.anchor)
    }

    /// The part under `point` within `tolerance` (image pixels): the
    /// nearest anchor, or else the nearest handle of an anchor in
    /// `handlesOf`. A handle on its anchor is not grabbable; the anchor is.
    func part(at point: CGPoint, tolerance: Double, handlesOf: Set<AnchorIndex>) -> Part? {
        var best: (part: Part, distance: Double)?
        func consider(_ part: Part, at location: CGPoint) {
            let distance = hypot(Double(location.x - point.x), Double(location.y - point.y))
            guard distance <= tolerance, distance < best?.distance ?? .infinity else { return }
            best = (part, distance)
        }

        for (s, subpath) in subpaths.enumerated() {
            for (a, anchor) in subpath.anchors.enumerated() {
                consider(.anchor(AnchorIndex(subpath: s, anchor: a)), at: anchor.point)
            }
        }
        if best != nil { return best?.part }

        for index in handlesOf where contains(index) {
            let anchor = self[index]
            if anchor.handleIn != anchor.point { consider(.handleIn(index), at: anchor.handleIn) }
            if anchor.handleOut != anchor.point { consider(.handleOut(index), at: anchor.handleOut) }
        }
        return best?.part
    }

    /// Removes one anchor. A subpath left without anchors goes away, and
    /// a closed one left with a single anchor opens.
    mutating func removeAnchor(at index: AnchorIndex) {
        guard contains(index) else { return }
        subpaths[index.subpath].anchors.remove(at: index.anchor)
        if subpaths[index.subpath].anchors.isEmpty {
            subpaths.remove(at: index.subpath)
        } else if subpaths[index.subpath].anchors.count < 2 {
            subpaths[index.subpath].isClosed = false
        }
    }

    /// Reverses a subpath's direction, so extending its first anchor can
    /// append at the end. Each anchor's handles swap roles.
    mutating func reverseSubpath(_ index: Int) {
        guard subpaths.indices.contains(index) else { return }
        subpaths[index].anchors = subpaths[index].anchors.reversed().map {
            Anchor(point: $0.point, handleIn: $0.handleOut, handleOut: $0.handleIn)
        }
    }

    /// Whether `other` has exactly the same anchors, handles and closings,
    /// bit for bit. Unlike `==`, a NaN coordinate (a damaged file can hold
    /// one) matches itself, so a drag on such a path is not taken for a
    /// change made elsewhere.
    func isUnchanged(from other: VectorPath) -> Bool {
        guard subpaths.count == other.subpaths.count else { return false }
        let same = { (a: CGPoint, b: CGPoint) in
            a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern
        }
        return zip(subpaths, other.subpaths).allSatisfy { mine, theirs in
            mine.isClosed == theirs.isClosed && mine.anchors.count == theirs.anchors.count
                && zip(mine.anchors, theirs.anchors).allSatisfy {
                    same($0.point, $1.point) && same($0.handleIn, $1.handleIn) && same($0.handleOut, $1.handleOut)
                }
        }
    }

    /// The outline at `scale` view points per image pixel, for drawing:
    /// one cubic curve between neighboring anchors, through the first's
    /// out handle and the second's in handle.
    func cgPath(scale: Double) -> CGPath {
        let path = CGMutablePath()
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        for subpath in subpaths {
            guard let first = subpath.anchors.first else { continue }
            path.move(to: first.point, transform: transform)
            var previous = first
            for anchor in subpath.anchors.dropFirst() {
                path.addCurve(to: anchor.point, control1: previous.handleOut, control2: anchor.handleIn,
                              transform: transform)
                previous = anchor
            }
            if subpath.isClosed, subpath.anchors.count > 1 {
                path.addCurve(to: first.point, control1: previous.handleOut, control2: first.handleIn,
                              transform: transform)
                path.closeSubpath()
            }
        }
        return path
    }
}

private extension CGPoint {
    func offset(by delta: CGSize) -> CGPoint {
        CGPoint(x: x + delta.width, y: y + delta.height)
    }
}
