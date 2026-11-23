import Foundation

/// Preference suites for tests and smoke runs. A suite that is a plain name
/// lives in ~/Library/Preferences, where `removePersistentDomain` empties it
/// but leaves its file. A suite that is an absolute path lives at that path,
/// so these stay in the temporary directory.
enum ScratchDefaults {
    static func suiteName(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glims-defaults-\(label)-\(UUID().uuidString)").path
    }
}
