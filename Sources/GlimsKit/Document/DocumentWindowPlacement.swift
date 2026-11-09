import CoreGraphics

/// Screen coordinates only. Existing palette positions are obstacles;
/// document placement never moves or resizes a person's palettes.
enum DocumentWindowPlacement {
    static let cascadeStep: CGFloat = 22

    static func availableFrame(in visible: CGRect, avoiding frames: [CGRect],
                               minimum: CGSize = CGSize(width: 360, height: 240)) -> CGRect {
        guard finite(visible), visible.width > 0, visible.height > 0 else { return .zero }
        let obstacles = frames.filter(finite).map { $0.insetBy(dx: -6, dy: -6).intersection(visible) }
            .filter { !$0.isNull && !$0.isEmpty }
        let xs = Set([visible.minX, visible.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set([visible.minY, visible.maxY] + obstacles.flatMap { [$0.minY, $0.maxY] }).sorted()
        var best: CGRect?
        var area: CGFloat = 0
        var distance = CGFloat.infinity
        for left in xs.indices {
            for right in xs.indices where right > left {
                guard xs[right] - xs[left] >= minimum.width else { continue }
                for bottom in ys.indices {
                    for top in ys.indices where top > bottom {
                        let candidate = CGRect(x: xs[left], y: ys[bottom],
                                               width: xs[right] - xs[left], height: ys[top] - ys[bottom])
                        let candidateArea = candidate.width * candidate.height
                        guard candidate.height >= minimum.height, candidateArea >= area,
                              !obstacles.contains(where: { $0.intersects(candidate) }) else { continue }
                        let candidateDistance = abs(candidate.midX - visible.midX) + abs(candidate.midY - visible.midY)
                        if candidateArea > area || candidateDistance < distance {
                            best = candidate
                            area = candidateArea
                            distance = candidateDistance
                        }
                    }
                }
            }
        }
        // A custom workspace can occupy every usable rectangle. Keep the
        // document reachable then rather than creating a tiny unusable view.
        return best ?? visible
    }

    static func frame(size: CGSize, after previous: CGRect?, in area: CGRect) -> CGRect {
        guard finite(area), !area.isEmpty else { return .zero }
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        guard let previous else {
            return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let stepped = CGRect(x: previous.minX + cascadeStep,
                             y: previous.maxY - cascadeStep - size.height,
                             width: size.width, height: size.height)
        if area.contains(stepped) { return stepped }
        return CGRect(x: min(area.minX + cascadeStep, area.maxX - size.width),
                      y: area.maxY - size.height, width: size.width, height: size.height)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
