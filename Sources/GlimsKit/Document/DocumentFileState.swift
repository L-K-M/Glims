import Foundation

/// Where a document's pixels live on disk, and whether closing would
/// lose them.
///
/// The engine writes files but keeps no per-image book-keeping the
/// interface can query, so the document tracks it: the native XCF a
/// plain Save writes to, the foreign file an imported image came from —
/// never a save target, XCF bytes over a JPEG would corrupt it — and
/// the unsaved-changes flag the close prompt consults.
struct DocumentFileState: Equatable {
    /// The native (XCF) file this image is written to; `nil` while it
    /// only exists in memory or came from a foreign file.
    private(set) var nativeURL: URL?
    /// The foreign file this image was imported from, if any. Cleared
    /// when a native save gives the image its own file.
    private(set) var importedSourceURL: URL?
    /// Changes not written to `nativeURL`: edits the engine counted
    /// and, for an imported image, the missing native file itself.
    private(set) var hasUnsavedChanges: Bool

    /// The engine's native file extension.
    static let nativeExtension = "xcf"

    /// `source` is the file the image was opened from: native when it
    /// is an XCF, an imported source otherwise; `nil` for a new image.
    init(openedFrom source: URL? = nil) {
        if let source, Self.isNative(source) {
            nativeURL = source
            importedSourceURL = nil
            hasUnsavedChanges = false
        } else {
            nativeURL = nil
            importedSourceURL = source
            // Imported pixels have no writable file: the image counts
            // as unsaved until a native save creates one.
            hasUnsavedChanges = source != nil
        }
    }

    static func isNative(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".xcf") || name.hasSuffix(".xcf.gz") || name.hasSuffix(".xcf.bz2")
    }

    /// How a plain Save proceeds.
    enum SaveRoute: Equatable {
        /// A native file exists: write it.
        case write(URL)
        /// None yet: ask for one (Save As).
        case askForFile
    }

    var saveRoute: SaveRoute {
        nativeURL.map(SaveRoute.write) ?? .askForFile
    }

    /// Syncs the flag with the dirty state the engine reports. An
    /// imported image stays unsaved even when the engine calls it
    /// clean: its only disk copy is still the foreign source.
    mutating func syncDirty(_ dirty: Bool) {
        hasUnsavedChanges = dirty || importedSourceURL != nil
    }

    /// A native save to `url` succeeded: it is the image's file now.
    mutating func noteSaved(to url: URL) {
        nativeURL = url
        importedSourceURL = nil
        hasUnsavedChanges = false
    }

    /// An export to `url` finished. Exports write a foreign-format
    /// copy: the native file state — target and dirtiness — stands, so
    /// this deliberately changes nothing.
    mutating func noteExported(to url: URL) {}
}
