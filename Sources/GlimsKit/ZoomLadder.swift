/// The fixed zoom steps the status strip and View menu move through.
///
/// Values are percentages. Stepping from a value between two steps lands on
/// the neighbouring step in that direction, so a fit-to-window zoom such as
/// 61% goes to 67% on zoom in and 50% on zoom out.
public enum ZoomLadder {
    public static let steps: [Int] = [
        5, 10, 25, 33, 50, 67, 100, 150, 200, 300, 400, 800, 1600, 3200
    ]
    public static let actualPixels = 100

    public static func zoomIn(from percent: Int) -> Int {
        steps.first { $0 > percent } ?? steps[steps.count - 1]
    }

    public static func zoomOut(from percent: Int) -> Int {
        steps.last { $0 < percent } ?? steps[0]
    }

    /// A typed zoom, kept within the ladder's smallest and largest steps.
    public static func clamped(_ percent: Int) -> Int {
        min(max(percent, steps[0]), steps[steps.count - 1])
    }
}
