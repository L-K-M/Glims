import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// View ▸ Clear Guides and the ruler units through a real window, with
    /// preferences of its own so the user's choice is untouched.
    static func exerciseGuidesRulerUnits(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
            if !condition() { check(false, "a guides and ruler units wait timed out") }
        }
        let suite = work.appendingPathComponent("ruler-unit-defaults").path
        guard let defaults = UserDefaults(suiteName: suite) else {
            return check(false, "scratch preferences open")
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let preferences = EditorPreferences(defaults: defaults)
        let image = try session.newImage(width: 600, height: 400)
        let document = try ImageDocument(session: session, image: image, name: "Guides and ruler units")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, preferences: preferences)
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        defer {
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        guard let horizontal = controller.scrollView.horizontalRulerView as? PixelRulerView,
              let vertical = controller.scrollView.verticalRulerView as? PixelRulerView else {
            return check(false, "both rulers are installed")
        }
        // The menu bar's own items and validation, not copies of them.
        let view = MainMenu.make().items.first { $0.submenu?.title == "View" }?.submenu
        guard let clear = view?.items.first(where: { $0.title == "Clear Guides" }),
              let units = view?.items.first(where: { $0.title == "Ruler Units" })?.submenu else {
            return check(false, "the View menu has Clear Guides and Ruler Units")
        }

        // Clear Guides.
        check(!controller.validateMenuItem(clear), "Clear Guides is disabled without guides")
        document.addGuide(.horizontal, at: 100)
        document.addGuide(.vertical, at: 200)
        document.addGuide(.vertical, at: 600)
        settle()
        wait { document.guides.count == 3 }
        let placed = document.guides.map { "\($0.orientation) \($0.position)" }.sorted()
        check(controller.validateMenuItem(clear), "Clear Guides is enabled with guides")
        controller.toggleLockGuides(nil)
        check(!controller.validateMenuItem(clear), "Lock Guides disables Clear Guides")
        controller.clearGuides(nil)
        settle()
        check(document.guides.count == 3, "locked guides are not cleared")
        controller.toggleLockGuides(nil)
        let before = document.undoInfo.undoCount
        controller.clearGuides(nil)
        settle()
        wait { document.guides.isEmpty }
        check(document.guides.isEmpty, "Clear Guides removes every guide")
        check(document.undoInfo.undoCount == before + 1, "Clear Guides is one undo step")
        check(!controller.validateMenuItem(clear), "Clear Guides is disabled once they are gone")
        document.undo()
        settle()
        wait { document.guides.count == 3 }
        check(document.guides.map { "\($0.orientation) \($0.position)" }.sorted() == placed,
              "one undo restores the three guides")

        // Ruler units.
        check(units.items.map(\.title) == RulerUnit.allCases.map(\.title), "Ruler Units lists every unit")
        check(horizontal.currentPlan()?.unit == .pixels && vertical.currentPlan()?.unit == .pixels,
              "rulers start in pixels")
        document.setResolution(EngineSession.ImageResolution(x: 100, y: 200))
        settle()
        wait { document.resolution?.y == 200 }
        func choose(_ unit: RulerUnit) {
            guard let entry = units.items.first(where: { $0.tag == unit.tag }) else {
                return check(false, "\(unit.title) is in the menu")
            }
            check(controller.validateMenuItem(entry), "\(unit.title) can be chosen")
            controller.chooseRulerUnit(entry)
            _ = controller.validateMenuItem(entry)
            check(entry.state == .on && preferences.rulerUnit == unit, "\(unit.title) is checked and remembered")
            check(horizontal.unit == unit && vertical.unit == unit, "both rulers follow \(unit.title)")
        }
        // A major's label times the unit's pixels lands on the tick.
        func labelsMeasure(_ ruler: PixelRulerView, pixelsPerUnit: Double) -> Bool {
            guard let majors = ruler.currentPlan()?.ticks.filter(\.isMajor), majors.count > 1 else { return false }
            return majors.allSatisfy { tick in
                guard let label = tick.label, let value = Double(label) else { return false }
                return abs(value * pixelsPerUnit - tick.imagePosition) < 1e-3
            }
        }
        choose(.inches)
        check(labelsMeasure(horizontal, pixelsPerUnit: 100), "the horizontal ruler measures at the X resolution")
        check(labelsMeasure(vertical, pixelsPerUnit: 200), "the vertical ruler measures at the Y resolution")
        document.setResolution(EngineSession.ImageResolution(x: 50, y: 200))
        settle()
        wait { document.resolution?.x == 50 }
        check(labelsMeasure(horizontal, pixelsPerUnit: 50), "a resolution change relabels the ruler")
        choose(.percent)
        check(labelsMeasure(horizontal, pixelsPerUnit: 6) && labelsMeasure(vertical, pixelsPerUnit: 4),
              "percent is of each side of the image")

        // Either ruler's context menu.
        guard let window = controller.window,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else {
            return check(false, "a context-click event can be made")
        }
        for (ruler, unit) in [(horizontal, RulerUnit.picas), (vertical, RulerUnit.pixels)] {
            guard let menu = ruler.menu(for: event),
                  let entry = menu.items.first(where: { $0.tag == unit.tag }), let action = entry.action else {
                check(false, "a ruler has a units menu")
                continue
            }
            check(menu.items.filter { $0.state == .on }.map(\.tag) == [ruler.unit.tag],
                  "the ruler's menu checks its current unit")
            check(entry.target === controller, "the ruler's menu acts on its own window")
            _ = NSApp.sendAction(action, to: entry.target, from: entry)
            check(preferences.rulerUnit == unit && horizontal.unit == unit && vertical.unit == unit,
                  "the ruler's menu chooses \(unit.title) for both rulers")
        }
    }
}
