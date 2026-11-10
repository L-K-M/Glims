import AppKit
import CGlimsEngine
import CoreGraphics
import Foundation

/// The canvas's display destination: an immutable snapshot of the owning
/// window's actual backing color space, taken on the main actor and passed
/// to the render worker as plain value data. The actual window backing is
/// authoritative (Apple TN2313): the snapshot never guesses from
/// `NSScreen.main`, `NSColorSpace.deviceRGB`/`.genericRGB` or the image's
/// working space. The window's associated screen is used only to observe
/// profile changes, never as a pixel destination. Detached or unusable
/// window destinations take an explicit, honestly classified sRGB fallback
/// through the existing tagged-sRGB render — bytes are never relabelled.
struct CanvasDisplayDestination: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Rendered into the owning window's own RGB ICC profile.
        case windowProfile
        /// The explicit existing sRGB render fallback (real sRGB tag).
        case srgbFallback
    }

    let kind: Kind
    /// The exact window ICC bytes for `.windowProfile`; empty for fallback.
    let icc: Data

    /// The explicit fallback: the existing sRGB render path with its real
    /// sRGB `CGImage` tag. Safe while detached, and never a guessed profile.
    static let srgbFallback = CanvasDisplayDestination(kind: .srgbFallback, icc: Data())

    private init(kind: Kind, icc: Data) {
        self.kind = kind
        self.icc = icc
    }

    /// Largest window ICC blob accepted; mirrors the adapter cap for facade
    /// slot 132 (`GLIMS_MAX_ICC_PROFILE_BYTES`).
    static let maximumICCBytes = 16 * 1024 * 1024

    /// Pure classification of a candidate window destination: usable only
    /// with real, non-empty ICC bytes within the cap and an RGB color-space
    /// model. Missing, non-RGB or oversized data yields nil, which the
    /// caller maps to `.srgbFallback` — never to a guessed monitor profile.
    init?(validatedWindowICC icc: Data?, colorSpaceModel model: CGColorSpaceModel?) {
        guard let icc, let model, model == .rgb,
              (1...Self.maximumICCBytes).contains(icc.count) else { return nil }
        self.init(kind: .windowProfile, icc: icc)
    }

    /// Main-actor snapshot of the actual owning window's backing color
    /// space. All `NSWindow`/`NSColorSpace` access stays on main; the result
    /// is an immutable value the render worker captures per queued tile.
    @MainActor
    static func snapshot(window: NSWindow?) -> CanvasDisplayDestination {
        guard let space = window?.colorSpace, let cgSpace = space.cgColorSpace else { return .srgbFallback }
        return Self(validatedWindowICC: space.iccProfileData, colorSpaceModel: cgSpace.model)
            ?? .srgbFallback
    }

    var isFallback: Bool { kind == .srgbFallback }

    /// The ICC bytes to render into, or nil for the explicit sRGB fallback.
    var profileICC: Data? { kind == .windowProfile ? icc : nil }

    /// Whether the completed tile cache must be rebuilt when `new` replaces
    /// `self`: only an ICC identity (byte) change invalidates; identical
    /// bytes — e.g. a density-only backing change — preserve the cache.
    func invalidatesCache(comparedTo new: CanvasDisplayDestination) -> Bool { self != new }

    /// Honest classification of a failed destination render. Only an
    /// unusable profile/transform — UNSUPPORTED (non-RGB/malformed ICC, or
    /// an engine without slot 132) or FAILED (the LCMS profile error) — may
    /// fall back once to the sRGB render. Stale-image/close (NOT_FOUND),
    /// BUSY, admission (LOCKED/REQUIRES_RASTERIZE), argument and any other
    /// error is not a destination failure and propagates to the caller's
    /// normal failure path instead of becoming a busy retry loop.
    static func isUnusableDestination(_ error: Error) -> Bool {
        guard let engineError = error as? EngineSession.EngineError else { return false }
        return engineError.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue)
            || engineError.status == Int32(GLIMS_STATUS_FAILED.rawValue)
    }

    /// Renders one tile into `destination` on the caller's queue (the canvas
    /// render queue). The window-profile path passes the exact immutable ICC
    /// bytes to `render(_:scale:area:destinationICC:)`, whose `CGImage` is
    /// exactly tagged; an unusable profile/transform falls back ONCE per
    /// request to the existing sRGB render (never retagging bytes), and every
    /// other error propagates unchanged. No profile/transform cache exists.
    static func render(_ session: EngineSession, image: Int32, scale: Double, area: CGRect,
                       destination: CanvasDisplayDestination, proof: CanvasSoftProof? = nil) throws -> CGImage {
        if let proof {
            guard let icc = destination.profileICC
                ?? (CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?) else {
                throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                    message: "The proof view has no usable display destination profile.")
            }
            // A requested proof must never become ordinary, unproofed pixels
            // when a profile or native transform fails.
            return try session.render(image, scale: scale, area: area, destinationICC: icc, proof: proof)
        }
        guard let icc = destination.profileICC else {
            return try session.render(image, scale: scale, area: area)
        }
        do {
            return try session.render(image, scale: scale, area: area, destinationICC: icc)
        } catch {
            guard isUnusableDestination(error) else { throw error }
            return try session.render(image, scale: scale, area: area)
        }
    }
}
