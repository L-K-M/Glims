import AppKit

@MainActor
extension EngineSmokeTest {
    /// Exercises the nine-coefficient Swift/native boundary against analytic
    /// output, separately from the future canvas warp interactions.
    static func exerciseProjectiveTransform(_ session: EngineSession) throws {
        let image = try session.newImage(width: 100, height: 100)
        defer { try? session.closeImage(image) }
        var bytes = [UInt8]()
        for y in 0..<100 {
            for x in 0..<100 {
                let value: UInt8 = x < 50 && y < 50 ? 0 : 255
                bytes.append(contentsOf: [value, value, value, 255])
            }
        }
        let layer = try session.pastePixels(image, pixels: ClipboardImage(
            width: 100, height: 100, pixels: Data(bytes), origin: .zero), at: .zero)
        func pixels() throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 100, height: 100))
            return rendered.dataProvider!.data! as Data
        }
        let original = try pixels()
        let before = try session.undoInfo(image)
        let keystone = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                           h10: 0, h11: 1, h12: 0,
                                           h20: 0, h21: 0.01, h22: 1)
        try session.transformLayer(layer, image: image, matrix: keystone, interpolation: .none)
        let changed = try pixels()
        let result = try session.layers(image).first { $0.id == layer }
        check(result?.bounds == CGRect(x: 0, y: 0, width: 100, height: 50),
              "projective bridge preserves all nine coefficients and native bounds")
        check(changed != original && changed[(10 * 100 + 10) * 4] == 0 &&
              changed[(10 * 100 + 70) * 4] == 255 && changed[(40 * 100 + 40) * 4] == 255,
              "projective bridge matches independently predicted interior pixels")
        check(try session.undoInfo(image).undoCount == before.undoCount + 1,
              "projective bridge commits one native Undo step")
        try session.undo(image)
        check(try pixels() == original, "projective bridge Undo restores exact original pixels")
        try session.redo(image)
        check(try pixels() == changed, "projective bridge Redo restores exact transformed pixels")
    }
}
