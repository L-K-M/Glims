import AppKit

@MainActor
extension EngineSmokeTest {
    /// Window ▸ Navigator: the thumbnail, the viewport box, click and drag
    /// to scroll, the zoom controls, refresh after an edit, document
    /// scoping, and that navigating never touches the image's history.
    static func exerciseNavigator(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "navigator: \(message)") }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            return condition()
        }
        func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1.5) -> Bool {
            abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        }
        /// One pixel of a rendered sRGB RGBA thumbnail, top-left origin.
        func pixel(_ image: CGImage?, x: Int, y: Int) -> [UInt8]? {
            guard let image, x < image.width, y < image.height,
                  let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else { return nil }
            let offset = y * image.bytesPerRow + x * 4
            return [UInt8](data[offset..<(offset + 4)])
        }

        var bytes: [UInt8] = []
        for y in 0..<200 { for x in 0..<400 { bytes += [UInt8(x * 255 / 399), UInt8(y * 255 / 199), 96, 255] } }
        let image = try session.newImage(pixels: ClipboardImage(width: 400, height: 200, pixels: Data(bytes), origin: .zero))
        let document = try ImageDocument(session: session, image: image, name: "Navigator Fixture")
        let otherImage = try session.newImage(width: 32, height: 32)
        let otherDocument = try ImageDocument(session: session, image: otherImage, name: "Other Navigator Fixture")
        document.onError = { _ in }
        documents.items += [document, otherDocument]
        let owner = DocumentWindowController(document: document)
        let palette = NavigatorPaletteController(viewport: { $0 === document ? owner : nil })
        let host = NSPanel(contentRect: NSRect(origin: .zero, size: NavigatorPaletteController.definition.contentSize),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentViewController = palette
        host.setContentSize(NavigatorPaletteController.definition.contentSize)
        owner.showWindow(nil)
        owner.window?.setContentSize(NSSize(width: 640, height: 420))
        host.orderFront(nil)
        host.contentView?.layoutSubtreeIfNeeded()
        palette.retarget(to: document)
        defer {
            palette.retarget(to: nil)
            host.orderOut(nil); host.close()
            owner.window?.orderOut(nil)
            var stopped = false
            owner.canvas.stopRendering { stopped = true }
            _ = wait { stopped }
            if !owner.closeStarted { owner.window?.close() }
            document.closeImageWhenDrained()
            otherDocument.closeImageWhenDrained()
            _ = wait { (try? session.info(image)) == nil && (try? session.info(otherImage)) == nil }
            documents.items.removeAll { $0 === document || $0 === otherDocument }
        }

        let menuItem = NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.items
            .first { $0.action == #selector(AppController.showNavigator(_:)) }
        expect(menuItem?.title == "Navigator", "Window ▸ Navigator opens the palette")
        expect(wait { palette.renderCount > 0 && palette.thumbnailView.image != nil },
               "the palette renders the image's thumbnail")
        let thumbnail = palette.thumbnailView.image
        expect(thumbnail?.width == 400 && thumbnail?.height == 200,
               "a small image's thumbnail is rendered at its own size (\(thumbnail?.width ?? 0)x\(thumbnail?.height ?? 0))")
        let left = pixel(thumbnail, x: 2, y: 100), right = pixel(thumbnail, x: 397, y: 100)
        expect((left?[0] ?? 255) < 10 && (right?[0] ?? 0) > 245, "the thumbnail shows the image's pixels, left to right")
        let undoBefore = try session.undoInfo(image)
        let dirtyBefore = try session.info(image).isDirty

        // The viewport box at a high zoom: a small box around the center.
        owner.zoom(to: 1600)
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        let corners = palette.thumbnailView.viewportCorners
        let expectedCorners = owner.navigatorVisibleCorners
        expect(corners.count == 4 && zip(corners, expectedCorners).allSatisfy { near($0, $1, 0.01) },
               "the box follows the window's zoom")
        let boxWidth = (corners.map(\.x).max() ?? 0) - (corners.map(\.x).min() ?? 0)
        let clip = owner.scrollView.contentView.bounds
        expect(boxWidth > 0 && abs(boxWidth - clip.width / owner.canvas.scale) < 0.5 && boxWidth < 400,
               "the box covers the visible image area (\(boxWidth) px)")
        expect(palette.zoomField.stringValue == "1600%"
                && abs(palette.zoomSlider.doubleValue - NavigatorGeometry.sliderValue(zoomPercent: 1600)) < 1e-9,
               "the zoom field and slider show the window's zoom")

        // A click centers the view there; a drag keeps following.
        func mouse(_ type: NSEvent.EventType, at imagePoint: CGPoint) {
            let view = palette.thumbnailView
            let point = NavigatorGeometry.viewPoint(imagePoint, thumbnail: view.thumbnailRect, imageSize: view.imageSize)
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: host.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseDragged(with: event) }
        }
        mouse(.leftMouseDown, at: CGPoint(x: 120, y: 60))
        expect(near(owner.canvasCenter, CGPoint(x: 120, y: 60)), "a click centers the view on that point (\(owner.canvasCenter))")
        mouse(.leftMouseDragged, at: CGPoint(x: 280, y: 140))
        expect(near(owner.canvasCenter, CGPoint(x: 280, y: 140)), "a drag keeps centering the view (\(owner.canvasCenter))")
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        let box = palette.thumbnailView.viewportCorners
        let boxCenter = CGPoint(x: box.map(\.x).reduce(0, +) / 4, y: box.map(\.y).reduce(0, +) / 4)
        expect(box.count == 4 && near(boxCenter, CGPoint(x: 280, y: 140)), "the box follows the scroll (\(boxCenter))")

        // The zoom controls.
        palette.zoomField.stringValue = "200"
        palette.zoomField.sendAction(palette.zoomField.action, to: palette.zoomField.target)
        expect(owner.canvas.zoomPercent == 200 && palette.zoomField.stringValue == "200%", "a typed zoom applies")
        palette.zoomField.stringValue = "abc"
        palette.zoomField.sendAction(palette.zoomField.action, to: palette.zoomField.target)
        expect(owner.canvas.zoomPercent == 200 && palette.zoomField.stringValue == "200%",
               "an unreadable zoom is refused and the field shows the zoom again")
        palette.zoomInButton.performClick(nil)
        expect(owner.canvas.zoomPercent == 300, "Zoom In steps up the ladder")
        palette.zoomOutButton.performClick(nil)
        palette.zoomOutButton.performClick(nil)
        expect(owner.canvas.zoomPercent == 150, "Zoom Out steps down the ladder")
        palette.zoomSlider.doubleValue = NavigatorGeometry.sliderValue(zoomPercent: 800)
        palette.zoomSlider.sendAction(palette.zoomSlider.action, to: palette.zoomSlider.target)
        expect(owner.canvas.zoomPercent == 800, "the slider sets the zoom")
        let undoAfter = try session.undoInfo(image)
        expect(undoAfter.undoCount == undoBefore.undoCount && (try? session.info(image).isDirty) == dirtyBefore,
               "navigating and zooming leave the image and its history alone")

        // Another document's change does not refresh this thumbnail. The
        // notification is delivered synchronously, so nothing scheduled
        // after it means it was ignored.
        expect(wait { !palette.isRefreshing }, "pending thumbnail work settles")
        let rendersBefore = palette.renderCount
        NotificationCenter.default.post(name: .glimsNavigatorImageChanged, object: otherDocument)
        expect(!palette.isRefreshing && palette.renderCount == rendersBefore,
               "another document's edit leaves the thumbnail alone")
        NotificationCenter.default.post(name: .glimsNavigatorImageChanged, object: document)
        expect(palette.isRefreshing, "this document's edit schedules a refresh")
        expect(wait { !palette.isRefreshing && palette.renderCount > rendersBefore }, "the scheduled refresh renders")

        // An edit refreshes the thumbnail.
        let rendersBeforeEdit = palette.renderCount
        document.select(.all)
        document.fill(at: CGPoint(x: 10, y: 10), mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        expect(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "the fill finishes")
        expect(wait { palette.renderCount > rendersBeforeEdit && (pixel(palette.thumbnailView.image, x: 2, y: 100)?[0] ?? 0) > 245 },
               "an edit refreshes the thumbnail")

        // A size change renders a new thumbnail at the new size.
        document.crop(to: CGRect(x: 0, y: 0, width: 100, height: 150))
        expect(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "the crop finishes")
        expect(wait { palette.thumbnailView.imageSize == CGSize(width: 100, height: 150)
                    && palette.thumbnailView.image?.width == 100 && palette.thumbnailView.image?.height == 150 },
               "a crop re-renders the thumbnail at the new size (\(palette.thumbnailView.image?.width ?? 0)x\(palette.thumbnailView.image?.height ?? 0))")

        palette.retarget(to: nil)
        expect(palette.thumbnailView.image == nil && palette.thumbnailView.viewportCorners.isEmpty
                && !palette.zoomField.isEnabled && !palette.zoomSlider.isEnabled,
               "with no document the palette is empty and its controls are disabled")
    }
}
