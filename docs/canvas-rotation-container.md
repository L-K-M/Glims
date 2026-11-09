# Canvas rotation container

`CanvasRotationView` is a standalone AppKit container for a later Root-owned
document workspace integration. It wraps one flipped canvas view and applies
view rotation with ordinary `NSView.frameRotation`.

Measured probe behavior (`/tmp/glims-completion/view-rotation-probe.*`): the
rotated child's frame and bounds sizes stay unrotated while AppKit rotates point
conversion and hit testing. `setFrameSize` keeps logical bounds and does not
swap width and height.

The container keeps rotation as a plain degree value normalized to `[-180, 180)`,
rejects non-finite values without mutation, observes child frame changes, and
lays the rotated bounds box into positive host coordinates. Canvas pixels, tile
keys, tool coordinates, and overlays remain in unrotated image space. DWC
centering, zoom, fit, backing, rulers, and menu integration are intentionally
left for Root.
