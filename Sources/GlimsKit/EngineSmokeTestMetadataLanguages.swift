import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Explicit focused bridge check; the caller supplies the committed
    /// Core-generated fixture rather than teaching the frontend a setter.
    static func exerciseMetadataLanguages(_ session: EngineSession) throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMS_LANGUAGE_FIXTURE"] else {
            return check(false, "the language-map bridge check needs its explicit known XCF fixture")
        }
        let image = try session.openImage(path: path)
        var closed = false
        defer { if !closed { try? session.closeImage(image) } }
        let before = try session.info(image)
        let history = try session.undoInfo(image)
        let values = try session.metadataLanguages(image, tag: "Xmp.dc.title")
        let expected = [EngineSession.MetadataLanguageValue(language: "x-default", text: "Hello"),
                        .init(language: "fr", text: "Salut"), .init(language: "de", text: "Hallo")]
        check(values.count == expected.count && expected.allSatisfy(values.contains),
              "the real Swift bridge returns the independently known language/text map")
        let rights = try session.metadataLanguages(image, tag: "Xmp.dc.rights")
        check(rights.count == 2 && rights.contains(.init(language: "ja", text: "権利"))
                && rights.contains(.init(language: "x-default", text: "Default rights")),
              "the Swift bridge preserves Unicode and explicit default language")
        do {
            _ = try session.metadataLanguages(image, tag: "Xmp.dc.format")
            check(false, "a wrong-kind language read must throw")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                  "the Swift bridge reports the native wrong-kind refusal")
        }
        check(try session.info(image) == before && session.undoInfo(image) == history,
              "bridge success and refusal preserve native facts and history")
        try session.closeImage(image)
        closed = true
        check(expected.allSatisfy(values.contains) && rights.contains(.init(language: "ja", text: "権利")),
              "Swift values remain owned after both the C result and image are gone")
    }
}
