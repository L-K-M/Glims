import Foundation

/// The app's fixed identity. `Resources/Info.plist` must agree with these
/// values; `AppIdentityTests` and CI check that.
public enum AppIdentity {
    public static let name = "Glims"
    public static let bundleIdentifier = "ch.lkmc.Glims"

    /// The marketing version of the running bundle, or `nil` when the binary
    /// runs unbundled (for example under `swift run`), where no Info.plist
    /// carries a version.
    public static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
