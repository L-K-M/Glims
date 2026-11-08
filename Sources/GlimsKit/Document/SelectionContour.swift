import AppKit

/// The selection marching-ants path, built from the engine's boundary
/// edges.
///
/// The engine reports the selection boundary as unordered edges on pixel
/// corners (`EngineSession.Segment`). The edges are joined into continuous
/// contours here so the dash pattern runs along each contour instead of
/// restarting on every raw edge: with one subpath per edge, short
/// stair-step edges all start the dash in its "off" half at some phases
/// and the black outline vanishes on a white image.
enum SelectionContour {
    /// One continuous chain of boundary edges, in image-pixel corners.
    /// A closed contour does not repeat its first point at the end.
    struct Contour: Equatable {
        var points: [CGPoint]
        var isClosed: Bool
    }

    /// The boundary edges joined into contours. Every input edge appears
    /// in exactly one contour, exactly once, whatever order or direction
    /// the input uses; the input is not mutated.
    ///
    /// One walk per unused edge, following unused edges out of each vertex
    /// (a hash map keyed by the exact integral pixel-corner coordinates),
    /// so the whole join is O(n) with no per-edge scan. Returning to any
    /// vertex on the current chain completes a contour there; removing
    /// that loop keeps diagonally touching regions as separate contours
    /// even when the input's edge directions differ.
    static func contours(from segments: [EngineSession.Segment]) -> [Contour] {
        var adjacency: [Vertex: [(edge: Int, other: Vertex)]] = [:]
        var endpoints: [(Vertex, Vertex)] = []
        endpoints.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            let a = Vertex(segment.from), b = Vertex(segment.to)
            endpoints.append((a, b))
            adjacency[a, default: []].append((index, b))
            adjacency[b, default: []].append((index, a))
        }
        func degree(_ vertex: Vertex) -> Int { adjacency[vertex]?.count ?? 0 }
        // Open chains are walked from a degree-1 tip so each chain becomes
        // a single contour; closed loops start anywhere.
        let starts = segments.indices.filter { degree(endpoints[$0].0) == 1 || degree(endpoints[$0].1) == 1 }
            + segments.indices
        var used = [Bool](repeating: false, count: segments.count)
        var result: [Contour] = []
        for start in starts where !used[start] {
            used[start] = true
            var first = endpoints[start].0
            var current = endpoints[start].1
            if degree(first) != 1, degree(current) == 1 { swap(&first, &current) }
            var previous = first
            var points = [first, current]
            var positions = [first: 0, current: 1]
            while current != first,
                  let next = nextEdge(at: current, arrivingFrom: previous, adjacency: adjacency, used: used) {
                used[next.edge] = true
                previous = current
                current = next.other
                if let loopStart = positions[current] {
                    result.append(Contour(points: points[loopStart...].map(\.point), isClosed: true))
                    for vertex in points[(loopStart + 1)...] { positions.removeValue(forKey: vertex) }
                    points.removeSubrange((loopStart + 1)...)
                    if loopStart == 0 { break }
                } else {
                    positions[current] = points.count
                    points.append(current)
                }
            }
            if points.count > 1 {
                result.append(Contour(points: points.map(\.point), isClosed: false))
            }
        }
        return result
    }

    /// The unused edge to follow out of `vertex`, arriving from `previous`.
    /// At a branch (a diagonal touch, where four edges share one corner)
    /// prefer the sharpest left turn. Loop extraction above separates
    /// touching contours regardless of which direction the walk started.
    private static func nextEdge(at vertex: Vertex, arrivingFrom previous: Vertex,
                                 adjacency: [Vertex: [(edge: Int, other: Vertex)]],
                                 used: [Bool]) -> (edge: Int, other: Vertex)? {
        let options = adjacency[vertex]?.filter { !used[$0.edge] } ?? []
        guard let first = options.first else { return nil }
        guard options.count > 1 else { return first }
        let incoming = (dx: vertex.x - previous.x, dy: vertex.y - previous.y)
        func cross(_ other: Vertex) -> Int {
            incoming.dx * (other.y - vertex.y) - incoming.dy * (other.x - vertex.x)
        }
        return options.max { cross($0.other) < cross($1.other) }
    }

    /// An exact key for a pixel-corner coordinate. The facade reports
    /// integral coordinates, for which rounding is the identity.
    private struct Vertex: Hashable {
        let x: Int
        let y: Int
        init(_ point: CGPoint) {
            x = Int(point.x.rounded())
            y = Int(point.y.rounded())
        }
        var point: CGPoint { CGPoint(x: x, y: y) }
    }

    /// The outline path for `segments` at `scale` view points per image
    /// pixel. Half a point inward of pixel corners keeps a 1 pt line
    /// crisp.
    static func outlinePath(for segments: [EngineSession.Segment], scale: Double) -> NSBezierPath {
        let path = NSBezierPath()
        for contour in contours(from: segments) {
            guard let first = contour.points.first else { continue }
            path.move(to: viewPoint(first, scale: scale))
            for point in contour.points.dropFirst() {
                path.line(to: viewPoint(point, scale: scale))
            }
            if contour.isClosed { path.close() }
        }
        return path
    }

    private static func viewPoint(_ point: CGPoint, scale: Double) -> NSPoint {
        NSPoint(x: point.x * scale + 0.5, y: point.y * scale + 0.5)
    }
}
