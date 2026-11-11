import AppKit
import IOKit.hidsystem

/// App-lifetime, passive proximity tracking. The first canvas installs it;
/// documents and windows are never retained. Standalone and mouse-mirrored
/// proximity reports are idempotent state updates, never paint samples.
@MainActor
final class TabletEraserProximity {
    static let shared = TabletEraserProximity()

    private var state = TabletEraserProximityState()
    private var capabilities: [UInt: TabletStrokeInput.Capabilities] = [:]
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
                MainActor.assumeIsolated {
                    self?.state.clear()
                    self?.capabilities.removeAll()
                }
            }
    }

    /// Proximity-only properties are read only after validating one of the
    /// two public proximity representations. Point events never reach them.
    private func observeProximity(_ event: NSEvent) {
        guard Self.isProximityEvent(event),
              let device = UInt(exactly: event.deviceID) else { return }
        state.update(deviceID: device, entering: event.isEnteringProximity,
                     isEraser: event.pointingDeviceType == .eraser)
        if event.isEnteringProximity {
            let mask = UInt(exactly: event.capabilityMask) ?? 0
            capabilities[device] = .init(rotation: mask & UInt(NX_TABLET_CAPABILITY_ROTATIONMASK) != 0,
                tangentialPressure: mask & UInt(NX_TABLET_CAPABILITY_TANGENTIALPRESSUREMASK) != 0)
        } else { capabilities.removeValue(forKey: device) }
    }

    /// Only a matching tablet point may borrow Eraser for its next press.
    /// Standalone points are queried here but not dispatched as paint input:
    /// the existing mouse-subtype stream remains the sole stroke producer.
    func effectiveTool(selected: ToolID, event: NSEvent) -> ToolID {
        let point = Self.isTabletPoint(event)
        let device = point ? UInt(exactly: event.deviceID) : nil
        return state.effectiveTool(selected: selected, tabletDeviceID: device)
    }

    func strokeCapture(for event: NSEvent) -> TabletStrokeInput.Capture? {
        guard Self.isTabletPoint(event), let device = UInt(exactly: event.deviceID) else { return nil }
        return TabletStrokeInput.capture(deviceID: device, devices: capabilities)
    }

    static func isTabletPoint(_ event: NSEvent) -> Bool {
        event.type == .tabletPoint || (isMouseEvent(event) && event.subtype == .tabletPoint)
    }

    static func isProximityEvent(_ event: NSEvent) -> Bool {
        event.type == .tabletProximity
            || (isMouseEvent(event) && event.subtype == .tabletProximity)
    }

    static func isMouseEvent(_ event: NSEvent) -> Bool {
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
