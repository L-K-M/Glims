import Foundation

/// Detached sRGB color and opacity. The logical layer is a separate,
/// explicitly resolved binding and is never stored as a native item ID.
struct RecorderLabLayerFillValue: Equatable {
    let color: RecorderColor
    let opacity: Double

    func validated() throws -> Self {
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw RecorderFileError.invalid("A recorded Lab layer Fill opacity must be between 0 and 1.")
        }
        return self
    }

    func apply(session: EngineSession, image: Int32, target: EngineSession.LabLayerFillTarget) throws {
        _ = try validated()
        let native = EngineSession.RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        try session.fillLabLayer(image, target: target, color: native, opacity: opacity, requireEmptySelection: true)
    }
}
