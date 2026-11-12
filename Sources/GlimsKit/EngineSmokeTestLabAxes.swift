import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// No windows or dialogs: exercises the real optional facade through Swift.
    static func exerciseLabAxes(_ session: EngineSession, work: URL) throws {
        let prefix = Int(ProcessInfo.processInfo.environment["GLIMS_SMOKE_LAB_PREFIX"] ?? "191") ?? 191
        check(session.supportsLabCreation == (prefix >= 190), "Lab creation capability follows its independent API prefix")
        check(session.supportsLabAxes == (prefix >= 191), "Lab metadata capability follows its independent API prefix")
        func unsupported(_ body: () throws -> Void, _ label: String) {
            do { try body(); check(false, label) }
            catch { check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue), label) }
        }
        if prefix < 190 {
            unsupported({ _ = try session.newLabImage(width: 8, height: 4, component: .u8) },
                        "old producers refuse optional Lab creation without calling a missing slot")
        }
        if prefix < 191 {
            unsupported({ _ = try session.labAxes(1) },
                        "old producers refuse optional Lab metadata without calling a missing slot")
            if prefix == 190 {
                let image = try session.newLabImage(width: 8, height: 4, component: .u8)
                check(try session.info(image).width == 8, "slot190 creation works without requiring slot191")
                try session.closeImage(image)
            }
            let ordinary = try session.newImage(width: 8, height: 4)
            check(try session.info(ordinary).width == 8, "legacy ordinary editing remains available")
            try session.closeImage(ordinary)
            return
        }

        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 8, height: 4))
            return rendered.dataProvider!.data! as Data
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let image = try session.newLabImage(width: 8, height: 4, component: component)
            defer { try? session.closeImage(image) }
            let before = try pixels(image), history = try session.undoInfo(image)
            let state = try session.labAxes(image)
            check(state.component == component && state.axes.map(\.role) == [.lightness, .a, .b],
                  "Swift receives the native precision and physical Lab roles")
            check(state.axes.map(\.name) == ["Lightness", "a", "b"] &&
                  state.axes.map(\.isSelected) == [true, false, false],
                  "Lab metadata reads explicit native names and selection")
            check(Set(state.axes.map(\.id)).count == 3 && Set(state.axes.map(\.uuid)).count == 3,
                  "Lab axes have separate current handles and durable identities")
            check(try session.labAxes(image) == state, "repeated Lab metadata reads are stable")
            let after = try pixels(image), afterHistory = try session.undoInfo(image)
            check(after == before && afterHistory.undoCount == history.undoCount && afterHistory.redoCount == history.redoCount,
                  "Swift Lab reads preserve visible pixels and history")
            let path = work.appendingPathComponent("lab-axes-\(component.rawValue).xcf").path
            try session.save(image, to: path)
            let reopened = try session.openImage(path: path)
            defer { try? session.closeImage(reopened) }
            let restored = try session.labAxes(reopened)
            check(restored.component == component && restored.axes.map(\.uuid) == state.axes.map(\.uuid) &&
                  restored.axes.map(\.role) == state.axes.map(\.role),
                  "Swift reads durable Lab identities after XCF reopen")
            check(Set(restored.axes.map(\.id)).isDisjoint(with: Set(state.axes.map(\.id))),
                  "reopened Lab handles are distinct from still-open source handles")
        }

        let ordinary = try session.newImage(width: 8, height: 4)
        defer { try? session.closeImage(ordinary) }
        unsupported({ _ = try session.labAxes(ordinary) }, "ordinary channels cannot masquerade as Lab axes")

        // Until Lab UI capabilities are implemented, construction must refuse
        // and Open must release its otherwise successfully loaded native image.
        let rejected = try session.newLabImage(width: 8, height: 4, component: .u8)
        do {
            try AppController.adoptOpenedImage(.success(rejected), adopt: { image in
                _ = try ImageDocument(session: session, image: image, name: "Lab admission witness")
            }, close: { try session.closeImage($0) })
            check(false, "unsupported Lab document construction is refused")
            try? session.closeImage(rejected)
        } catch {
            check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                  "unsupported Lab document construction preserves its original error")
        }
        do { _ = try session.info(rejected); check(false, "failed Open closes the actual native Lab image") }
        catch { check((error as? EngineSession.EngineError)?.isNotFound == true,
                      "failed Open closes the actual native Lab image") }
    }
}
