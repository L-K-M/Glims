/// Pure eraser-proximity state for tablet pointing devices. The canvas owns
/// integration and event reading; this type only tracks which tablet device
/// IDs are currently reporting eraser proximity.
struct TabletEraserProximityState {
    private var eraserDeviceIDs: Set<UInt> = []

    /// Updates the proximity state for one tablet device. An eraser entering
    /// proximity becomes active, any device leaving proximity becomes inactive
    /// regardless of the reported pointing type, and an ordinary pen entering
    /// proximity clears a stale eraser state for that same device.
    mutating func update(deviceID: UInt, entering: Bool, isEraser: Bool) {
        if entering {
            if isEraser {
                eraserDeviceIDs.insert(deviceID)
            } else {
                eraserDeviceIDs.remove(deviceID)
            }
        } else {
            eraserDeviceIDs.remove(deviceID)
        }
    }

    /// Clears all tracked eraser-proximity devices.
    mutating func clear() {
        eraserDeviceIDs.removeAll()
    }

    /// Returns the effective tool for the selected tool and tablet device. A
    /// matching device with active eraser proximity yields `.eraser`; every
    /// other case preserves the selected tool.
    func effectiveTool(selected: ToolID, tabletDeviceID: UInt?) -> ToolID {
        guard let tabletDeviceID, eraserDeviceIDs.contains(tabletDeviceID) else {
            return selected
        }
        return .eraser
    }
}
