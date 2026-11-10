import AppKit

/// App-lifetime, passive proximity tracking. The first canvas installs it;
/// documents and windows are never retained. Standalone and mouse-mirrored
/// proximity reports are idempotent state updates, never paint samples.
@MainActor
final class TabletEraserProximity {
    static let shared = TabletEraserProximity()

    private var state = TabletEraserProximityState()
    private var started = false
    private var monitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Mouse events may carry the SDK-documented tabletProximity subtype.
        // Observe those too, returning every original event exactly once.
        let mask: NSEvent.EventTypeMask = [.tabletProximity, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observeProximity(event)
            return event
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.state.clear()
            }
    }

    /// Proximity-only properties are read only after validating one of the
    /// two public proximity representations. Point events never reach them.
    private func observeProximity(_ event: NSEvent) {
        guard Self.isProximityEvent(event),
              let device = UInt(exactly: event.deviceID) else { return }
        state.update(deviceID: device, entering: event.isEnteringProximity,
                     isEraser: event.pointingDeviceType == .eraser)
    }

    /// Only a matching tablet point may borrow Eraser for its next press.
    /// Standalone points are queried here but not dispatched as paint input:
    /// the existing mouse-subtype stream remains the sole stroke producer.
    func effectiveTool(selected: ToolID, event: NSEvent) -> ToolID {
        let point = event.type == .tabletPoint
            || (Self.isMouseEvent(event) && event.subtype == .tabletPoint)
        let device = point ? UInt(exactly: event.deviceID) : nil
        return state.effectiveTool(selected: selected, tabletDeviceID: device)
    }

    static func isProximityEvent(_ event: NSEvent) -> Bool {
        event.type == .tabletProximity
            || (isMouseEvent(event) && event.subtype == .tabletProximity)
    }

    private static func isMouseEvent(_ event: NSEvent) -> Bool {
        // Tracking events (entered/exited/cursorUpdate) do not support subtype.
        // AppKit raises NSInternalInconsistencyException if it is queried.

        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved: return true
        default: return false
        }
    }
}
